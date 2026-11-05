"""A materialization built from an earlier definition is not used.

A field keeps its id when it is redefined, so a materialization's column
mapping still resolved after `ADD OR REPLACE METRIC`, and the compiler kept
answering from an aggregate computed with the old formula -- the live sources
said one thing and the governed query another, and nothing reported it. Each
mapped column now records the definition it was built from; a redefined field
makes the selector read the sources instead (DEFINITION_CHANGED), validation
says which aggregate to rebuild (SEMANTIC_MODEL_077), and marking the object
refreshed puts it back in service.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "materialization_definition"
SRC = "MATDEF_SRC"
QUERY = f"SELECT status, total_amount FROM SEMANTIC_{MODEL.upper()}.SALES"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def compiled(con: Any) -> tuple[str | None, list[str], dict[str, float]]:
    """The materialization chosen, why others were rejected, and the answer."""
    result = support.compile_sql(con, QUERY)
    assert result["status"] == "OK", result["error_message"]
    decision = json.loads(result["plan_json"])["materialization_decision"]
    rows = con.execute(result["generated_sql"]).fetchall()
    selected = decision.get("selected_materialization")
    return (selected if isinstance(selected, str) else None,
            [r["reason_code"] for r in decision.get("rejected_materializations") or []],
            {row[0]: float(row[1]) for row in rows})


def redefine(con: Any, expression: str) -> None:
    applied = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"'ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE METRIC total_amount AS"
        f" {expression} ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE', FALSE)"))
    assert applied is not None and applied["status"] == "OK", applied


def mark_refreshed(con: Any) -> None:
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.MARK_MATERIALIZATION_REFRESHED("
                f"'{MODEL}', 'by_status', NULL, NULL)")


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), STATUS VARCHAR(20),"
                " AMOUNT DECIMAL(18,2), DISCOUNT DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES"
                " (1, 'OPEN', 10, 1), (2, 'OPEN', 20, 2), (3, 'SHIPPED', 40, 4)")
    # The aggregate a refresh job built for SUM(amount).
    con.execute(f"CREATE TABLE {SRC}.BY_STATUS AS SELECT STATUS, SUM(AMOUNT) AS TOTAL_AMOUNT"
                f" FROM {SRC}.ORDERS GROUP BY STATUS")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Materialization definition', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_DIMENSION({m}, 'SALES', 'orders', 'status', 'o.status', 'VARCHAR(20)',"
        " 'Status', 'Order status', NULL, TRUE)",
        f"ADD_FACT({m}, 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Amount', 'Order amount', FALSE, TRUE)",
        f"ADD_FACT({m}, 'orders', 'discount', 'o.discount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Discount', 'Order discount', FALSE, TRUE)",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
                f"'ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE METRICS (METRIC total_amount AS"
                " SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE)', FALSE)")
    for statement in (
        f"REGISTER_MATERIALIZATION({m}, 'by_status', '{SRC}', 'BY_STATUS', 'AGGREGATE',"
        " 'MANUAL')",
        f"ADD_MATERIALIZATION_COLUMN({m}, 'by_status', 'DIMENSION', 'status', 'STATUS', 'DIRECT')",
        f"ADD_MATERIALIZATION_COLUMN({m}, 'by_status', 'METRIC', 'total_amount',"
        " 'TOTAL_AMOUNT', 'SUM')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_the_aggregate_serves_the_definition_it_was_built_from(model: Any) -> None:
    selected, _, totals = compiled(model)
    assert selected == "by_status"
    assert totals == {"OPEN": 30, "SHIPPED": 40}


def test_a_redefined_metric_is_answered_by_the_sources(model: Any) -> None:
    redefine(model, "SUM(amount) - SUM(discount)")
    selected, rejected, totals = compiled(model)
    assert selected is None
    assert rejected == ["DEFINITION_CHANGED"]
    assert totals == {"OPEN": 27, "SHIPPED": 36}  # the new definition, not the aggregate
    warnings = [issue for issue in support.validate_model(model, MODEL)
                if issue["rule_code"] == "SEMANTIC_MODEL_077"]
    assert len(warnings) == 1 and "metric total_amount" in warnings[0]["message"]


def test_marking_the_rebuilt_aggregate_refreshed_restores_it(model: Any) -> None:
    redefine(model, "SUM(amount) - SUM(discount)")
    model.execute(f"DELETE FROM {SRC}.BY_STATUS")
    model.execute(f"INSERT INTO {SRC}.BY_STATUS SELECT STATUS, SUM(AMOUNT) - SUM(DISCOUNT)"
                  f" FROM {SRC}.ORDERS GROUP BY STATUS")
    mark_refreshed(model)
    selected, rejected, totals = compiled(model)
    assert (selected, rejected) == ("by_status", [])
    assert totals == {"OPEN": 27, "SHIPPED": 36}
    assert not [issue for issue in support.validate_model(model, MODEL)
                if issue["rule_code"] == "SEMANTIC_MODEL_077"]
