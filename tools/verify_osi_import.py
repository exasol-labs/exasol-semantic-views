#!/usr/bin/env python3
"""Verify OSI import apply support on Exasol Nano."""

from __future__ import annotations

import importlib.util
import json
import os
import ssl
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
OSI_PATH = ROOT / "tools/osi.py"
TARGET_MODEL = "sales_osi_import"

spec = importlib.util.spec_from_file_location("osi_tool", OSI_PATH)
osi = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
assert spec.loader is not None
sys.modules[spec.name] = osi
spec.loader.exec_module(osi)


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


def fetchall(con, sql: str) -> list[tuple[Any, ...]]:
    return [tuple(row) for row in con.execute(sql).fetchall()]


def scalar(con, sql: str) -> int:
    rows = fetchall(con, sql)
    return int(rows[0][0])


def compile_request(con, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    rows = fetchall(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})")
    if len(rows) != 1:
        raise AssertionError(f"expected one compiler row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "generated_sql": row[4],
        "plan_json": row[5],
    }


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_true(name: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(f"{name}: expected true")
    print(f"ok {name}")


def assert_contains(name: str, text: str, expected: str) -> None:
    if expected not in text:
        raise AssertionError(f"{name}: expected to find {expected!r} in {text!r}")
    print(f"ok {name}: found {expected!r}")


def diagnostic_codes(result: dict[str, Any]) -> set[str]:
    return {item["code"] for item in result.get("diagnostics", [])}


def make_plan(document: dict[str, Any], *, target_model: str = TARGET_MODEL) -> dict[str, Any]:
    return osi.plan_import(
        document,
        osi.ImportOptions(
            profile="lossless",
            strict=True,
            warnings_as_errors=False,
            target_model=target_model,
            source="<live-sales-export>",
        ),
    )


def apply_plan(con, plan: dict[str, Any], *, collision_policy: str) -> dict[str, Any]:
    return osi.apply_import_plan(
        con,
        plan,
        osi.ImportApplyOptions(
            collision_policy=collision_policy,
            rollback_on_failure=True,
            validate_after_apply=True,
            warnings_as_errors=False,
        ),
    )


def main() -> int:
    con = connect()
    try:
        document, warnings = osi.export_model(
            con,
            osi.ExportOptions(model_name="sales", object_name=None, profile="lossless"),
        )
        osi.validate_document(document)
        assert_equal("source export warnings", warnings, [])

        plan = make_plan(document)
        assert_equal("import plan status", plan["status"], "ok")
        assert_true("import plan operations", len(plan["operations"]) >= 25)

        result = apply_plan(con, plan, collision_policy="replace_draft")
        assert_equal("apply status", result["status"], "ok")
        assert_true("apply operation results", len(result["operation_results"]) == len(plan["operations"]))
        assert_true("apply warnings are explicit", "OSI_IMPORT_120" in diagnostic_codes(result))
        assert_equal("validation rows", result.get("validation_rows", []), [])

        expected_counts = {
            "SEMANTIC_CATALOG.MODELS": 1,
            "SEMANTIC_CATALOG.ENTITIES": 4,
            "SEMANTIC_CATALOG.RELATIONSHIPS": 3,
            "SEMANTIC_CATALOG.DIMENSIONS": 4,
            "SEMANTIC_CATALOG.FACTS": 3,
            "SEMANTIC_CATALOG.METRICS": 5,
            "SEMANTIC_CATALOG.SYNONYMS": 3,
        }
        for table_name, expected in expected_counts.items():
            assert_equal(
                f"imported {table_name}",
                scalar(con, f"SELECT COUNT(*) FROM {table_name} WHERE MODEL_NAME = {sql_string(TARGET_MODEL)}"),
                expected,
            )

        assert_equal(
            "imported semantic object",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.SEMANTIC_OBJECTS "
                f"WHERE MODEL_NAME = {sql_string(TARGET_MODEL)} AND OBJECT_NAME = 'SALES'",
            ),
            1,
        )

        compiled = compile_request(
            con,
            {
                "model": TARGET_MODEL,
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["customer_region"],
                "order_by": [{"field": "total_revenue", "direction": "desc"}],
                "limit": 2,
                "purpose": "osi_import_apply_smoke",
                "client": "verify_osi_import",
            },
        )
        assert_equal("imported compile status", compiled["status"], "OK")
        assert_contains("imported compile SQL", compiled["generated_sql"], 'c.region AS "customer_region"')
        assert_contains("imported compile SQL metric", compiled["generated_sql"], "SUM((ol.quantity * ol.net_unit_price))")
        revenue_rows = fetchall(con, compiled["generated_sql"])
        assert_equal("imported query rows", revenue_rows, [("North", "3635"), ("West", "1500")])

        collision = apply_plan(con, plan, collision_policy="fail")
        assert_equal("collision status", collision["status"], "blocked")
        assert_true("collision diagnostic", "OSI_APPLY_010" in diagnostic_codes(collision))
    finally:
        con.close()
    print("ok OSI import verifier")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
