"""A metric name belongs to one semantic view, and a second view cannot take it.

Metric names are unique per model, so Semantic DDL looks a metric up by name
alone. A second view declaring a name the first already held used to take the
row over: it rewrote the first view's definition and became a column of both
views. On a draft model nothing noticed. On a published one VALIDATE_MODEL
observed the metric once per view and crashed on METRIC_TYPE_OBSERVATIONS'
primary key, surfacing as SEMANTIC_DDL_999. It is now refused as
SEMANTIC_DDL_095, naming the view that holds the name and the DDL that frees it.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "metric_ownership"
SRC = "METRICOWN_SRC"


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


def total_amount(view: str, expression: str) -> str:
    return (f"ALTER SEMANTIC VIEW {MODEL}.{view} REPLACE METRICS (METRIC total_amount"
            f" AS {expression} ON ENTITY orders RETURNS DECIMAL(36,2) ADDITIVE)")


def holders(con: Any, metric: str) -> list[tuple[str, str]]:
    """Each view that lists the metric, with the metric's stored expression."""
    rows = con.execute(
        "SELECT so.OBJECT_NAME, mt.EXPRESSION FROM SYS_SEMANTIC.METRICS mt"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = mt.MODEL_ID"
        " JOIN SYS_SEMANTIC.OBJECT_COLUMNS oc"
        "   ON oc.COLUMN_KIND = 'METRIC' AND oc.OBJECT_REF_ID = mt.METRIC_ID"
        " JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID"
        f" WHERE m.MODEL_NAME = '{MODEL}' AND mt.METRIC_NAME = '{metric}'"
        " ORDER BY so.OBJECT_NAME").fetchall()
    return [(str(name), str(expression)) for name, expression in rows]


@pytest.fixture(params=["draft", "published"])
def model(request: Any, con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0),"
                " AMOUNT DECIMAL(18,2), DISCOUNT DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1, 10, 1), (2, 20, 2)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Metric ownership', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_SEMANTIC_OBJECT({m}, 'FINANCE', 'orders', 'Finance')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    applied = apply(con, f"ALTER SEMANTIC VIEW {MODEL}.SALES"
                         " REPLACE FACTS (FACT amount ON ENTITY orders AS o.amount"
                         " RETURNS DECIMAL(18,2) ADDITIVE,"
                         " FACT discount ON ENTITY orders AS o.discount"
                         " RETURNS DECIMAL(18,2) ADDITIVE)"
                         " REPLACE METRICS (METRIC total_amount AS SUM(amount)"
                         " ON ENTITY orders RETURNS DECIMAL(36,2) ADDITIVE)")
    assert applied["status"] == "OK", applied
    # FINANCE needs a metric of its own to publish.
    applied = apply(con, f"ALTER SEMANTIC VIEW {MODEL}.FINANCE REPLACE METRICS"
                         " (METRIC total_discount AS SUM(discount) ON ENTITY orders"
                         " RETURNS DECIMAL(36,2) ADDITIVE)")
    assert applied["status"] == "OK", applied
    if request.param == "published":
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_another_views_metric_name_is_refused(model: Any) -> None:
    refused = apply(model, total_amount("FINANCE", "SUM(discount)"))
    assert refused["status"] == "ERROR", refused
    assert refused["error_code"] == "SEMANTIC_DDL_095", refused
    assert "semantic view SALES" in refused["message"]
    assert f"ALTER SEMANTIC VIEW {MODEL}.SALES DROP METRIC total_amount" in refused["message"]


def test_the_refusal_leaves_the_owning_view_as_it_was(model: Any) -> None:
    apply(model, total_amount("FINANCE", "SUM(discount)"))
    assert holders(model, "total_amount") == [("SALES", "SUM(amount)")]
    assert not support.blocking_issues(support.validate_model(model, MODEL))


def test_the_owning_view_still_redefines_its_metric(model: Any) -> None:
    redefined = apply(model, total_amount("SALES", "SUM(amount) - SUM(discount)"))
    assert redefined["status"] == "OK", redefined
    assert holders(model, "total_amount") == [("SALES", "SUM(amount) - SUM(discount)")]


def test_a_dropped_name_can_move_to_another_view(model: Any) -> None:
    dropped = apply(model, f"ALTER SEMANTIC VIEW {MODEL}.SALES DROP METRIC total_amount")
    assert dropped["status"] == "OK", dropped
    moved = apply(model, total_amount("FINANCE", "SUM(discount)"))
    assert moved["status"] == "OK", moved
    assert holders(model, "total_amount") == [("FINANCE", "SUM(discount)")]
