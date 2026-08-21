#!/usr/bin/env python3
"""Verify the maintained D1/D2 multi-fact execution lane against Exasol.

The fixture is isolated from the bundled sales model. It exercises three fact
branches and compares ESV output with an independently aggregated reference
query across base, hybrid, and materialized branch-source plans.
"""

from __future__ import annotations

from decimal import Decimal
import json
import os
import ssl
import sys
from typing import Any


MODEL = "grain_d1"
OBJECT = "D1_METRICS"
DATA_SCHEMA = "GRAIN_D1_DATA"


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


def assert_equal(label: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{label}: expected {expected!r}, got {actual!r}")
    print(f"ok {label}: {actual!r}")


def assert_true(label: str, condition: bool) -> None:
    if not condition:
        raise AssertionError(label)
    print(f"ok {label}")


def model_count(con) -> int:
    return int(
        rows(
            con,
            "SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS "
            f"WHERE UPPER(MODEL_NAME) = {sql_string(MODEL.upper())}",
        )[0][0]
    )


def active_count(con, table: str, name_column: str, name: str) -> int:
    return int(
        rows(
            con,
            f"SELECT COUNT(*) FROM SYS_SEMANTIC.{table} x "
            "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = x.MODEL_ID "
            "AND m.ACTIVE_VERSION_ID = x.VERSION_ID "
            f"WHERE UPPER(m.MODEL_NAME) = {sql_string(MODEL.upper())} "
            f"AND UPPER(x.{name_column}) = {sql_string(name.upper())}",
        )[0][0]
    )


def ensure_once(
    con, table: str, name_column: str, name: str, statement: str
) -> None:
    if active_count(con, table, name_column, name) == 0:
        execute_script(con, statement)


def unique_key_column_count(con, key_name: str, column_name: str) -> int:
    return int(
        rows(
            con,
            "SELECT COUNT(*) FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS ukc "
            "JOIN SYS_SEMANTIC.UNIQUE_KEYS uk ON uk.UNIQUE_KEY_ID = ukc.UNIQUE_KEY_ID "
            "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = uk.MODEL_ID "
            "AND m.ACTIVE_VERSION_ID = uk.VERSION_ID "
            f"WHERE UPPER(m.MODEL_NAME) = {sql_string(MODEL.upper())} "
            f"AND UPPER(uk.KEY_NAME) = {sql_string(key_name.upper())} "
            f"AND UPPER(ukc.COLUMN_NAME) = {sql_string(column_name.upper())}",
        )[0][0]
    )


def relationship_mapping_count(con, relationship_name: str) -> int:
    return int(
        rows(
            con,
            "SELECT COUNT(*) FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS rkm "
            "JOIN SYS_SEMANTIC.RELATIONSHIPS r "
            "ON r.RELATIONSHIP_ID = rkm.RELATIONSHIP_ID "
            "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = r.MODEL_ID "
            "AND m.ACTIVE_VERSION_ID = r.VERSION_ID "
            f"WHERE UPPER(m.MODEL_NAME) = {sql_string(MODEL.upper())} "
            f"AND UPPER(r.RELATIONSHIP_NAME) = {sql_string(relationship_name.upper())}",
        )[0][0]
    )


def reset_physical_fixture(con) -> None:
    con.execute(f"CREATE SCHEMA IF NOT EXISTS {DATA_SCHEMA}")
    for table in (
        "D2_FINAL_RATIO_BY_REGION",
        "D2_PAYMENTS_BY_REGION",
        "D2_TICKETS_BY_REGION",
        "D2_ORDERS_BY_REGION",
        "D1_ORDERS",
        "D1_TICKETS",
        "D1_PAYMENTS",
        "D1_CUSTOMERS",
    ):
        con.execute(f"DROP TABLE IF EXISTS {DATA_SCHEMA}.{table}")
    con.execute(
        f"CREATE TABLE {DATA_SCHEMA}.D1_CUSTOMERS ("
        "CUSTOMER_ID DECIMAL(18,0) PRIMARY KEY, REGION VARCHAR(32))"
    )
    con.execute(
        f"INSERT INTO {DATA_SCHEMA}.D1_CUSTOMERS VALUES "
        "(1, 'North'), (2, 'South'), (3, 'West'), (4, 'North'), (5, 'East')"
    )
    con.execute(
        f"CREATE TABLE {DATA_SCHEMA}.D1_ORDERS ("
        "ORDER_ID DECIMAL(18,0) PRIMARY KEY, CUSTOMER_ID DECIMAL(18,0), "
        "AMOUNT DECIMAL(18,2))"
    )
    con.execute(
        f"INSERT INTO {DATA_SCHEMA}.D1_ORDERS VALUES "
        "(1, 1, 100), (2, 1, 50), (3, 2, 40), (4, 4, 25), "
        "(5, 999, 7), (6, NULL, 11), (7, 5, 30)"
    )
    con.execute(
        f"CREATE TABLE {DATA_SCHEMA}.D1_TICKETS ("
        "TICKET_ID DECIMAL(18,0) PRIMARY KEY, CUSTOMER_ID DECIMAL(18,0), "
        "PRIORITY VARCHAR(16))"
    )
    con.execute(
        f"INSERT INTO {DATA_SCHEMA}.D1_TICKETS VALUES "
        "(10, 1, 'URGENT'), (11, 1, 'NORMAL'), (12, 2, 'URGENT'), "
        "(13, 4, 'URGENT'), (14, 3, 'NORMAL'), (15, 999, 'URGENT'), "
        "(16, NULL, 'NORMAL')"
    )
    con.execute(
        f"CREATE TABLE {DATA_SCHEMA}.D1_PAYMENTS ("
        "PAYMENT_ID DECIMAL(18,0) PRIMARY KEY, CUSTOMER_ID DECIMAL(18,0), "
        "AMOUNT DECIMAL(18,2))"
    )
    con.execute(
        f"INSERT INTO {DATA_SCHEMA}.D1_PAYMENTS VALUES "
        "(20, 1, 80), (21, 3, 60), (22, 4, 20), (23, 999, 5)"
    )
    con.execute(
        f"CREATE TABLE {DATA_SCHEMA}.D2_ORDERS_BY_REGION AS "
        "SELECT c.region AS customer_region, SUM(o.amount) AS order_revenue "
        f"FROM {DATA_SCHEMA}.D1_ORDERS o LEFT JOIN {DATA_SCHEMA}.D1_CUSTOMERS c "
        "ON o.customer_id = c.customer_id GROUP BY c.region"
    )
    con.execute(
        f"CREATE TABLE {DATA_SCHEMA}.D2_TICKETS_BY_REGION AS "
        "SELECT c.region AS customer_region, COUNT(t.ticket_id) AS ticket_count_state "
        f"FROM {DATA_SCHEMA}.D1_TICKETS t LEFT JOIN {DATA_SCHEMA}.D1_CUSTOMERS c "
        "ON t.customer_id = c.customer_id GROUP BY c.region"
    )
    con.execute(
        f"CREATE TABLE {DATA_SCHEMA}.D2_PAYMENTS_BY_REGION AS "
        "SELECT c.region AS customer_region, SUM(p.amount) AS payment_total_state "
        f"FROM {DATA_SCHEMA}.D1_PAYMENTS p LEFT JOIN {DATA_SCHEMA}.D1_CUSTOMERS c "
        "ON p.customer_id = c.customer_id GROUP BY c.region"
    )
    con.execute(
        f"CREATE TABLE {DATA_SCHEMA}.D2_FINAL_RATIO_BY_REGION AS "
        "SELECT customer_region, CAST(NULL AS DECIMAL(18,6)) AS revenue_per_ticket "
        f"FROM {DATA_SCHEMA}.D2_ORDERS_BY_REGION"
    )


def materialization_column_count(
    con, materialization_name: str, object_type: str, object_name: str
) -> int:
    return int(
        rows(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.MATERIALIZATION_COLUMNS "
            f"WHERE MODEL_NAME = {sql_string(MODEL)} "
            f"AND MATERIALIZATION_NAME = {sql_string(materialization_name)} "
            f"AND OBJECT_TYPE = {sql_string(object_type)} "
            f"AND OBJECT_NAME = {sql_string(object_name)}",
        )[0][0]
    )


def ensure_materialization(
    con, name: str, physical_object: str, columns: tuple[tuple[str, str, str, str], ...]
) -> None:
    if active_count(con, "MATERIALIZATIONS", "MATERIALIZATION_NAME", name) == 0:
        execute_script(
            con,
            "SEMANTIC_ADMIN.REGISTER_MATERIALIZATION("
            f"'{MODEL}', '{name}', '{DATA_SCHEMA}', '{physical_object}', "
            "'AGGREGATE', 'MANUAL')",
        )
    for object_type, object_name, physical_column, rollup_policy in columns:
        if materialization_column_count(
            con, name, object_type, object_name
        ) == 0:
            execute_script(
                con,
                "SEMANTIC_ADMIN.ADD_MATERIALIZATION_COLUMN("
                f"'{MODEL}', '{name}', '{object_type}', '{object_name}', "
                f"'{physical_column}', '{rollup_policy}')",
            )


def set_materializations(con, status: str) -> None:
    for name in (
        "d2_orders_by_region",
        "d2_tickets_by_region",
        "d2_payments_by_region",
        "d2_final_ratio_by_region",
    ):
        execute_script(
            con,
            f"SEMANTIC_ADMIN.SET_MATERIALIZATION_STATUS('{MODEL}', '{name}', '{status}')",
        )


def ensure_model_fixture(con) -> None:
    reset_physical_fixture(con)
    if model_count(con) == 0:
        execute_script(
            con,
            "SEMANTIC_ADMIN.CREATE_MODEL("
            f"'{MODEL}', 'SEMANTIC_GRAIN_D1', "
            "'Disposable grain-aware D1 regression model', NULL)",
        )

    entities = (
        (
            "order_fact",
            "o",
            "D1_ORDERS",
            "o.order_id",
            "Order fact row",
        ),
        (
            "ticket_fact",
            "t",
            "D1_TICKETS",
            "t.ticket_id",
            "Ticket fact row",
        ),
        (
            "payment_fact",
            "p",
            "D1_PAYMENTS",
            "p.payment_id",
            "Payment fact row",
        ),
        (
            "customer",
            "c",
            "D1_CUSTOMERS",
            "c.customer_id",
            "Customer row",
        ),
    )
    for entity, alias, table, key_expr, description in entities:
        ensure_once(
            con,
            "ENTITIES",
            "ENTITY_NAME",
            entity,
            "SEMANTIC_ADMIN.ADD_ENTITY("
            f"'{MODEL}', '{entity}', '{DATA_SCHEMA}', '{table}', '{alias}', "
            f"'{key_expr}', '{description}', 'D1 isolated fixture')",
        )
        key_name = entity + "_pk"
        ensure_once(
            con,
            "UNIQUE_KEYS",
            "KEY_NAME",
            key_name,
            "SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
            f"'{MODEL}', '{entity}', '{key_name}', 'PRIMARY', "
            f"'{description}', 'NATIVE')",
        )
        key_column = {
            "order_fact": "order_id",
            "ticket_fact": "ticket_id",
            "payment_fact": "payment_id",
            "customer": "customer_id",
        }[entity]
        if unique_key_column_count(con, key_name, key_column) == 0:
            execute_script(
                con,
                "SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
                f"'{MODEL}', '{entity}', '{key_name}', '{key_column}', NULL, 1)",
            )

    ensure_once(
        con,
        "SEMANTIC_OBJECTS",
        "OBJECT_NAME",
        OBJECT,
        "SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT("
        f"'{MODEL}', '{OBJECT}', 'order_fact', 'D1 multi-fact regression object')",
    )
    for relationship, source, alias in (
        ("order_customer", "order_fact", "o"),
        ("ticket_customer", "ticket_fact", "t"),
        ("payment_customer", "payment_fact", "p"),
    ):
        ensure_once(
            con,
            "RELATIONSHIPS",
            "RELATIONSHIP_NAME",
            relationship,
            "SEMANTIC_ADMIN.ADD_RELATIONSHIP("
            f"'{MODEL}', '{relationship}', '{source}', 'customer', "
            f"'{alias}.customer_id = c.customer_id', 'MANY_TO_ONE', 'LEFT', NULL)",
        )
        if relationship_mapping_count(con, relationship) == 0:
            execute_script(
                con,
                "SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
                f"'{MODEL}', '{relationship}', 'customer_id', NULL, "
                "'customer_id', NULL, 1)",
            )

    ensure_once(
        con,
        "DIMENSIONS",
        "DIMENSION_NAME",
        "customer_region",
        "SEMANTIC_ADMIN.ADD_DIMENSION("
        f"'{MODEL}', '{OBJECT}', 'customer', 'customer_region', 'c.region', "
        "'VARCHAR(32)', 'Customer Region', 'Shared customer label', NULL, TRUE)",
    )

    definition = f"""ALTER SEMANTIC VIEW {MODEL}.{OBJECT}
REPLACE FACTS (
  FACT order_amount ON ENTITY order_fact AS o.amount
    RETURNS DECIMAL(18,2) ADDITIVE PRIVATE CERTIFIED,
  FACT ticket_row ON ENTITY ticket_fact AS t.ticket_id
    RETURNS DECIMAL(18,0) ADDITIVE PRIVATE CERTIFIED,
  FACT payment_amount ON ENTITY payment_fact AS p.amount
    RETURNS DECIMAL(18,2) ADDITIVE PRIVATE CERTIFIED
)
REPLACE METRICS (
  METRIC order_revenue AS SUM(order_amount) ON ENTITY order_fact
    RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED,
  METRIC ticket_count_state AS COUNT(ticket_row) ON ENTITY ticket_fact
    RETURNS DECIMAL(18,0) ADDITIVE PRIVATE CERTIFIED,
  METRIC urgent_ticket_count_state AS COUNT(ticket_row)
    FILTER (WHERE t.priority = 'URGENT') ON ENTITY ticket_fact
    RETURNS DECIMAL(18,0) ADDITIVE PRIVATE CERTIFIED,
  METRIC payment_total_state AS SUM(payment_amount) ON ENTITY payment_fact
    RETURNS DECIMAL(18,2) ADDITIVE PRIVATE CERTIFIED,
  METRIC ticket_count AS ticket_count_state + 0 ON ENTITY order_fact
    RETURNS DECIMAL(18,0) DERIVED PUBLIC CERTIFIED,
  METRIC urgent_ticket_count AS urgent_ticket_count_state + 0 ON ENTITY order_fact
    RETURNS DECIMAL(18,0) DERIVED PUBLIC CERTIFIED,
  METRIC payment_total AS payment_total_state + 0 ON ENTITY order_fact
    RETURNS DECIMAL(18,2) DERIVED PUBLIC CERTIFIED,
  METRIC revenue_per_ticket AS order_revenue / NULLIF(ticket_count_state, 0)
    ON ENTITY order_fact RETURNS DECIMAL(18,6) RATIO PUBLIC CERTIFIED
)"""
    applied = execute_script(
        con,
        f"SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION({sql_string(definition)}, FALSE)",
    )
    if applied and applied[0][0] == "ERROR":
        raise AssertionError(f"D1 semantic definition failed: {applied[0]}")
    validation = execute_script(con, f"SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")
    assert_true(
        "isolated model validation",
        all(issue[0] != "ERROR" for issue in validation),
    )
    ensure_materialization(
        con,
        "d2_orders_by_region",
        "D2_ORDERS_BY_REGION",
        (
            ("DIMENSION", "customer_region", "CUSTOMER_REGION", "DIRECT"),
            ("METRIC", "order_revenue", "ORDER_REVENUE", "SUM"),
        ),
    )
    ensure_materialization(
        con,
        "d2_tickets_by_region",
        "D2_TICKETS_BY_REGION",
        (
            ("DIMENSION", "customer_region", "CUSTOMER_REGION", "DIRECT"),
            ("METRIC", "ticket_count_state", "TICKET_COUNT_STATE", "SUM"),
        ),
    )
    ensure_materialization(
        con,
        "d2_payments_by_region",
        "D2_PAYMENTS_BY_REGION",
        (
            ("DIMENSION", "customer_region", "CUSTOMER_REGION", "DIRECT"),
            ("METRIC", "payment_total_state", "PAYMENT_TOTAL_STATE", "SUM"),
        ),
    )
    ensure_materialization(
        con,
        "d2_final_ratio_by_region",
        "D2_FINAL_RATIO_BY_REGION",
        (
            ("DIMENSION", "customer_region", "CUSTOMER_REGION", "DIRECT"),
            ("METRIC", "revenue_per_ticket", "REVENUE_PER_TICKET", "SUM"),
        ),
    )
    set_materializations(con, "INACTIVE")


def compile_json(con, request: dict[str, Any]) -> tuple[Any, ...]:
    payload = json.dumps(request, separators=(",", ":"))
    result = execute_script(
        con, f"SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    )
    if not result:
        raise AssertionError("JSON compiler returned no row")
    return result[0]


def compile_sql_debug(con, statement: str) -> tuple[Any, ...]:
    result = execute_script(
        con,
        "SEMANTIC_ADMIN.COMPILE_SQL_DEBUG("
        f"{sql_string(statement)}, 'grain-d1-regression')",
    )
    if not result:
        raise AssertionError("Semantic SQL compiler returned no row")
    return result[0]


def decimal_value(value: Any) -> Decimal | None:
    if value is None:
        return None
    return Decimal(str(value))


def normalized_by_region(
    result: list[tuple[Any, ...]],
) -> dict[str | None, tuple[int, int, Decimal | None, Decimal | None, Decimal | None]]:
    return {
        None if region is None else str(region): (
            int(ticket_count),
            int(urgent_count),
            decimal_value(revenue),
            decimal_value(payment_total),
            decimal_value(ratio),
        )
        for region, ticket_count, urgent_count, revenue, payment_total, ratio in result
    }


def reference_sql(region: str | None = None, grand_total: bool = False) -> str:
    filter_sql = ""
    if region is not None:
        filter_sql = f" WHERE UPPER(c.region) = UPPER({sql_string(region)})"
    dimension = "" if grand_total else "c.region AS region, "
    group = "" if grand_total else " GROUP BY c.region"
    union_dimension = "" if grand_total else "region, "
    final_dimension = "" if grand_total else "region, "
    final_group = "" if grand_total else " GROUP BY region"
    return f"""WITH
orders AS (
  SELECT {dimension}SUM(o.amount) AS revenue,
         CAST(NULL AS DECIMAL(18,0)) AS ticket_count,
         CAST(NULL AS DECIMAL(18,0)) AS urgent_count,
         CAST(NULL AS DECIMAL(18,2)) AS payment_total
  FROM {DATA_SCHEMA}.D1_ORDERS o
  LEFT JOIN {DATA_SCHEMA}.D1_CUSTOMERS c ON o.customer_id = c.customer_id
  {filter_sql}{group}
),
tickets AS (
  SELECT {dimension}CAST(NULL AS DECIMAL(18,2)) AS revenue,
         COUNT(t.ticket_id) AS ticket_count,
         COUNT(CASE WHEN t.priority = 'URGENT' THEN t.ticket_id END) AS urgent_count,
         CAST(NULL AS DECIMAL(18,2)) AS payment_total
  FROM {DATA_SCHEMA}.D1_TICKETS t
  LEFT JOIN {DATA_SCHEMA}.D1_CUSTOMERS c ON t.customer_id = c.customer_id
  {filter_sql}{group}
),
payments AS (
  SELECT {dimension}CAST(NULL AS DECIMAL(18,2)) AS revenue,
         CAST(NULL AS DECIMAL(18,0)) AS ticket_count,
         CAST(NULL AS DECIMAL(18,0)) AS urgent_count,
         SUM(p.amount) AS payment_total
  FROM {DATA_SCHEMA}.D1_PAYMENTS p
  LEFT JOIN {DATA_SCHEMA}.D1_CUSTOMERS c ON p.customer_id = c.customer_id
  {filter_sql}{group}
),
states AS (
  SELECT {union_dimension}revenue, ticket_count, urgent_count, payment_total FROM orders
  UNION ALL
  SELECT {union_dimension}revenue, ticket_count, urgent_count, payment_total FROM tickets
  UNION ALL
  SELECT {union_dimension}revenue, ticket_count, urgent_count, payment_total FROM payments
)
SELECT {final_dimension}COALESCE(SUM(ticket_count), 0) AS ticket_count,
       COALESCE(SUM(urgent_count), 0) AS urgent_count,
       SUM(revenue) AS order_revenue,
       SUM(payment_total) AS payment_total,
       SUM(revenue) / NULLIF(COALESCE(SUM(ticket_count), 0), 0) AS revenue_per_ticket
FROM states{final_group}"""


def base_request() -> dict[str, Any]:
    return {
        "model": MODEL,
        "object": OBJECT,
        "metrics": [
            "ticket_count",
            "urgent_ticket_count",
            "order_revenue",
            "payment_total",
            "revenue_per_ticket",
        ],
        "dimensions": ["customer_region"],
    }


def execute_compiled(con, compiled: tuple[Any, ...]) -> list[tuple[Any, ...]]:
    if compiled[0] != "OK":
        raise AssertionError(
            f"compile failed: code={compiled[1]!r}, message={compiled[2]!r}, "
            f"plan={compiled[5]!r}"
        )
    return rows(con, compiled[4])


def logged_runtime(con, agent_request_id: Any) -> int:
    value = rows(
        con,
        "SELECT RUNTIME_MS FROM SYS_SEMANTIC.AGENT_REQUEST_LOG "
        f"WHERE AGENT_REQUEST_ID = {int(agent_request_id)}",
    )[0][0]
    if value is None:
        raise AssertionError("planner runtime was not logged")
    return int(value)


def measure_branch_shapes(con) -> None:
    cases = (
        ("one-branch", ["order_revenue"], 1),
        ("two-branch", ["order_revenue", "ticket_count"], 2),
        (
            "three-branch",
            ["order_revenue", "ticket_count", "payment_total"],
            3,
        ),
    )
    observations = []
    for label, metrics, expected_branches in cases:
        request = {
            "model": MODEL,
            "object": OBJECT,
            "metrics": metrics,
            "dimensions": ["customer_region"],
        }
        compiled = compile_json(con, request)
        execute_compiled(con, compiled)
        logical = json.loads(compiled[5])["logical_plan"]
        if expected_branches == 1:
            assert_equal(f"{label} plan kind", logical["plan_kind"], "SINGLE_BRANCH")
            observed_branches = 1
        else:
            observed_branches = logical["physical_plan"]["safeguards"]["branch_count"]
        assert_equal(f"{label} branch count", observed_branches, expected_branches)
        observations.append(
            {
                "shape": label,
                "branches": observed_branches,
                "planner_runtime_ms": logged_runtime(con, compiled[8]),
                "sql_size_bytes": len(compiled[4].encode("utf-8")),
            }
        )
    print("ok branch-shape measurements: " + json.dumps(observations, sort_keys=True))


def main() -> int:
    con = connect()
    try:
        ensure_model_fixture(con)
        request = base_request()
        compiled = compile_json(con, request)
        actual = normalized_by_region(execute_compiled(con, compiled))
        expected = normalized_by_region(rows(con, reference_sql()))
        assert_equal("three-branch differential result", actual, expected)

        plan = json.loads(compiled[5])
        physical = plan["logical_plan"]["physical_plan"]
        assert_equal("plan version", plan["plan_version"], 10)
        assert_equal("physical plan version", physical["physical_plan_version"], 6)
        assert_equal("branch count", physical["safeguards"]["branch_count"], 3)
        assert_equal("conservative branch limit", physical["safeguards"]["branch_limit"], 8)
        assert_equal(
            "conservative SQL-size limit",
            physical["safeguards"]["sql_size_limit"],
            1_000_000,
        )
        assert_true("generated SQL size measured", physical["safeguards"]["sql_size_bytes"] > 0)
        assert_true(
            "all branch sources are explicit base sources",
            all(branch["source"]["source_kind"] == "BASE" for branch in physical["branches"]),
        )
        assert_equal(
            "distinct source objects",
            sorted(branch["source"]["physical_object"] for branch in physical["branches"]),
            ["D1_ORDERS", "D1_PAYMENTS", "D1_TICKETS"],
        )
        runtime = logged_runtime(con, compiled[8])
        assert_true("JSON planner runtime logged", runtime >= 0)

        semantic_sql = f"""SELECT customer_region,
  MEASURE(ticket_count), MEASURE(urgent_ticket_count), MEASURE(order_revenue),
  MEASURE(payment_total), MEASURE(revenue_per_ticket)
FROM SEMANTIC_GRAIN_D1.{OBJECT}
GROUP BY ALL"""
        semantic = compile_sql_debug(con, semantic_sql)
        semantic_actual = normalized_by_region(execute_compiled(con, semantic))
        assert_equal("input-lane differential result", semantic_actual, expected)
        assert_true(
            "input-lane logical plans",
            json.loads(semantic[5])["logical_plan"] == plan["logical_plan"],
        )
        query_runtime = rows(
            con,
            "SELECT RUNTIME_MS FROM SYS_SEMANTIC.QUERY_LOG "
            f"WHERE QUERY_LOG_ID = {int(semantic[8])}",
        )[0][0]
        assert_true(
            "Semantic SQL planner runtime logged",
            query_runtime is not None and int(query_runtime) >= 0,
        )

        set_materializations(con, "ACTIVE")
        hybrid_compiled = compile_json(con, request)
        hybrid_actual = normalized_by_region(execute_compiled(con, hybrid_compiled))
        assert_equal("hybrid source differential result", hybrid_actual, expected)
        hybrid_plan = json.loads(hybrid_compiled[5])
        hybrid_physical = hybrid_plan["logical_plan"]["physical_plan"]
        source_by_object = {
            branch["source"]["physical_object"]: branch["source"]["source_kind"]
            for branch in hybrid_physical["branches"]
        }
        assert_equal(
            "hybrid complete-source substitution",
            source_by_object,
            {
                "D2_ORDERS_BY_REGION": "MATERIALIZATION",
                "D1_TICKETS": "BASE",
                "D2_PAYMENTS_BY_REGION": "MATERIALIZATION",
            },
        )
        assert_true(
            "hybrid SQL skips substituted base tables",
            '"D1_ORDERS"' not in hybrid_compiled[4]
            and '"D1_PAYMENTS"' not in hybrid_compiled[4]
            and '"D1_TICKETS"' in hybrid_compiled[4],
        )
        hybrid_semantic = compile_sql_debug(con, semantic_sql)
        assert_equal(
            "hybrid Semantic SQL differential result",
            normalized_by_region(execute_compiled(con, hybrid_semantic)),
            expected,
        )
        logged_materializations = rows(
            con,
            "SELECT MATERIALIZATION_USED FROM SYS_SEMANTIC.QUERY_LOG "
            f"WHERE QUERY_LOG_ID = {int(hybrid_semantic[8])}",
        )[0][0]
        assert_equal(
            "hybrid materializations logged",
            set(str(logged_materializations).split(",")),
            {"d2_orders_by_region", "d2_payments_by_region"},
        )
        selection = hybrid_plan["materialization_decision"]
        ticket_diagnostics = next(
            branch
            for branch in selection["branches"]
            if branch["selected_materialization"] is None
        )
        assert_true(
            "partial filtered-state candidate causes whole-leaf fallback",
            any(
                rejection["materialization_name"] == "d2_tickets_by_region"
                and rejection["reason_code"] == "FILTERED_STATE_UNSUPPORTED"
                for rejection in ticket_diagnostics["rejected_materializations"]
            ),
        )
        assert_true(
            "finalized ratio candidate rejected as state source",
            any(
                rejection["materialization_name"] == "d2_final_ratio_by_region"
                and rejection["reason_code"] == "MISSING_STATE"
                for rejection in selection["rejected_materializations"]
            ),
        )

        unfiltered_request = {
            "model": MODEL,
            "object": OBJECT,
            "metrics": [
                "ticket_count",
                "order_revenue",
                "payment_total",
                "revenue_per_ticket",
            ],
            "dimensions": ["customer_region"],
        }
        all_materialized = compile_json(con, unfiltered_request)
        all_materialized_rows = {
            region: (
                int(ticket_count),
                decimal_value(revenue),
                decimal_value(payment_total),
                decimal_value(ratio),
            )
            for region, ticket_count, revenue, payment_total, ratio
            in execute_compiled(con, all_materialized)
        }
        expected_unfiltered = {
            region: (values[0], values[2], values[3], values[4])
            for region, values in expected.items()
        }
        assert_equal(
            "fully materialized private-state differential result",
            all_materialized_rows,
            expected_unfiltered,
        )
        all_materialized_plan = json.loads(all_materialized[5])
        cached_materialized = compile_json(con, unfiltered_request)
        assert_true(
            "source selection deterministic across cache",
            json.loads(cached_materialized[5]) == all_materialized_plan,
        )
        assert_equal(
            "one complete materialization per leaf",
            sorted(
                branch["source"]["source_kind"]
                for branch in all_materialized_plan["logical_plan"]["physical_plan"]["branches"]
            ),
            ["MATERIALIZATION", "MATERIALIZATION", "MATERIALIZATION"],
        )
        assert_equal(
            "private producer selected",
            sorted(
                selected["materialization_name"]
                for selected in all_materialized_plan["selected_materializations"]
            ),
            [
                "d2_orders_by_region",
                "d2_payments_by_region",
                "d2_tickets_by_region",
            ],
        )

        actual = hybrid_actual
        plan = hybrid_plan

        assert_equal("equal-label rollup revenue", actual["North"][2], Decimal("175"))
        assert_equal("same-leaf total count", actual["North"][0], 3)
        assert_equal("same-leaf filtered count", actual["North"][1], 2)
        assert_equal("sparse COUNT becomes zero", actual["East"][0], 0)
        assert_equal("sparse ratio remains null", actual["East"][4], None)
        assert_equal("orphan/null group revenue", actual[None][2], Decimal("18"))
        assert_equal("orphan/null group ticket count", actual[None][0], 2)

        filtered_request = base_request()
        filtered_request["filters"] = [
            {"field": "customer_region", "op": "=", "value": "North"}
        ]
        filtered = normalized_by_region(
            execute_compiled(con, compile_json(con, filtered_request))
        )
        filtered_reference = normalized_by_region(rows(con, reference_sql("North")))
        assert_equal("global-filter differential result", filtered, filtered_reference)

        grand_request = base_request()
        grand_request["dimensions"] = []
        grand = execute_compiled(con, compile_json(con, grand_request))[0]
        grand_reference = rows(con, reference_sql(grand_total=True))[0]
        assert_equal(
            "grand-total differential result",
            tuple(decimal_value(value) for value in grand),
            tuple(decimal_value(value) for value in grand_reference),
        )

        having_request = base_request()
        having_request["having"] = [
            {"field": "ticket_count", "op": ">", "value": 1}
        ]
        having_rows = normalized_by_region(
            execute_compiled(con, compile_json(con, having_request))
        )
        having_expected = {
            region: values for region, values in expected.items() if values[0] > 1
        }
        assert_equal("hybrid HAVING differential result", having_rows, having_expected)

        con.execute(
            f"INSERT INTO {DATA_SCHEMA}.D1_TICKETS VALUES (99, 2, 'URGENT')"
        )
        mutated = normalized_by_region(execute_compiled(con, compile_json(con, request)))
        mutated_reference = normalized_by_region(rows(con, reference_sql()))
        assert_equal("mutated differential result", mutated, mutated_reference)
        for region in actual:
            assert_equal(
                f"unrelated order state stable for {region!r}",
                mutated[region][2],
                actual[region][2],
            )
            assert_equal(
                f"unrelated payment state stable for {region!r}",
                mutated[region][3],
                actual[region][3],
            )
        assert_equal("mutated branch count", mutated["South"][0], actual["South"][0] + 1)
        assert_equal(
            "mutated filtered state",
            mutated["South"][1],
            actual["South"][1] + 1,
        )
        con.execute(f"DELETE FROM {DATA_SCHEMA}.D1_TICKETS WHERE TICKET_ID = 99")
        measure_branch_shapes(con)
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
