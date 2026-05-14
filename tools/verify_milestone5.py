#!/usr/bin/env python3
"""Verify Milestone 5 agent context and feedback workflow on Nano."""

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


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_at_least(name: str, actual: int, expected: int) -> None:
    if actual < expected:
        raise AssertionError(f"{name}: expected at least {expected}, got {actual}")
    print(f"ok {name}: {actual}")


def assert_contains(name: str, text: str, expected: str) -> None:
    if expected not in text:
        raise AssertionError(f"{name}: expected to find {expected!r} in {text!r}")
    print(f"ok {name}: found {expected!r}")


def assert_fails_with(con, name: str, sql: str, expected: str) -> None:
    try:
        con.execute(sql).fetchall()
    except Exception as exc:
        assert_contains(name, str(exc), expected)
        return
    raise AssertionError(f"{name}: expected failure containing {expected!r}")


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
        "generated_sql": row[3],
        "plan_json": row[4],
        "clarification_json": row[5],
        "validation_run_id": row[6],
        "agent_request_id": row[7],
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


def main() -> int:
    con = connect()
    try:
        agent_view_names = (
            "'MODELS_FOR_AGENT', 'OBJECTS_FOR_AGENT', 'FIELDS_FOR_AGENT', "
            "'VALID_COMBINATIONS_FOR_AGENT', 'MEASURE_GROUPS_FOR_AGENT', "
            "'VERIFIED_QUERIES_FOR_AGENT', 'INSTRUCTIONS_FOR_AGENT', "
            "'BUSINESS_GLOSSARY_FOR_AGENT', 'REQUEST_HISTORY_FOR_AGENT'"
        )
        assert_equal(
            "agent views",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_VIEWS "
                "WHERE VIEW_SCHEMA = 'SEMANTIC_AGENT' "
                f"AND VIEW_NAME IN ({agent_view_names})",
            ),
            9,
        )

        agent_script_names = (
            "'AGENT_RUNTIME', 'ADD_AGENT_INSTRUCTION', 'ADD_VERIFIED_QUERY', "
            "'SEARCH_SEMANTIC_OBJECTS', 'DESCRIBE_SEMANTIC_OBJECT', "
            "'GET_BUSINESS_GLOSSARY', 'EXPLAIN_COMPILED_SQL', "
            "'RECORD_AGENT_FEEDBACK'"
        )
        assert_equal(
            "agent scripts",
            scalar(
                con,
                "SELECT COUNT(*) FROM SYS.EXA_ALL_SCRIPTS "
                "WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN' "
                f"AND SCRIPT_NAME IN ({agent_script_names})",
            ),
            8,
        )

        assert_equal(
            "agent model readiness",
            fetchall(
                con,
                "SELECT MODEL_NAME, PUBLISHED_SCHEMA, AGENT_READINESS "
                "FROM SEMANTIC_AGENT.MODELS_FOR_AGENT "
                "WHERE MODEL_NAME = 'sales'",
            ),
            [("sales", "SEMANTIC_SALES", "VALID")],
        )
        assert_equal(
            "agent fields count",
            scalar(con, "SELECT COUNT(*) FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE MODEL_NAME = 'sales'"),
            9,
        )
        assert_equal(
            "agent sql field names",
            fetchall(
                con,
                "SELECT FIELD_NAME, SQL_COLUMN_NAME FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT "
                "WHERE MODEL_NAME = 'sales' AND FIELD_NAME IN ('customer_region', 'total_revenue') "
                "ORDER BY FIELD_NAME",
            ),
            [("customer_region", "CUSTOMER_REGION"), ("total_revenue", "TOTAL_REVENUE")],
        )
        assert_equal(
            "agent field role alias",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT "
                "WHERE MODEL_NAME = 'sales' AND FIELD_ROLE = FIELD_KIND",
            ),
            9,
        )
        assert_equal(
            "agent valid combinations",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT "
                "WHERE MODEL_NAME = 'sales' AND IS_VALID = TRUE",
            ),
            20,
        )
        assert_equal(
            "agent measure group",
            fetchall(
                con,
                "SELECT MEASURE_GROUP_NAME, METRIC_COUNT FROM SEMANTIC_AGENT.MEASURE_GROUPS_FOR_AGENT "
                "WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES'",
            ),
            [("default", 5)],
        )

        con.execute("UPDATE SYS_SEMANTIC.METRICS SET IS_PRIVATE = TRUE WHERE METRIC_NAME = 'total_cost'")
        try:
            assert_equal(
                "hidden metric not visible",
                scalar(
                    con,
                    "SELECT COUNT(*) FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT "
                    "WHERE MODEL_NAME = 'sales' AND FIELD_NAME = 'total_cost'",
                ),
                0,
            )
            hidden_search = fetchall(
                con,
                "EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS('cost', 'sales')",
            )
            if any(row[4] == "total_cost" for row in hidden_search):
                raise AssertionError(f"hidden metric leaked through search: {hidden_search!r}")
            print("ok hidden synonym search: total_cost absent")
        finally:
            con.execute("UPDATE SYS_SEMANTIC.METRICS SET IS_PRIVATE = FALSE WHERE METRIC_NAME = 'total_cost'")

        instruction_rows = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION("
            "'sales', 'METRIC', 'total_revenue', 'DEFINITION', "
            "'Use total_revenue for recognized net revenue analysis.', NULL, 10)",
        )
        assert_equal("add instruction status", instruction_rows[0][5], "ACTIVE")
        assert_equal(
            "instruction visible",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT "
                "WHERE MODEL_NAME = 'sales' AND SCOPE_NAME = 'total_revenue'",
            ),
            1,
        )
        general_instruction_rows = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION("
            "'sales', 'MODEL', 'sales', 'GENERAL', "
            "'Use current company sales definitions unless a user asks for experimental metrics.', NULL, 20)",
        )
        assert_equal("general instruction status", general_instruction_rows[0][5], "ACTIVE")
        assert_equal(
            "general instruction visible",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT "
                "WHERE MODEL_NAME = 'sales' AND SCOPE_NAME = 'sales' AND INSTRUCTION_KIND = 'GENERAL'",
            ),
            1,
        )

        request = {
            "model": "sales",
            "object": "SALES",
            "metrics": ["total_revenue"],
            "dimensions": ["customer_region"],
            "order_by": [{"field": "total_revenue", "direction": "desc"}],
            "limit": 2,
            "client": "verify_milestone5",
        }
        verified_rows = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY("
            "'sales', 'SALES', 'Revenue by region', "
            "'What is revenue by customer region?', "
            f"{sql_string(json.dumps(request, separators=(',', ':')))}, "
            "'customer_region,total_revenue', TRUE)",
        )
        assert_equal("add verified query status", verified_rows[0][4], "ACTIVE")
        assert_contains("verified generated SQL", verified_rows[0][5], 'ORDER BY "total_revenue" DESC')
        assert_equal(
            "verified query visible",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT "
                "WHERE MODEL_NAME = 'sales' AND QUERY_NAME = 'Revenue by region'",
            ),
            1,
        )

        search_rows = fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS('revenue', 'sales')")
        assert_at_least("search result count", len(search_rows), 1)
        assert_equal("search top field", search_rows[0][4], "total_revenue")

        describe_rows = fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT('sales', 'SALES')")
        assert_at_least("describe rows", len(describe_rows), 10)
        if not any(row[2] == "FIELD" and row[4] == "total_revenue" for row in describe_rows):
            raise AssertionError("describe output missing total_revenue field")
        print("ok describe includes total_revenue")

        structured_glossary = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'STRUCTURED_REQUEST')",
        )
        assert_contains("structured glossary mode", structured_glossary[0][3], "Use COMPILE_REQUEST_JSON")
        sql_glossary = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'SEMANTIC_SQL')",
        )
        assert_contains("sql glossary mode", sql_glossary[0][3], "Use semantic SQL")

        compiled = compile_request(con, request)
        assert_equal("agent compile status", compiled["status"], "OK")
        explain_agent = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL("
            f"'AGENT_REQUEST', {int(compiled['agent_request_id'])})",
        )
        assert_equal("explain agent handle", explain_agent[0][0], "AGENT_REQUEST")
        assert_contains("explain agent plan", explain_agent[0][9], '"metrics":["total_revenue"]')
        assert_contains("explain agent requested dimensions", explain_agent[0][10], "customer_region")
        assert_contains("explain agent requested metrics", explain_agent[0][11], "total_revenue")

        semantic_sql = (
            "SELECT customer_region, total_revenue "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region "
            "ORDER BY total_revenue DESC "
            "LIMIT 2"
        )
        debug = compile_sql_debug(con, semantic_sql, "verify_milestone5")
        assert_equal("sql debug status", debug["status"], "OK")
        explain_query = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL("
            f"'QUERY_LOG', {int(debug['query_log_id'])})",
        )
        assert_equal("explain query handle", explain_query[0][0], "QUERY_LOG")
        assert_contains("explain query plan", explain_query[0][9], '"metrics":["total_revenue"]')

        metric_count_before = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS")
        suggestion_count_before = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_SUGGESTIONS")
        feedback_agent = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK("
            f"'AGENT_REQUEST', {int(compiled['agent_request_id'])}, "
            "'NEEDS_CHANGE', 'Add a synonym for recognized revenue.', "
            "'{\"kind\":\"synonym\",\"metric\":\"total_revenue\",\"synonym\":\"recognized revenue\"}')",
        )
        assert_equal("agent feedback pending", feedback_agent[0][5], "PENDING")
        feedback_query = fetchall(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK("
            f"'QUERY_LOG', {int(debug['query_log_id'])}, "
            "'HELPFUL', 'SQL result matched expectation.', NULL)",
        )
        assert_equal("query feedback pending", feedback_query[0][5], "PENDING")
        feedback_count_before_invalid = scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_FEEDBACK")
        assert_fails_with(
            con,
            "invalid feedback verdict rejected",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK("
            f"'AGENT_REQUEST', {int(compiled['agent_request_id'])}, "
            "'completed_successfully', 'Invalid verdict robustness check.', NULL)",
            "SEMANTIC_AGENT_003",
        )
        assert_equal(
            "invalid feedback verdict did not insert",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_FEEDBACK"),
            feedback_count_before_invalid,
        )
        assert_equal(
            "suggestion created",
            scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_SUGGESTIONS"),
            suggestion_count_before + 1,
        )
        assert_equal("feedback no metadata mutation", scalar(con, "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS"), metric_count_before)

        assert_at_least(
            "request history rows",
            scalar(con, "SELECT COUNT(*) FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT"),
            2,
        )
        assert_equal(
            "request history request time alias",
            scalar(
                con,
                "SELECT COUNT(*) FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT "
                "WHERE REQUEST_TIME = STARTED_AT",
            ),
            scalar(con, "SELECT COUNT(*) FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT"),
        )
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
