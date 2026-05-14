#!/usr/bin/env python3
"""Verify Milestone 4 SQL compiler, surface views, and preprocessor on Nano."""

from __future__ import annotations

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


def compile_sql(con, sql: str) -> dict[str, Any]:
    rows = fetchall(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL({sql_string(sql)})")
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
        "error_code": row[1],
        "error_message": row[2],
        "original_sql": row[3],
        "generated_sql": row[4],
        "plan_json": row[5],
        "clarification_json": row[6],
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


def assert_status_ok(name: str, result: dict[str, Any]) -> None:
    if result["status"] != "OK":
        raise AssertionError(f"{name}: expected OK, got {result}")
    if not result["generated_sql"]:
        raise AssertionError(f"{name}: compiler did not return generated SQL")
    print(f"ok {name}: OK")


def assert_fails_with(con, name: str, sql: str, expected: str) -> None:
    try:
        con.execute(sql).fetchall()
    except Exception as exc:  # pyexasol wraps database errors.
        assert_contains(name, str(exc), expected)
        return
    raise AssertionError(f"{name}: expected failure containing {expected!r}")


def main() -> int:
    con = connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")

        script_names = (
            "'COMPILER_RUNTIME', 'COMPILE_SQL', 'COMPILE_SQL_DEBUG', 'SEMANTIC_PREPROCESSOR', "
            "'SEMANTIC_GUARD', 'PUBLISH_MODEL', 'REFRESH_SEMANTIC_SURFACE', "
            "'ENABLE_SEMANTIC_SQL', 'DISABLE_SEMANTIC_SQL'"
        )
        assert_equal(
            "milestone4 scripts",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_SCRIPTS "
                "WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN' "
                f"AND SCRIPT_NAME IN ({script_names})",
            ),
            9,
        )

        publish_rows = fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")
        assert_equal("published objects", publish_rows, [("sales", "SEMANTIC_SALES", "SALES", 9, "PUBLISHED")])
        assert_equal(
            "published model status",
            fetchall(con, "SELECT STATUS FROM SEMANTIC_CATALOG.MODELS WHERE MODEL_NAME = 'sales'"),
            [("PUBLISHED",)],
        )

        assert_equal(
            "published view",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_VIEWS "
                "WHERE VIEW_SCHEMA = 'SEMANTIC_SALES' AND VIEW_NAME = 'SALES'",
            ),
            1,
        )
        assert_contains(
            "published view comment",
            fetchall(
                con,
                "SELECT VIEW_COMMENT FROM SYS.EXA_ALL_VIEWS "
                "WHERE VIEW_SCHEMA = 'SEMANTIC_SALES' AND VIEW_NAME = 'SALES'",
            )[0][0],
            "ENABLE_SEMANTIC_SQL",
        )
        assert_equal(
            "published view columns",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_COLUMNS "
                "WHERE COLUMN_SCHEMA = 'SEMANTIC_SALES' "
                "AND COLUMN_TABLE = 'SALES' "
                "AND COLUMN_NAME IN ('CUSTOMER_REGION', 'TOTAL_REVENUE')",
            ),
            2,
        )

        assert_fails_with(
            con,
            "guard without preprocessor",
            "SELECT customer_region FROM SEMANTIC_SALES.SALES",
            "SEMANTIC_SURFACE_001",
        )

        semantic_sql = (
            "SELECT customer_region, total_revenue "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region "
            "ORDER BY total_revenue DESC "
            "LIMIT 2"
        )
        compiled = compile_sql(con, semantic_sql)
        assert_status_ok("COMPILE_SQL semantic query", compiled)
        assert_contains("COMPILE_SQL generated grouping", compiled["generated_sql"], "GROUP BY c.region")
        assert_equal(
            "COMPILE_SQL generated rows",
            fetchall(con, compiled["generated_sql"]),
            [("North", "3635"), ("West", "1500")],
        )

        query_log_before = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.QUERY_LOG")
        debug = compile_sql_debug(con, semantic_sql, "verify_milestone4")
        assert_status_ok("COMPILE_SQL_DEBUG semantic query", debug)
        if debug["query_log_id"] is None:
            raise AssertionError("COMPILE_SQL_DEBUG did not return a query log id")
        assert_equal(
            "COMPILE_SQL_DEBUG query log",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.QUERY_LOG"),
            query_log_before + 1,
        )

        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        validation_runs_before = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.VALIDATION_RUNS")
        assert_equal(
            "preprocessed semantic query rows",
            fetchall(con, semantic_sql),
            [("North", "3635"), ("West", "1500")],
        )
        validation_runs_after = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.VALIDATION_RUNS")
        assert_equal("preprocessor validation hot path", validation_runs_after, validation_runs_before)
        assert_equal("non-semantic query unchanged", scalar(con, "SELECT COUNT(*) FROM MART.CUSTOMERS"), 4)
        assert_contains(
            "published discovery table unchanged",
            repr(fetchall(con, "SELECT ENTRY_NAME, ENTRY_VALUE FROM SEMANTIC_SALES.SEMANTIC_DISCOVERY ORDER BY ENTRY_NAME")),
            "MCP_GUIDANCE",
        )

        assert_fails_with(
            con,
            "unsupported semantic SQL",
            "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES",
            "SEMANTIC_QUERY_007",
        )
    finally:
        try:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        finally:
            con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
