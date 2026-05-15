#!/usr/bin/env python3
"""Verify Milestone 6 materialization selection on Exasol Nano."""

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
        "original_sql": row[3],
        "generated_sql": row[4],
        "plan_json": row[5],
        "clarification_json": row[6],
        "validation_run_id": row[7],
        "agent_request_id": row[8],
    }


def compile_sql(con, sql: str) -> dict[str, Any]:
    rows = fetchall(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL({sql_string(sql)})")
    if len(rows) != 1:
        raise AssertionError(f"expected one compiler row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "generated_sql": row[4],
        "plan_json": row[5],
        "validation_run_id": row[7],
    }


def compile_sql_debug(con, sql: str, client_name: str) -> dict[str, Any]:
    rows = fetchall(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL_DEBUG("
        f"{sql_string(sql)}, {sql_string(client_name)})",
    )
    if len(rows) != 1:
        raise AssertionError(f"expected one debug compiler row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "generated_sql": row[4],
        "plan_json": row[5],
        "validation_run_id": row[7],
        "query_log_id": row[8],
    }


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_contains(name: str, text: str, expected: str) -> None:
    if expected not in text:
        raise AssertionError(f"{name}: expected to find {expected!r} in {text!r}")
    print(f"ok {name}: found {expected!r}")


def assert_not_contains(name: str, text: str, unexpected: str) -> None:
    if unexpected in text:
        raise AssertionError(f"{name}: did not expect {unexpected!r} in {text!r}")
    print(f"ok {name}: absent {unexpected!r}")


def assert_status_ok(name: str, result: dict[str, Any]) -> None:
    if result["status"] != "OK":
        raise AssertionError(f"{name}: expected OK, got {result}")
    if not result["generated_sql"]:
        raise AssertionError(f"{name}: compiler did not return generated SQL")
    if not result["plan_json"]:
        raise AssertionError(f"{name}: compiler did not return plan JSON")
    print(f"ok {name}: OK")


def selected_materialization(result: dict[str, Any]) -> str | None:
    plan = json.loads(result["plan_json"])
    selected = plan.get("selected_materialization")
    if isinstance(selected, dict):
        return selected.get("materialization_name")
    return None


def revenue_request(client: str) -> dict[str, Any]:
    return {
        "model": "sales",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "order_by": [{"field": "total_revenue", "direction": "desc"}],
        "limit": 2,
        "client": client,
    }


def main() -> int:
    con = connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")

        assert_equal(
            "materialization scripts",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_SCRIPTS "
                "WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN' "
                "AND SCRIPT_NAME IN ("
                "'MATERIALIZATION_RUNTIME', 'REGISTER_MATERIALIZATION', "
                "'ADD_MATERIALIZATION_COLUMN', 'SET_MATERIALIZATION_STATUS')",
            ),
            4,
        )
        assert_equal(
            "registered materialization",
            fetchall(
                con,
                "SELECT MATERIALIZATION_NAME, STATUS "
                "FROM SEMANTIC_CATALOG.MATERIALIZATIONS "
                "WHERE MODEL_NAME = 'sales'",
            ),
            [("sales_revenue_by_region", "ACTIVE")],
        )
        assert_equal(
            "registered materialization columns",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_CATALOG.MATERIALIZATION_COLUMNS "
                "WHERE MODEL_NAME = 'sales' AND MATERIALIZATION_NAME = 'sales_revenue_by_region'",
            ),
            2,
        )

        materialized = compile_request(con, revenue_request("verify_milestone6"))
        assert_status_ok("eligible revenue compile", materialized)
        assert_equal("selected materialization", selected_materialization(materialized), "sales_revenue_by_region")
        assert_contains("materialized SQL relation", materialized["generated_sql"], '"MART"."SALES_REVENUE_BY_REGION"')
        assert_not_contains("materialized SQL skips base order lines", materialized["generated_sql"], '"MART"."ORDER_LINES"')
        assert_equal(
            "materialized rows",
            fetchall(con, materialized["generated_sql"]),
            [("North", "3635"), ("West", "1500")],
        )

        product = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["product_category"],
                "client": "verify_milestone6",
            },
        )
        assert_status_ok("missing dimension fallback", product)
        assert_equal("missing dimension materialization", selected_materialization(product), None)
        assert_contains("fallback SQL relation", product["generated_sql"], '"MART"."ORDER_LINES"')

        non_additive = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["gross_margin_pct"],
                "dimensions": ["customer_region"],
                "client": "verify_milestone6",
            },
        )
        assert_status_ok("non-additive fallback", non_additive)
        assert_equal("non-additive materialization", selected_materialization(non_additive), None)

        filtered = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["customer_region"],
                "filters": [{"field": "order_status", "op": "=", "value": "COMPLETE"}],
                "client": "verify_milestone6",
            },
        )
        assert_status_ok("filtered dimension fallback", filtered)
        assert_equal("filtered materialization", selected_materialization(filtered), None)
        assert_contains("filtered fallback predicate", filtered["generated_sql"], "WHERE UPPER(o.order_status) = UPPER('COMPLETE')")

        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MATERIALIZATION_STATUS('sales', 'sales_revenue_by_region', 'INACTIVE')")
        try:
            inactive = compile_request(con, revenue_request("verify_milestone6_inactive"))
            assert_status_ok("inactive materialization fallback", inactive)
            assert_equal("inactive selected materialization", selected_materialization(inactive), None)
            assert_contains("inactive fallback SQL relation", inactive["generated_sql"], '"MART"."ORDER_LINES"')
        finally:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MATERIALIZATION_STATUS('sales', 'sales_revenue_by_region', 'ACTIVE')")

        semantic_sql = (
            "SELECT customer_region, total_revenue "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region "
            "ORDER BY total_revenue DESC "
            "LIMIT 2"
        )
        compiled_sql = compile_sql(con, semantic_sql)
        assert_status_ok("COMPILE_SQL materialization", compiled_sql)
        assert_equal("COMPILE_SQL selected materialization", selected_materialization(compiled_sql), "sales_revenue_by_region")
        assert_equal("COMPILE_SQL rows", fetchall(con, compiled_sql["generated_sql"]), [("North", "3635"), ("West", "1500")])

        validation_runs_before = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.VALIDATION_RUNS")
        query_logs_before = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.QUERY_LOG")
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        assert_equal("preprocessed materialized rows", fetchall(con, semantic_sql), [("North", "3635"), ("West", "1500")])
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        assert_equal("preprocessor validation hot path", scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.VALIDATION_RUNS"), validation_runs_before)
        assert_equal("preprocessor query log hot path", scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.QUERY_LOG"), query_logs_before)

        debug = compile_sql_debug(con, semantic_sql, "verify_milestone6")
        assert_status_ok("COMPILE_SQL_DEBUG materialization", debug)
        assert_equal("debug selected materialization", selected_materialization(debug), "sales_revenue_by_region")
        assert_equal(
            "query log materialization used",
            fetchall(
                con,
                "SELECT MATERIALIZATION_USED FROM SYS_SEMANTIC.QUERY_LOG "
                f"WHERE QUERY_LOG_ID = {int(debug['query_log_id'])}",
            ),
            [("sales_revenue_by_region",)],
        )

        explain_agent = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL("
            f"'AGENT_REQUEST', {int(materialized['agent_request_id'])})",
        )
        assert_equal("explain agent materialization", explain_agent[0][12], "sales_revenue_by_region")
        explain_query = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL("
            f"'QUERY_LOG', {int(debug['query_log_id'])})",
        )
        assert_equal("explain query materialization", explain_query[0][12], "sales_revenue_by_region")

        materialization_count_before = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.MATERIALIZATIONS")
        suggestion_count_before = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_SUGGESTIONS")
        feedback = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK("
            f"'AGENT_REQUEST', {int(materialized['agent_request_id'])}, "
            "'NEEDS_CHANGE', 'Materialized query needs an alternate display name.', "
            "'{\"kind\":\"display_name\",\"metric\":\"total_revenue\",\"display_name\":\"Revenue\"}')",
        )
        assert_equal("materialized feedback pending", feedback[0][5], "PENDING")
        assert_equal(
            "feedback suggestion on materialized query",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_SUGGESTIONS"),
            suggestion_count_before + 1,
        )
        assert_equal(
            "feedback did not mutate materializations",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.MATERIALIZATIONS"),
            materialization_count_before,
        )
    finally:
        try:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        finally:
            con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
