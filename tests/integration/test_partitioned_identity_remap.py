"""A joined entity anchored on a remapped representation joins through its remap.

`customer` is reached from `orders` over `o.CUSTOMER_KEY = c.CUSTOMER_KEY`, and
its `mongo` representation has no CUSTOMER_KEY: it carries the key as a
lowercase string that an F5.1 DIRECT identity binding casts back. When mongo is
the anchor for `c`, the relationship join has to read that cast.

The single-branch renderer applied it. The multi-branch renderer read the
relationship's declared condition verbatim, and an F3-partitioned object always
plans multi-branch -- so validation passed, COMPILE returned OK, and the SQL
failed at execution with `object C.CUSTOMER_KEY not found`, on a published view.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "partitioned_remap"
SRC = "PREMAP_SRC"
BOUNDARY = "2026-01-01 00:00:00"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def compile_and_run(con: Any, dimension: str) -> tuple[dict[str, Any], dict[Any, float]]:
    compiled = support.compile_request(con, {
        "model": MODEL, "object": "SALES",
        "dimensions": [dimension], "metrics": ["total_amount"]})
    assert compiled["status"] == "OK", compiled["error_message"]
    rows = con.execute(compiled["generated_sql"]).fetchall()
    return compiled, {row[0]: float(row[1]) for row in rows}


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS_HOT (ORDER_ID DECIMAL(18,0),"
                " ORDER_TS TIMESTAMP, CUSTOMER_KEY DECIMAL(18,0), AMOUNT DECIMAL(18,2))")
    con.execute(f"CREATE TABLE {SRC}.ORDERS_ARCHIVE LIKE {SRC}.ORDERS_HOT")
    con.execute(f"INSERT INTO {SRC}.ORDERS_ARCHIVE VALUES"
                " (1, TIMESTAMP '2025-11-01 00:00:00', 1, 10),"
                " (2, TIMESTAMP '2025-12-01 00:00:00', 2, 20)")
    con.execute(f"INSERT INTO {SRC}.ORDERS_HOT VALUES"
                " (3, TIMESTAMP '2026-01-15 00:00:00', 1, 30),"
                " (4, TIMESTAMP '2026-02-01 00:00:00', 2, 40)")
    con.execute(f"CREATE TABLE {SRC}.CUSTOMERS_MDM (CUSTOMER_KEY DECIMAL(18,0),"
                " REGION VARCHAR(20), TIER VARCHAR(20))")
    con.execute(f"INSERT INTO {SRC}.CUSTOMERS_MDM VALUES"
                " (1, 'mdm-north', 'Gold'), (2, 'mdm-south', 'Silver')")
    # No CUSTOMER_KEY: the key is a lowercase string, as a document store
    # exposes it. Customer 2 has no tier here, so COALESCE has to reach MDM;
    # where both have one they agree, as SEMANTIC_MODEL_045 requires.
    con.execute(f'CREATE TABLE {SRC}.CUSTOMERS_MONGO ("customer_id" VARCHAR(20),'
                ' "region" VARCHAR(20), "tier" VARCHAR(20))')
    con.execute(f"INSERT INTO {SRC}.CUSTOMERS_MONGO VALUES"
                " ('1', 'North', 'Gold'), ('2', 'South', NULL)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Partitioned remap', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS_HOT', 'o', 'o.order_id',"
        " 'One order', 'Orders')",
        f"ADD_UNIQUE_KEY({m}, 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
        f"ADD_ENTITY_REPRESENTATION({m}, 'orders', 'archive', 'RELATION', '{SRC}',"
        " 'ORDERS_ARCHIVE', 20, 'MANUAL')",
        f"SET_REPRESENTATION_COVERAGE({m}, 'orders', 'archive', 'o.order_ts < TIMESTAMP"
        f" ''{BOUNDARY}''', NULL, TIMESTAMP '{BOUNDARY}')",
        f"SET_REPRESENTATION_COVERAGE({m}, 'orders', 'primary', 'o.order_ts >= TIMESTAMP"
        f" ''{BOUNDARY}''', TIMESTAMP '{BOUNDARY}', NULL)",
        f"ADD_ENTITY({m}, 'customer', '{SRC}', 'CUSTOMERS_MDM', 'c', 'c.customer_key',"
        " 'One customer', 'Customers')",
        f"ADD_UNIQUE_KEY({m}, 'customer', 'customer_pk', 'PRIMARY', 'Customer', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'customer', 'customer_pk', 'CUSTOMER_KEY', NULL, 1)",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_RELATIONSHIP({m}, 'orders_customer', 'orders', 'customer',"
        " 'o.CUSTOMER_KEY = c.CUSTOMER_KEY', 'MANY_TO_ONE', 'LEFT', NULL)",
        f"ADD_RELATIONSHIP_KEY_MAPPING({m}, 'orders_customer', 'CUSTOMER_KEY', NULL,"
        " 'CUSTOMER_KEY', NULL, 1)",
        f"ADD_FACT({m}, 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Amount', 'Order amount', FALSE, TRUE)",
        f"REPLACE_ATTRIBUTE_BINDING({m}, 'FACT', 'amount', 'archive', 'o.amount', 'PREFER', 1)",
        f"ADD_DIMENSION({m}, 'SALES', 'customer', 'customer_region', 'c.region',"
        " 'VARCHAR(20)', 'Region', 'Customer region', NULL, TRUE)",
        f"ADD_DIMENSION({m}, 'SALES', 'customer', 'customer_tier', 'c.tier',"
        " 'VARCHAR(20)', 'Tier', 'Customer tier', NULL, TRUE)",
        f"ADD_ENTITY_REPRESENTATION({m}, 'customer', 'mongo', 'RELATION', '{SRC}',"
        " 'CUSTOMERS_MONGO', 20, 'MANUAL')",
        # Region: mongo is preferred, so it anchors `c` outright.
        f"REPLACE_ATTRIBUTE_BINDING({m}, 'DIMENSION', 'customer_region', 'primary',"
        " 'c.region', 'FALLBACK', 20)",
        f"ADD_ATTRIBUTE_BINDING({m}, 'DIMENSION', 'customer_region', 'mongo',"
        " 'c.\"region\"', 'PREFER', 1)",
        # Tier: fused, both FALLBACK, and mongo's lower priority makes it the
        # anchor -- the shape of the report.
        f"REPLACE_ATTRIBUTE_BINDING({m}, 'DIMENSION', 'customer_tier', 'primary',"
        " 'c.tier', 'FALLBACK', 100)",
        f"ADD_ATTRIBUTE_BINDING({m}, 'DIMENSION', 'customer_tier', 'mongo',"
        " 'c.\"tier\"', 'FALLBACK', 99)",
        f"SET_ATTRIBUTE_FUSION_POLICY({m}, 'DIMENSION', 'customer_tier', 'COALESCE')",
        f"ADD_SEMANTIC_IDENTITY({m}, 'customer', 'cid', 'GLOBAL', 'DECIMAL(18,0)', 'Customer')",
        f"ADD_IDENTITY_BINDING({m}, 'cid', 'primary', 'c.CUSTOMER_KEY', 'DIRECT')",
        f"ADD_IDENTITY_BINDING({m}, 'cid', 'mongo',"
        " 'CAST(c.\"customer_id\" AS DECIMAL(18,0))', 'DIRECT')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
                f"'ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE METRICS (METRIC total_amount AS"
                " SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)',"
                " FALSE)")
    con.commit()
    blocking = support.blocking_issues(support.validate_model(con, MODEL))
    assert not blocking, blocking
    try:
        yield con
    finally:
        teardown(con)


def test_a_preferred_remapped_anchor_joins_through_its_remap(model: Any) -> None:
    compiled, totals = compile_and_run(model, "customer_region")
    sql = compiled["generated_sql"]
    assert "UNION ALL" in sql, "the object is partitioned, so the plan is multi-branch"
    assert 'CAST(c."customer_id" AS DECIMAL(18,0))' in sql
    assert totals == {"North": 40, "South": 60}


def test_a_fused_dimension_anchored_on_the_remapped_source_executes(model: Any) -> None:
    _, totals = compile_and_run(model, "customer_tier")
    assert totals == {"Gold": 40, "Silver": 60}


def test_the_plan_records_the_remap_it_applied(model: Any) -> None:
    compiled, _ = compile_and_run(model, "customer_region")
    plan = json.loads(compiled["plan_json"])
    remaps = plan.get("relationship_identity_remaps") or []
    assert [(r["relationship_name"], r["representation_name"]) for r in remaps] == \
        [("orders_customer", "mongo")]
