"""Two semantic views share a dimension only when they define it the same way.

Dimension names are unique per model, so a dimension two views both list is one
row. Semantic DDL in a second view that declared a name the first already listed
used to take that row over, silently redefining the first view's column. It may
now declare it only with the same entity, expression and type, and then both
views list the one dimension; any other definition is refused as
SEMANTIC_DDL_096, from either view, naming the views that list it.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "shared_dimensions"
SRC = "SHAREDDIM_SRC"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL_IF_EXISTS('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        con.execute(statement)
    con.commit()


def apply(con: Any, statement: str) -> dict[str, Any]:
    row = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{support.sql_string(statement)}, FALSE)"))
    assert row is not None
    return row


def ship_mode(view: str, expression: str = "o.ship_mode",
              data_type: str = "VARCHAR(20)") -> str:
    return (f"ALTER SEMANTIC VIEW {MODEL}.{view} REPLACE DIMENSIONS (DIMENSION ship_mode"
            f" ON ENTITY orders AS {expression} RETURNS {data_type} COMMENT 'Ship mode')")


def listings(con: Any) -> list[tuple[str, str]]:
    """Each view that lists ship_mode, with the dimension's stored expression."""
    rows = con.execute(
        "SELECT so.OBJECT_NAME, d.EXPRESSION FROM SYS_SEMANTIC.DIMENSIONS d"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = d.MODEL_ID"
        " JOIN SYS_SEMANTIC.OBJECT_COLUMNS oc"
        "   ON oc.COLUMN_KIND = 'DIMENSION' AND oc.OBJECT_REF_ID = d.DIMENSION_ID"
        " JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID"
        f" WHERE m.MODEL_NAME = '{MODEL}' AND d.DIMENSION_NAME = 'ship_mode'"
        " ORDER BY so.OBJECT_NAME").fetchall()
    return [(str(name), str(expression)) for name, expression in rows]


def answer(con: Any, view: str, metric: str) -> list[tuple[Any, ...]]:
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    compiled = support.compile_request(con, {"model": MODEL, "object": view,
                                             "dimensions": ["ship_mode"],
                                             "metrics": [metric]})
    assert compiled["status"] == "OK", compiled["error_message"]
    return sorted((str(mode), float(value))
                  for mode, value in con.execute(compiled["generated_sql"]).fetchall())


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0),"
                " SHIP_MODE VARCHAR(20), AMOUNT DECIMAL(18,2), FREIGHT DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1, 'AIR', 10, 1), (2, 'AIR', 20, 2),"
                " (3, 'SEA', 5, 4)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Shared dimensions', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SHIPPING', 'orders', 'Shipping')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    for view, metric, column in (("SALES", "revenue", "amount"),
                                 ("SHIPPING", "freight", "freight")):
        applied = apply(con, ship_mode(view).replace(
            "'Ship mode')",
            f"'Ship mode') REPLACE FACTS (FACT {column} ON ENTITY orders AS o.{column}"
            f" RETURNS DECIMAL(18,2) ADDITIVE) REPLACE METRICS (METRIC {metric}"
            f" AS SUM({column}) ON ENTITY orders RETURNS DECIMAL(36,2) ADDITIVE)"))
        assert applied["status"] == "OK", applied
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_two_views_list_one_dimension(model: Any) -> None:
    assert listings(model) == [("SALES", "o.ship_mode"), ("SHIPPING", "o.ship_mode")]
    assert not support.blocking_issues(support.validate_model(model, MODEL))


def test_each_view_answers_by_the_shared_dimension(model: Any) -> None:
    assert answer(model, "SALES", "revenue") == [("AIR", 30.0), ("SEA", 5.0)]
    assert answer(model, "SHIPPING", "freight") == [("AIR", 3.0), ("SEA", 4.0)]


def test_the_same_definition_spelled_differently_is_shared(model: Any) -> None:
    applied = apply(model, ship_mode("SHIPPING", 'O."SHIP_MODE"', "varchar( 20 )"))
    assert applied["status"] == "OK", applied
    assert len(listings(model)) == 2


