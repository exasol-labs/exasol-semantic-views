"""An evolution proposal goes stale when the model's definition changes.

The guard compared a suggestion's VERSION_ID with the model's active version.
Authoring mutates a model's one version in place, so nothing ever advanced it:
a proposal made before a material change read IS_STALE = FALSE and was
certified against a model it no longer described. Staleness is now measured on
the model's DEFINITION_HASH, which moves exactly when a definition does.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "evolution_stale"
SRC = "EVOSTALE_SRC"
PAYLOAD = '{"source_column":"STATUS","observed_type":"VARCHAR(40)"}'


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def propose(con: Any) -> dict[str, Any]:
    row = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION("
        f"'{MODEL}', 'DRIFT_REPAIR', 'ENTITY', 'orders', {support.sql_string(PAYLOAD)},"
        " 'Source metadata differs from the last reviewed model.')"))
    assert row is not None
    return row


def is_stale(con: Any, suggestion_id: int) -> bool:
    return bool(con.execute(
        "SELECT IS_STALE FROM SEMANTIC_CATALOG.MODEL_EVOLUTION_SUGGESTIONS"
        f" WHERE SUGGESTION_ID = {suggestion_id}").fetchone()[0])


def review(con: Any, suggestion_id: int, decision: str) -> Any:
    return con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION("
                       f"{suggestion_id}, '{decision}', 'Reviewed.')")


def change_model(con: Any) -> None:
    applied = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"'ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE METRIC order_count AS"
        " COUNT(order_id) ON ENTITY orders RETURNS DECIMAL(18,0) ADDITIVE', FALSE)"))
    assert applied is not None and applied["status"] == "OK", applied


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), AMOUNT DECIMAL(18,2))")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Evolution staleness', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_FACT({m}, 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Amount', 'Order amount', FALSE, TRUE)",
        f"ADD_FACT({m}, 'orders', 'order_id', 'o.order_id', 'DECIMAL(18,0)', 'ADDITIVE',"
        " 'Order', 'Order id', FALSE, TRUE)",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
                f"'ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE METRICS (METRIC total_amount AS"
                " SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE)', FALSE)")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_a_proposal_on_an_unchanged_model_is_current(model: Any) -> None:
    created = propose(model)
    assert not is_stale(model, created["suggestion_id"])
    assert propose(model)["is_duplicate"] is True
    assert support.named_row(review(model, created["suggestion_id"], "CERTIFIED"))[
        "review_status"] == "CERTIFIED"


def test_a_material_change_makes_a_proposal_stale(model: Any) -> None:
    created = propose(model)
    change_model(model)
    assert is_stale(model, created["suggestion_id"])
    with pytest.raises(Exception, match="SEMANTIC_AGENT_044.*definition has changed"):
        review(model, created["suggestion_id"], "CERTIFIED")
    # Rejecting a stale proposal is still allowed: it is the way out.
    assert support.named_row(review(model, created["suggestion_id"], "REJECTED"))[
        "review_status"] == "REJECTED"


def test_reproposing_after_a_change_yields_a_certifiable_suggestion(model: Any) -> None:
    stale = propose(model)
    change_model(model)
    fresh = propose(model)
    assert fresh["is_duplicate"] is False
    assert fresh["suggestion_id"] != stale["suggestion_id"]
    assert not is_stale(model, fresh["suggestion_id"])
    assert support.named_row(review(model, fresh["suggestion_id"], "CERTIFIED"))[
        "review_status"] == "CERTIFIED"
