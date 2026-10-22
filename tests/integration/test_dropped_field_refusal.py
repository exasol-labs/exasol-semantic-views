"""A dropped field is reported as dropped, not guessed at.

After `DROP METRIC gross_margin_pct` (a percentage), asking for it answered
`Unknown semantic field: gross_margin_pct. Did you mean: gross_margin?` -- a
currency metric -- and the one-token fix, `gross_margin AS gross_margin_pct`,
shipped a dashboard reading "Gross Margin % 123000.0%". Every lane now says the
field was dropped (`_029`) and suggests nothing, and a near-miss suggestion
carries each candidate's format so the caller can see two different numbers.

Warnings reach the agent surface too: VALIDATION_ERRORS_FOR_AGENT showed none
while MODELS_FOR_AGENT said WARNING.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "dropped_field"
SRC = "DROPFIELD_SRC"
PUBLISHED = f"SEMANTIC_{MODEL.upper()}"


def ddl(con: Any, statement: str) -> None:
    rows = support.named_rows(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{support.sql_string(statement)}, FALSE)"))
    assert rows and rows[0]["status"] == "OK", rows
    con.commit()


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {PUBLISHED} CASCADE",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


@pytest.fixture(scope="module")
def model() -> Iterator[Any]:
    con = support.connect()
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), REGION VARCHAR(20),"
                " REVENUE DECIMAL(18,2), COST DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1, 'North', 100, 60), (2, 'South', 50, 40)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, '{PUBLISHED}', 'Dropped fields', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    ddl(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE DIMENSIONS (DIMENSION region ON ENTITY orders AS o.region RETURNS VARCHAR(20)
  DISPLAY 'Region' PUBLIC CERTIFIED)""")
    ddl(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE FACTS (
  FACT revenue ON ENTITY orders AS o.revenue RETURNS DECIMAL(18,2) ADDITIVE PUBLIC,
  FACT cost ON ENTITY orders AS o.cost RETURNS DECIMAL(18,2) ADDITIVE PUBLIC)""")
    ddl(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE METRICS (
  METRIC total_revenue AS SUM(revenue) ON ENTITY orders RETURNS DECIMAL(18,2)
    FORMAT 'currency' UNIT 'EUR' ADDITIVE PUBLIC CERTIFIED,
  METRIC gross_margin AS SUM(revenue) - SUM(cost) ON ENTITY orders RETURNS DECIMAL(18,2)
    FORMAT 'currency' UNIT 'EUR' DERIVED PUBLIC CERTIFIED,
  METRIC gross_margin_pct AS (SUM(revenue) - SUM(cost)) / NULLIF(SUM(revenue), 0)
    ON ENTITY orders RETURNS DOUBLE FORMAT 'percentage' UNIT 'fraction' RATIO PUBLIC CERTIFIED,
  METRIC order_count AS COUNT(revenue) ON ENTITY orders RETURNS DECIMAL(18,0)
    ADDITIVE PUBLIC)""")
    assert not support.blocking_issues(support.validate_model(con, MODEL))
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    con.commit()
    ddl(con, f"ALTER SEMANTIC VIEW {MODEL}.SALES DROP METRIC gross_margin_pct")
    try:
        yield con
    finally:
        teardown(con)
        con.close()


def test_structured_request_says_the_field_was_dropped(model: Any) -> None:
    compiled = support.compile_request(model, {
        "model": MODEL, "object": "SALES", "metrics": ["gross_margin_pct"]})
    assert compiled["error_code"] == "SEMANTIC_REQUEST_029"
    assert "was dropped" in compiled["error_message"]
    assert "Did you mean" not in compiled["error_message"]
    assert compiled["clarification_json"] is None


def test_semantic_sql_says_the_field_was_dropped(model: Any) -> None:
    compiled = support.compile_sql(
        model, f"SELECT region, gross_margin_pct FROM {PUBLISHED}.SALES")
    assert compiled["error_code"] == "SEMANTIC_QUERY_029", compiled["error_message"]
    assert "Did you mean" not in compiled["error_message"]


def test_reference_expansion_says_the_field_was_dropped(model: Any) -> None:
    # Through the preprocessor, where a subquery over the object is read by
    # reference expansion. (COMPILE_SQL keeps its own lane's _003 for this
    # shape, as it does for any unknown field there.)
    lane = support.connect()
    try:
        lane.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        outcome = support.outcome(lane, f"SELECT x.region FROM (SELECT region, gross_margin_pct"
                                        f" FROM {PUBLISHED}.SALES) x")
    finally:
        lane.close()
    assert outcome[0] == "refused" and "SEMANTIC_QUERY_029" in str(outcome[1]), outcome


def test_a_near_miss_shows_each_candidates_format(model: Any) -> None:
    compiled = support.compile_request(model, {
        "model": MODEL, "object": "SALES", "metrics": ["gross_marg"]})
    assert compiled["error_code"] == "SEMANTIC_REQUEST_020"
    clarification = json.loads(compiled["clarification_json"])
    assert "gross_margin" in clarification["candidates"]
    assert clarification["candidate_formats"]["gross_margin"] == "currency"


def test_warnings_reach_the_agent_surface(model: Any) -> None:
    # order_count is a public numeric metric with no format or unit hint.
    issues = model.execute(
        "SELECT SEVERITY, RULE_CODE FROM SEMANTIC_AGENT.VALIDATION_ISSUES_FOR_AGENT"
        f" WHERE MODEL_NAME = '{MODEL}'").fetchall()
    assert ("WARNING", "SEMANTIC_MODEL_022") in [tuple(row) for row in issues]
    errors = model.execute(
        "SELECT COUNT(*) FROM SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT"
        f" WHERE MODEL_NAME = '{MODEL}'").fetchone()[0]
    assert errors == 0
