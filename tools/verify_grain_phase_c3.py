#!/usr/bin/env python3
"""Verify executable Phase C3 multi-fact planning against Exasol."""

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
        print("pyexasol is required.", file=sys.stderr)
        raise SystemExit(2)
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def rows(con, statement: str) -> list[tuple[Any, ...]]:
    return con.execute(statement).fetchall()


def execute_script(con, statement: str) -> list[tuple[Any, ...]]:
    result = con.execute("EXECUTE SCRIPT " + statement)
    if result.columns():
        return result.fetchall()
    return []


def active_count(con, table: str, name_column: str, name: str) -> int:
    result = rows(
        con,
        f"SELECT COUNT(*) FROM SYS_SEMANTIC.{table} x "
        "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = x.MODEL_ID "
        "AND m.ACTIVE_VERSION_ID = x.VERSION_ID "
        f"WHERE UPPER(m.MODEL_NAME) = 'SALES' AND UPPER(x.{name_column}) = "
        + sql_string(name.upper()),
    )
    return int(result[0][0])


def visible_metric_count(con, metric_name: str) -> int:
    result = rows(
        con,
        "SELECT COUNT(*) FROM SYS_SEMANTIC.OBJECT_COLUMNS oc "
        "JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID "
        "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = so.MODEL_ID "
        "AND m.ACTIVE_VERSION_ID = so.VERSION_ID "
        "JOIN SYS_SEMANTIC.METRICS mt ON mt.METRIC_ID = oc.OBJECT_REF_ID "
        "WHERE UPPER(m.MODEL_NAME) = 'SALES' AND UPPER(so.OBJECT_NAME) = 'SALES' "
        "AND oc.COLUMN_KIND = 'METRIC' AND oc.IS_VISIBLE = TRUE "
        f"AND UPPER(mt.METRIC_NAME) = {sql_string(metric_name.upper())}",
    )
    return int(result[0][0])


def ensure_fixture(con) -> None:
    con.execute("DROP TABLE IF EXISTS MART.SUPPORT_TICKETS")
    con.execute(
        "CREATE TABLE MART.SUPPORT_TICKETS ("
        "TICKET_ID DECIMAL(18,0) PRIMARY KEY, "
        "CUSTOMER_ID DECIMAL(18,0) NOT NULL)"
    )
    con.execute(
        "INSERT INTO MART.SUPPORT_TICKETS VALUES "
        "(2001, 1), (2002, 1), (2003, 2), (2004, 4), (2005, 4), (2006, 4)"
    )

    if active_count(con, "ENTITIES", "ENTITY_NAME", "support_ticket") == 0:
        execute_script(
            con,
            "SEMANTIC_ADMIN.ADD_ENTITY("
            "'sales', 'support_ticket', 'MART', 'SUPPORT_TICKETS', 't', "
            "'t.ticket_id', 'One row per support ticket', 'C3 multi-fact fixture')",
        )
    if active_count(con, "UNIQUE_KEYS", "KEY_NAME", "support_ticket_pk") == 0:
        execute_script(
            con,
            "SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
            "'sales', 'support_ticket', 'support_ticket_pk', 'PRIMARY', "
            "'Support-ticket row grain', 'NATIVE')",
        )
        execute_script(
            con,
            "SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
            "'sales', 'support_ticket', 'support_ticket_pk', 'ticket_id', NULL, 1)",
        )
    if active_count(con, "RELATIONSHIPS", "RELATIONSHIP_NAME", "ticket_to_customer") == 0:
        execute_script(
            con,
            "SEMANTIC_ADMIN.ADD_RELATIONSHIP("
            "'sales', 'ticket_to_customer', 'support_ticket', 'customer', "
            "'t.customer_id = c.customer_id', 'MANY_TO_ONE', 'LEFT', NULL)",
        )
        execute_script(
            con,
            "SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
            "'sales', 'ticket_to_customer', 'customer_id', NULL, "
            "'customer_id', NULL, 1)",
        )
    if active_count(con, "FACTS", "FACT_NAME", "ticket_row") == 0:
        execute_script(
            con,
            "SEMANTIC_ADMIN.ADD_FACT("
            "'sales', 'support_ticket', 'ticket_row', 't.ticket_id', "
            "'DECIMAL(18,0)', 'ADDITIVE', 'Ticket Row', "
            "'One countable support ticket', FALSE, TRUE)",
        )
    if active_count(con, "METRICS", "METRIC_NAME", "ticket_count") == 0:
        definition = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC ticket_count
  AS COUNT(ticket_row)
  ON ENTITY support_ticket
  RETURNS DECIMAL(18,0)
  DISPLAY 'Ticket Count'
  COMMENT 'Number of support tickets'
  FORMAT 'count'
  ADDITIVE PRIVATE CERTIFIED"""
        result = execute_script(
            con,
            f"SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_string(definition)}, FALSE)",
        )
        if result and result[0][0] == "ERROR":
            issues = rows(
                con,
                "SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE "
                "FROM SYS_SEMANTIC.VALIDATION_RESULTS "
                f"WHERE VALIDATION_RUN_ID = {int(result[0][5])}",
            )
            raise AssertionError(
                f"ticket_count definition failed: {result[0]}; issues={issues}"
            )
    if visible_metric_count(con, "support_ticket_count") == 0:
        definition = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC support_ticket_count
  AS ticket_count + 0
  ON ENTITY order_line
  RETURNS DECIMAL(18,0)
  FORMAT 'count'
  DISPLAY 'Support Ticket Count'
  COMMENT 'Number of support tickets'
  DERIVED PUBLIC CERTIFIED"""
        result = execute_script(
            con,
            f"SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_string(definition)}, FALSE)",
        )
        if result and result[0][0] == "ERROR":
            raise AssertionError(f"support_ticket_count definition failed: {result[0]}")
    if visible_metric_count(con, "revenue_per_ticket") == 0:
        definition = """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC revenue_per_ticket
  AS total_revenue / NULLIF(ticket_count, 0)
  ON ENTITY order_line
  RETURNS DECIMAL(18,6)
  DISPLAY 'Revenue per Ticket'
  COMMENT 'Revenue divided by support-ticket count'
  RATIO PUBLIC CERTIFIED"""
        result = execute_script(
            con,
            f"SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_string(definition)}, FALSE)",
        )
        if result and result[0][0] == "ERROR":
            raise AssertionError(f"revenue_per_ticket definition failed: {result[0]}")
    execute_script(con, "SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")


