"""A published model's version reads as published, and shows that it changes.

A model has one version, which authoring edits in place. PUBLISH_MODEL set the
model's status and left the version row as CREATE_MODEL wrote it, so
SYS_SEMANTIC.MODEL_VERSIONS and SEMANTIC_CATALOG.MODEL_VERSIONS described a
repeatedly edited, published model as an unpublished DRAFT. The version row now
follows the model, the catalog view reads the model's status rather than
restating it, and the view carries the DEFINITION_HASH that moves when the
version's content does.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "version_status"
SRC = "VERSTATUS_SRC"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def version(con: Any) -> dict[str, Any]:
    catalog = support.named_row(con.execute(
        "SELECT STATUS, DEFINITION_HASH FROM SEMANTIC_CATALOG.MODEL_VERSIONS"
        f" WHERE MODEL_NAME = '{MODEL}'"))
    stored = con.execute(
        "SELECT mv.STATUS FROM SYS_SEMANTIC.MODEL_VERSIONS mv"
        " JOIN SYS_SEMANTIC.MODELS m ON m.ACTIVE_VERSION_ID = mv.VERSION_ID"
        f" WHERE m.MODEL_NAME = '{MODEL}'").fetchone()[0]
    assert catalog is not None
    return {"catalog": catalog["status"], "stored": stored,
            "hash": catalog["definition_hash"]}


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), AMOUNT DECIMAL(18,2))")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Version status', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_FACT({m}, 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Amount', 'Order amount', FALSE, TRUE)",
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


def publish(con: Any) -> None:
    assert not support.blocking_issues(support.validate_model(con, MODEL))
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")


def test_an_unpublished_model_reads_draft(model: Any) -> None:
    state = version(model)
    assert (state["catalog"], state["stored"]) == ("DRAFT", "DRAFT")
    assert state["hash"]


def test_publishing_publishes_the_version(model: Any) -> None:
    publish(model)
    state = version(model)
    assert (state["catalog"], state["stored"]) == ("PUBLISHED", "PUBLISHED")


def test_an_edit_after_publishing_moves_the_hash_not_the_status(model: Any) -> None:
    publish(model)
    before = version(model)
    applied = support.named_row(model.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"'ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE METRIC order_total AS"
        " SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE', FALSE)"))
    assert applied is not None and applied["status"] == "OK", applied
    after = version(model)
    assert after["catalog"] == "PUBLISHED"
    assert after["hash"] != before["hash"]
