#!/usr/bin/env python3
"""Measure semantic runtime latency and deployed-model scale against Exasol.

This complements database-free Lua coverage. It is intentionally configurable:
CI environments with a large-model fixture can raise PERF_MIN_MODEL_FIELDS and
PERF_MIN_CARDINALITY, while the bundled sales model still provides a useful
cold/warm and execution regression signal.
"""

from __future__ import annotations

import json
import os
import ssl
import statistics
import sys
import time
from pathlib import Path
from typing import Any

from semantic_client import compile_request


WARM_ITERATIONS = int(os.environ.get("PERF_WARM_ITERATIONS", "20"))
COLD_MAX_MS = float(os.environ.get("PERF_COLD_MAX_MS", "5000"))
WARM_P95_MAX_MS = float(os.environ.get("PERF_WARM_P95_MAX_MS", "1000"))
EXECUTION_MAX_MS = float(os.environ.get("PERF_EXECUTION_MAX_MS", "30000"))
MIN_MODEL_FIELDS = int(os.environ.get("PERF_MIN_MODEL_FIELDS", "1"))
MIN_CARDINALITY = int(os.environ.get("PERF_MIN_CARDINALITY", "1"))


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this live-runtime test.", file=sys.stderr)
        raise SystemExit(2)
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def percentile(values: list[float], pct: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = round((pct / 100.0) * (len(ordered) - 1))
    return ordered[max(0, min(len(ordered) - 1, index))]


def timed_compile(conn: Any, request: dict[str, Any]) -> tuple[dict[str, Any], float]:
    started = time.perf_counter()
    result = compile_request(conn, request)
    elapsed_ms = (time.perf_counter() - started) * 1000
    if result["status"] != "OK":
        raise AssertionError(
            f"compile failed [{result['error_code']}]: {result['error_message']}"
        )
    return result, elapsed_ms


def discover_largest_object(conn: Any) -> dict[str, Any]:
    rows = conn.execute("""
        SELECT MODEL_NAME, OBJECT_NAME, FIELD_KIND, FIELD_NAME
        FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
        ORDER BY MODEL_NAME, OBJECT_NAME, FIELD_KIND, FIELD_NAME
    """).fetchall()
    objects: dict[tuple[str, str], dict[str, Any]] = {}
    for model, object_name, kind, field in rows:
        item = objects.setdefault(
            (model, object_name),
            {"model": model, "object": object_name, "metrics": [], "dimensions": []},
        )
        if kind == "METRIC":
            item["metrics"].append(field)
        elif kind == "DIMENSION":
            item["dimensions"].append(field)
    if not objects:
        raise AssertionError("no role-visible semantic fields found")
    return max(
        objects.values(),
        key=lambda item: len(item["metrics"]) + len(item["dimensions"]),
    )


def compatible_dimensions(conn: Any, model: str, object_name: str, metrics: list[str]) -> list[str]:
    if not metrics:
        return []
    metric_literals = ",".join("'" + value.replace("'", "''") + "'" for value in metrics)
    rows = conn.execute(f"""
        SELECT DIMENSION_NAME
        FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT
        WHERE UPPER(MODEL_NAME) = UPPER('{model.replace("'", "''")}')
          AND UPPER(OBJECT_NAME) = UPPER('{object_name.replace("'", "''")}')
          AND METRIC_NAME IN ({metric_literals})
          AND IS_VALID = TRUE
        GROUP BY DIMENSION_NAME
        HAVING COUNT(DISTINCT METRIC_NAME) = {len(metrics)}
        ORDER BY DIMENSION_NAME
    """).fetchall()
    return [row[0] for row in rows]


def execute_dimension_probe(conn: Any, base: dict[str, Any], dimension: str) -> tuple[int, float]:
    result, _ = timed_compile(conn, {
        "model": base["model"], "object": base["object"],
        "dimensions": [dimension], "client": "runtime_performance_cardinality",
    })
    started = time.perf_counter()
    rows = conn.execute(result["generated_sql"]).fetchall()
    elapsed_ms = (time.perf_counter() - started) * 1000
    return len(rows), elapsed_ms


def main() -> None:
    conn = connect()
    try:
        largest = discover_largest_object(conn)
        field_count = len(largest["metrics"]) + len(largest["dimensions"])
        if field_count < MIN_MODEL_FIELDS:
            raise AssertionError(
                f"largest visible object has {field_count} fields; expected >= {MIN_MODEL_FIELDS}"
            )

        metrics = largest["metrics"]
        dimensions = compatible_dimensions(
            conn, largest["model"], largest["object"], metrics
        )
        request: dict[str, Any] = {
            "model": largest["model"], "object": largest["object"],
            "client": "runtime_performance",
        }
        if metrics:
            request["metrics"] = metrics
            request["dimensions"] = dimensions
        else:
            request["dimensions"] = largest["dimensions"]

        _, first_ms = timed_compile(conn, request)
        warm_ms = [timed_compile(conn, request)[1] for _ in range(WARM_ITERATIONS)]
        warm_p95 = percentile(warm_ms, 95)
        if first_ms > COLD_MAX_MS:
            raise AssertionError(f"first-call latency {first_ms:.1f}ms exceeds {COLD_MAX_MS:.1f}ms")
        if warm_p95 > WARM_P95_MAX_MS:
            raise AssertionError(f"warm p95 latency {warm_p95:.1f}ms exceeds {WARM_P95_MAX_MS:.1f}ms")

        probes = []
        for dimension in largest["dimensions"]:
            cardinality, elapsed_ms = execute_dimension_probe(conn, largest, dimension)
            if elapsed_ms > EXECUTION_MAX_MS:
                raise AssertionError(
                    f"dimension {dimension} execution {elapsed_ms:.1f}ms exceeds {EXECUTION_MAX_MS:.1f}ms"
                )
            probes.append({
                "dimension": dimension, "cardinality": cardinality,
                "execution_ms": round(elapsed_ms, 3),
            })
        max_cardinality = max((probe["cardinality"] for probe in probes), default=0)
        if max_cardinality < MIN_CARDINALITY:
            raise AssertionError(
                f"maximum observed dimension cardinality {max_cardinality}; expected >= {MIN_CARDINALITY}"
            )

        summary = {
            "model": largest["model"], "object": largest["object"],
            "field_count": field_count, "metric_count": len(metrics),
            "compatible_dimension_count": len(dimensions),
            "first_call_ms": round(first_ms, 3),
            "warm_compile": {
                "iterations": WARM_ITERATIONS,
                "mean_ms": round(statistics.mean(warm_ms), 3),
                "p50_ms": round(percentile(warm_ms, 50), 3),
                "p95_ms": round(warm_p95, 3),
                "max_ms": round(max(warm_ms), 3),
            },
            "dimension_probes": probes,
            "max_observed_cardinality": max_cardinality,
            "thresholds": {
                "cold_max_ms": COLD_MAX_MS, "warm_p95_max_ms": WARM_P95_MAX_MS,
                "execution_max_ms": EXECUTION_MAX_MS,
                "min_model_fields": MIN_MODEL_FIELDS,
                "min_cardinality": MIN_CARDINALITY,
            },
        }
        print(json.dumps(summary, indent=2, sort_keys=True))
        output = os.environ.get("PERF_OUTPUT_JSON")
        if output:
            Path(output).write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