@pytest.mark.parametrize("view, other", [("SHIPPING", "SALES"), ("SALES", "SHIPPING")])
def test_another_definition_is_refused_from_either_view(model: Any, view: str,
                                                        other: str) -> None:
    refused = apply(model, ship_mode(view, "UPPER(o.ship_mode)"))
    assert refused["status"] == "ERROR", refused
    assert refused["error_code"] == "SEMANTIC_DDL_096", refused
    assert f"semantic view(s) {other}" in refused["message"]
    assert listings(model) == [("SALES", "o.ship_mode"), ("SHIPPING", "o.ship_mode")]


def test_a_dimension_no_other_view_lists_is_redefined(model: Any) -> None:
    left = apply(model, f"ALTER SEMANTIC VIEW {MODEL}.SHIPPING REPLACE DIMENSIONS"
                        " (DIMENSION order_id ON ENTITY orders AS o.order_id"
                        " RETURNS DECIMAL(18,0))")
    assert left["status"] == "OK", left
    redefined = apply(model, ship_mode("SALES", "UPPER(o.ship_mode)"))
    assert redefined["status"] == "OK", redefined
    assert listings(model) == [("SALES", "UPPER(o.ship_mode)")]


@pytest.fixture
def two_roots(con: Any) -> Iterator[Any]:
    """SALES rooted at orders, CUSTOMERS at customer; both list customer's region."""
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0),"
                " CUSTOMER_KEY DECIMAL(18,0), AMOUNT DECIMAL(18,2))")
    con.execute(f"CREATE TABLE {SRC}.CUSTOMERS (CUSTOMER_KEY DECIMAL(18,0),"
                " REGION VARCHAR(20), CREDIT DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1, 1, 10), (2, 1, 20), (3, 2, 5)")
    con.execute(f"INSERT INTO {SRC}.CUSTOMERS VALUES (1, 'EU', 100), (2, 'US', 50),"
                " (3, 'US', 25)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Shared dimensions', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_UNIQUE_KEY({m}, 'orders', 'orders_pk', 'PRIMARY', 'Order', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
        f"ADD_ENTITY({m}, 'customer', '{SRC}', 'CUSTOMERS', 'c', 'c.customer_key',"
        " 'One customer', 'Customers')",
        f"ADD_UNIQUE_KEY({m}, 'customer', 'customer_pk', 'PRIMARY', 'Customer', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'customer', 'customer_pk', 'CUSTOMER_KEY', NULL, 1)",
        f"ADD_RELATIONSHIP({m}, 'orders_customer', 'orders', 'customer',"
        " 'o.CUSTOMER_KEY = c.CUSTOMER_KEY', 'MANY_TO_ONE', 'LEFT', NULL)",
        f"ADD_RELATIONSHIP_KEY_MAPPING({m}, 'orders_customer', 'CUSTOMER_KEY', NULL,"
        " 'CUSTOMER_KEY', NULL, 1)",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_SEMANTIC_OBJECT({m}, 'CUSTOMERS', 'customer', 'Customers')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    region = ("REPLACE DIMENSIONS (DIMENSION region ON ENTITY customer AS c.region"
              " RETURNS VARCHAR(20))")
    for view, entity, fact, column, metric in (
            ("SALES", "orders", "amount", "o.amount", "revenue"),
            ("CUSTOMERS", "customer", "credit", "c.credit", "credit_limit")):
        applied = apply(con, f"ALTER SEMANTIC VIEW {MODEL}.{view} {region}"
                             f" REPLACE FACTS (FACT {fact} ON ENTITY {entity} AS {column}"
                             " RETURNS DECIMAL(18,2) ADDITIVE)"
                             f" REPLACE METRICS (METRIC {metric} AS SUM({fact})"
                             f" ON ENTITY {entity} RETURNS DECIMAL(36,2) ADDITIVE)")
        assert applied["status"] == "OK", applied
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_views_with_different_roots_share_a_dimension(two_roots: Any) -> None:
    assert not support.blocking_issues(support.validate_model(two_roots, MODEL))
    for view, metric, expected in (("SALES", "revenue", [("EU", 30.0), ("US", 5.0)]),
                                   ("CUSTOMERS", "credit_limit",
                                    [("EU", 100.0), ("US", 75.0)])):
        two_roots.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
        compiled = support.compile_request(two_roots, {
            "model": MODEL, "object": view, "dimensions": ["region"], "metrics": [metric]})
        assert compiled["status"] == "OK", compiled["error_message"]
        rows = two_roots.execute(compiled["generated_sql"]).fetchall()
        assert sorted((str(r), float(v)) for r, v in rows) == expected, view
