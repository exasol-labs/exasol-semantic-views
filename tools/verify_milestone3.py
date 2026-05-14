#!/usr/bin/env python3
"""Verify Milestone 3 structured request compilation on Exasol Nano."""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any


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


def scalar(con, sql: str) -> int:
    rows = con.execute(sql).fetchall()
    return int(rows[0][0])


def compile_request(con, request: dict[str, Any] | str) -> dict[str, Any]:
    payload = request if isinstance(request, str) else json.dumps(request, separators=(",", ":"))
    rows = con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})").fetchall()
    if len(rows) != 1:
        raise AssertionError(f"expected one compiler row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "generated_sql": row[3],
        "plan_json": row[4],
        "clarification_json": row[5],
        "validation_run_id": row[6],
        "agent_request_id": row[7],
    }


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_contains(name: str, text: str, expected: str) -> None:
    if expected not in text:
        raise AssertionError(f"{name}: expected to find {expected!r} in {text!r}")
    print(f"ok {name}: found {expected!r}")


def assert_float_rows(name: str, actual: list[tuple[Any, ...]], expected: list[tuple[str, float]]) -> None:
    if len(actual) != len(expected):
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    for actual_row, expected_row in zip(actual, expected, strict=True):
        if actual_row[0] != expected_row[0] or abs(float(actual_row[1]) - expected_row[1]) > 0.000001:
            raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_status_ok(name: str, result: dict[str, Any]) -> None:
    if result["status"] != "OK":
        raise AssertionError(f"{name}: expected OK, got {result}")
    if not result["generated_sql"]:
        raise AssertionError(f"{name}: compiler did not return generated SQL")
    if not result["plan_json"]:
        raise AssertionError(f"{name}: compiler did not return plan JSON")
    print(f"ok {name}: OK")


def fetchall(con, sql: str) -> list[tuple[Any, ...]]:
    return [tuple(row) for row in con.execute(sql).fetchall()]


def main() -> int:
    con = connect()
    try:
        assert_equal(
            "compiler scripts",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_SCRIPTS "
                "WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN' "
                "AND SCRIPT_NAME IN ('COMPILER_RUNTIME', 'COMPILE_REQUEST_JSON')",
            ),
            2,
        )

        before_logs = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_REQUEST_LOG")

        revenue_by_region = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["customer_region"],
                "order_by": [{"field": "total_revenue", "direction": "desc"}],
                "limit": 2,
                "purpose": "milestone3_smoke",
                "client": "verify_milestone3",
            },
        )
        assert_status_ok("revenue by region compile", revenue_by_region)
        sql = revenue_by_region["generated_sql"]
        assert_contains("revenue SQL selects region", sql, 'c.region AS "customer_region"')
        assert_contains("revenue SQL expands fact", sql, "SUM((ol.quantity * ol.net_unit_price))")
        assert_contains("revenue SQL joins customers", sql, '"MART"."CUSTOMERS" c ON o.customer_id = c.customer_id')
        assert_contains("revenue SQL groups", sql, "GROUP BY c.region")
        assert_contains("revenue SQL orders", sql, 'ORDER BY "total_revenue" DESC')

        revenue_rows = fetchall(con, sql)
        assert_equal(
            "revenue by region rows",
            revenue_rows,
            [("North", "3635"), ("West", "1500")],
        )
        plan = json.loads(revenue_by_region["plan_json"])
        assert_equal("plan validation id", plan["validation_run_id"], int(revenue_by_region["validation_run_id"]))
        assert_equal("plan metric", plan["metrics"], ["total_revenue"])

        synonym_request = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["revenue"],
                "dimensions": ["region"],
                "limit": 1,
                "client": "verify_milestone3",
            },
        )
        assert_status_ok("synonym compile", synonym_request)
        assert_contains("synonym resolved metric", synonym_request["generated_sql"], '"total_revenue"')
        assert_contains("synonym resolved dimension", synonym_request["generated_sql"], '"customer_region"')

        margin_pct = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["gross_margin_pct"],
                "dimensions": ["customer_region"],
                "filters": [{"field": "order_status", "op": "=", "value": "COMPLETE"}],
                "order_by": [{"field": "customer_region", "direction": "asc"}],
                "client": "verify_milestone3",
            },
        )
        assert_status_ok("gross margin pct compile", margin_pct)
        assert_contains("margin SQL expands derived metric", margin_pct["generated_sql"], "NULLIF")
        assert_contains("margin SQL filters dimensions", margin_pct["generated_sql"], "WHERE UPPER(o.order_status) = UPPER('COMPLETE')")
        margin_rows = fetchall(con, margin_pct["generated_sql"])
        assert_float_rows(
            "gross margin pct rows",
            margin_rows,
            [
                ("North", 0.317744),
                ("South", 0.555556),
            ],
        )

        completed = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["completed_revenue"],
                "dimensions": ["product_category"],
                "filters": [{"field": "order_month", "op": ">=", "value": "2026-02-01"}],
                "order_by": [{"field": "completed_revenue", "direction": "desc"}],
                "client": "verify_milestone3",
            },
        )
        assert_status_ok("filtered metric compile", completed)
        assert_contains("filtered metric CASE", completed["generated_sql"], "SUM(CASE WHEN o.order_status = 'COMPLETE'")
        assert_equal(
            "completed revenue rows",
            fetchall(con, completed["generated_sql"]),
            [("Bikes", "2200"), ("Accessories", "75")],
        )

        unknown = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["not_a_metric"],
                "dimensions": ["customer_region"],
                "client": "verify_milestone3",
            },
        )
        assert_equal("unknown field status", unknown["status"], "ERROR")
        assert_equal("unknown field code", unknown["error_code"], "SEMANTIC_REQUEST_020")

        bad_limit = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["customer_region"],
                "limit": 10001,
                "client": "verify_milestone3",
            },
        )
        assert_equal("bad limit status", bad_limit["status"], "ERROR")
        assert_equal("bad limit code", bad_limit["error_code"], "SEMANTIC_REQUEST_051")

        bad_json = compile_request(con, '{"model":')
        assert_equal("bad JSON status", bad_json["status"], "ERROR")
        assert_equal("bad JSON code", bad_json["error_code"], "SEMANTIC_REQUEST_001")

        after_logs = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_REQUEST_LOG")
        assert_equal("agent request logs", after_logs - before_logs, 7)
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
