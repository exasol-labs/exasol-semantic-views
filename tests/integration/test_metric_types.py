"""A published metric that compiles to a different kind of number is reported.

The published view declared GROSS_MARGIN_PCT DECIMAL(18,6) and a query returned
DOUBLE, so a typed consumer got a float where a decimal was promised, and
metadata probes disagreed with the result set. The layer reports it rather
than casting: SEMANTIC_MODEL_076 from validation of a published model, and
CHECK_METRIC_TYPES for any model on demand. A SUM that widens the precision at
the same scale is not a mismatch.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "metric_types"
SRC = "METRICTYPES_SRC"


def ddl(con: Any, statement: str) -> None:
    rows = support.named_rows(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{support.sql_string(statement)}, FALSE)"))
    con.commit()
    assert rows and rows[0]["status"] == "OK", rows


def type_warnings(con: Any) -> list[str]:
    return [issue["object_name"] for issue in support.validate_model(con, MODEL)
            if issue["rule_code"] == "SEMANTIC_MODEL_076"]


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS SEMANTIC_{MODEL.upper()} CASCADE",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


@pytest.fixture
def draft(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), REVENUE DECIMAL(18,2),"
                " COST DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1, 100, 60), (2, 50, 40)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Metric types', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    ddl(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE FACTS (
  FACT revenue ON ENTITY orders AS o.revenue RETURNS DECIMAL(18,2) ADDITIVE PUBLIC,
  FACT cost ON ENTITY orders AS o.cost RETURNS DECIMAL(18,2) ADDITIVE PUBLIC)""")
    ddl(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE METRICS (
  METRIC total_revenue AS SUM(revenue) ON ENTITY orders RETURNS DECIMAL(18,2)
    FORMAT 'currency' UNIT 'EUR' ADDITIVE PUBLIC,
  METRIC total_cost AS SUM(cost) ON ENTITY orders RETURNS DECIMAL(18,2)
    FORMAT 'currency' UNIT 'EUR' ADDITIVE PUBLIC,
  METRIC margin_pct AS (total_revenue - total_cost) / NULLIF(total_revenue, 0)
    ON ENTITY orders RETURNS DECIMAL(18,6) FORMAT 'percentage' UNIT 'fraction'
    RATIO PUBLIC)""")
    try:
        yield con
    finally:
        teardown(con)


@pytest.fixture
def published(draft: Any) -> Any:
    draft.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    draft.commit()
    return draft


def test_check_metric_types_reports_declared_against_compiled(draft: Any) -> None:
    rows = {row["metric_name"]: row for row in support.named_rows(draft.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_METRIC_TYPES('{MODEL}')"))}
    assert (rows["margin_pct"]["declared_type"], rows["margin_pct"]["compiled_type"],
            rows["margin_pct"]["compatible"]) == ("DECIMAL(18,6)", "DOUBLE", False)
    # A SUM widens the precision at the same scale: shown, but compatible.
    assert rows["total_revenue"]["compatible"] is True
    assert rows["total_revenue"]["compiled_type"].startswith("DECIMAL(")


def test_a_published_model_warns_about_the_mismatch(published: Any) -> None:
    assert type_warnings(published) == ["margin_pct"]


def test_declaring_the_compiled_type_clears_it(published: Any) -> None:
    ddl(published, f"""ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE METRIC margin_pct
  AS (total_revenue - total_cost) / NULLIF(total_revenue, 0) ON ENTITY orders
  RETURNS DOUBLE FORMAT 'percentage' UNIT 'fraction' RATIO PUBLIC""")
    assert type_warnings(published) == []


def test_a_draft_model_is_not_checked_during_validation(draft: Any) -> None:
    assert type_warnings(draft) == []


def observations(con: Any) -> dict[str, Any]:
    return {name: observed for name, observed in con.execute(
        "SELECT m.METRIC_NAME, o.OBSERVED_AT FROM SYS_SEMANTIC.METRIC_TYPE_OBSERVATIONS o"
        " JOIN SYS_SEMANTIC.METRICS m ON m.METRIC_ID = o.METRIC_ID"
        " JOIN SYS_SEMANTIC.MODELS md ON md.MODEL_ID = m.MODEL_ID"
        f" WHERE md.MODEL_NAME = '{MODEL}'").fetchall()}


def test_an_unchanged_model_reuses_what_it_observed(published: Any) -> None:
    support.validate_model(published, MODEL)
    first = observations(published)
    assert set(first) == {"total_revenue", "total_cost", "margin_pct"}
    assert type_warnings(published) == ["margin_pct"]
    assert observations(published) == first


def test_a_redefined_metric_is_compiled_again(published: Any) -> None:
    support.validate_model(published, MODEL)
    first = observations(published)
    ddl(published, f"""ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE METRIC total_cost
  AS SUM(cost) * 2 ON ENTITY orders RETURNS DECIMAL(18,2) FORMAT 'currency' UNIT 'EUR'
  ADDITIVE PUBLIC""")
    support.validate_model(published, MODEL)
    assert observations(published)["total_cost"] != first["total_cost"]


def test_a_source_column_type_change_is_compiled_again(published: Any) -> None:
    support.validate_model(published, MODEL)
    first = observations(published)
    published.execute(f"ALTER TABLE {SRC}.ORDERS MODIFY COLUMN REVENUE DECIMAL(18,4)")
    published.commit()
    support.validate_model(published, MODEL)
    assert observations(published)["total_revenue"] != first["total_revenue"]
