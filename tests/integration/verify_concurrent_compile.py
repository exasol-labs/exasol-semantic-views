#!/usr/bin/env python3
"""Verify BUG-001 fix: concurrent COMPILE_REQUEST_JSON / COMPILE_SQL succeed.

Spawns multiple threads that hammer the compiler with mixed requests. Asserts
that every compile returns STATUS=OK, that no caller sees SEMANTIC_REQUEST_999
(catch-all) or SEMANTIC_REQUEST_100 (transient collision) leak through, and
that a uniform p95 latency stays well under what the validator-on-every-call
path produced before the fix.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
import threading
import time
from typing import Any


THREADS = int(os.environ.get("CONCURRENT_THREADS", "6"))
ITERATIONS = int(os.environ.get("CONCURRENT_ITERATIONS", "8"))
P95_MAX_MS = float(os.environ.get("CONCURRENT_P95_MAX_MS", "5000"))


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)
    host = os.environ.get("EXASOL_HOST", "localhost")
    port = os.environ.get("EXASOL_PORT", "8563")
    return pyexasol.connect(
        dsn=f"{host}:{port}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


REQUESTS: list[dict[str, Any]] = [
    {"model": "sales", "object": "SALES", "metrics": ["total_revenue", "gross_margin"], "client": "concurrent_test"},
    {"model": "sales", "object": "SALES", "metrics": ["total_revenue", "gross_margin"],
     "dimensions": ["customer_region"], "client": "concurrent_test"},
    {"model": "sales", "object": "SALES", "metrics": ["total_revenue"],
     "dimensions": ["order_month"], "client": "concurrent_test"},
    {"model": "sales", "object": "SALES", "metrics": ["completed_revenue"],
     "dimensions": ["product_category"], "client": "concurrent_test"},
]


def compile_one(con, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    started = time.perf_counter()
    rows = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    ).fetchall()
    elapsed = time.perf_counter() - started
    if len(rows) != 1:
        raise AssertionError(f"expected one row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "elapsed_ms": elapsed * 1000.0,
    }


def worker(worker_id: int, results: list[dict[str, Any]]) -> None:
    con = connect()
    try:
        for i in range(ITERATIONS):
            req = REQUESTS[(worker_id + i) % len(REQUESTS)]
            try:
                result = compile_one(con, req)
            except Exception as exc:  # noqa: BLE001
                result = {"status": "EXCEPTION", "error_code": None,
                          "error_message": str(exc), "elapsed_ms": 0.0}
            result["worker"] = worker_id
            result["iteration"] = i
            results.append(result)
    finally:
        con.close()


def percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round((pct / 100.0) * (len(s) - 1)))))
    return s[k]


def main() -> None:
    results: list[dict[str, Any]] = []
    threads = [
        threading.Thread(target=worker, args=(i, results), daemon=False)
        for i in range(THREADS)
    ]
    started = time.perf_counter()
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    wall_clock = time.perf_counter() - started

    statuses: dict[str, int] = {}
    error_codes: dict[str, int] = {}
    latencies: list[float] = []
    for r in results:
        statuses[r["status"]] = statuses.get(r["status"], 0) + 1
        if r["error_code"]:
            error_codes[r["error_code"]] = error_codes.get(r["error_code"], 0) + 1
        latencies.append(r["elapsed_ms"])

    expected = THREADS * ITERATIONS
    assert len(results) == expected, f"expected {expected} results, got {len(results)}"
    print(f"ok concurrent compile total: {len(results)}")
    print(f"ok concurrent compile wall-clock: {wall_clock * 1000:.0f} ms across {THREADS} threads")
    print(f"ok concurrent compile p50/p95/max latency (ms): "
          f"{percentile(latencies, 50):.0f} / {percentile(latencies, 95):.0f} / {max(latencies):.0f}")

    p95 = percentile(latencies, 95)
    if p95 > P95_MAX_MS:
        print(f"FAIL concurrent compile p95 {p95:.0f} ms exceeds {P95_MAX_MS:.0f} ms")
        raise SystemExit(1)
    print(f"ok concurrent compile p95 threshold: <= {P95_MAX_MS:.0f} ms")

    if statuses != {"OK": expected}:
        print(f"FAIL non-OK statuses: {statuses}")
        for r in results:
            if r["status"] != "OK":
                print(f"  worker={r['worker']} iter={r['iteration']} "
                      f"status={r['status']} code={r['error_code']} msg={r['error_message']}")
        raise SystemExit(1)
    print(f"ok concurrent compile all OK: {statuses}")
    if error_codes:
        print(f"FAIL unexpected error codes observed: {error_codes}")
        raise SystemExit(1)
    print("ok concurrent compile no SEMANTIC_REQUEST_100 / _999 leakage")


if __name__ == "__main__":
    main()