def compile_json(con, request: dict[str, Any]) -> tuple[Any, ...]:
    payload = json.dumps(request, separators=(",", ":"))
    result = execute_script(
        con, f"SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    )
    if not result:
        raise AssertionError("JSON compiler returned no row")
    return result[0]


def compile_sql(con, statement: str) -> tuple[Any, ...]:
    result = execute_script(
        con, f"SEMANTIC_ADMIN.COMPILE_SQL({sql_string(statement)})"
    )
    if not result:
        raise AssertionError("SQL compiler returned no row")
    return result[0]


def assert_equal(label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")
    print(f"ok {label}: {actual!r}")


def assert_true(label: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(label)
    print(f"ok {label}")


def normalized_result(result: list[tuple[Any, ...]]) -> list[tuple[str, int, str, str]]:
    return [
        (str(region), int(ticket_count), str(revenue), str(ratio))
        for region, ticket_count, revenue, ratio in result
    ]


def main() -> int:
    con = connect()
    try:
        ensure_fixture(con)
        request = {
            "model": "sales",
            "object": "SALES",
            "metrics": ["support_ticket_count", "total_revenue", "revenue_per_ticket"],
            "dimensions": ["customer_region"],
            "having": [{"field": "revenue_per_ticket", "op": ">", "value": 100}],
            "order_by": [{"field": "revenue_per_ticket", "direction": "DESC"}],
        }
        compiled = compile_json(con, request)
        if compiled[0] != "OK":
            raise AssertionError(
                f"JSON compile failed: code={compiled[1]!r}, message={compiled[2]!r}, "
                f"plan={compiled[5]!r}"
            )
        assert_equal("JSON compile status", compiled[0], "OK")
        assert_equal("JSON compile error", compiled[1], None)
        assert_true("JSON generated SQL", bool(compiled[4]))
        plan = json.loads(compiled[5])
        assert_equal("plan version", plan["plan_version"], 5)
        logical = plan["logical_plan"]
        assert_equal("logical kind", logical["plan_kind"], "MULTI_BRANCH")
        assert_equal("logical execution", logical["execution"]["status"], "EXECUTABLE")
        assert_equal("physical execution", logical["physical_plan"]["execution"]["status"], "EXECUTABLE")
        assert_equal("branch count", len(logical["physical_plan"]["branches"]), 2)
        json_values = normalized_result(rows(con, compiled[4]))
        assert_equal(
            "JSON values",
            json_values,
            [("North", 5, "3635", "727.0"), ("South", 1, "135", "135.0")],
        )

        semantic_statement = """SELECT customer_region,
  MEASURE(support_ticket_count), MEASURE(total_revenue), MEASURE(revenue_per_ticket)
FROM SEMANTIC_SALES.SALES
GROUP BY ALL
HAVING revenue_per_ticket > 100
ORDER BY revenue_per_ticket DESC"""
        semantic = compile_sql(con, semantic_statement)
        assert_equal("Semantic SQL compile status", semantic[0], "OK")
        semantic_plan = json.loads(semantic[5])
        assert_equal(
            "input-lane logical plans",
            semantic_plan["logical_plan"],
            logical,
        )
        assert_equal(
            "Semantic SQL values",
            normalized_result(rows(con, semantic[4])),
            json_values,
        )

        sparse_request = dict(request)
        sparse_request.pop("having")
        sparse_request.pop("order_by")
        sparse = compile_json(con, sparse_request)
        sparse_values = normalized_result(rows(con, sparse[4]))
        west = [value for value in sparse_values if value[0] == "West"]
        assert_equal("sparse branch count finalizer", west[0][1], 0)
        assert_equal("sparse ratio remains null", west[0][3], "None")
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
