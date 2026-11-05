"""A rebuild can drop its model without first asking whether it exists.

A pipeline that rebuilds a model from source -- a dbt hook -- starts every run
from a clean slate, the first one included, and DROP_MODEL refuses a model that
is not there with SEMANTIC_ADMIN_011. DROP_MODEL_IF_EXISTS drops it the same
way, or reports NOT_FOUND; only a missing model is absorbed.
"""

from __future__ import annotations

from typing import Any

import pytest

import verify_support as support

MODEL = "drop_if_exists"


def drop(con: Any, name: str) -> dict[str, Any]:
    row = support.named_row(con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL_IF_EXISTS('{name}')"))
    assert row is not None
    return row


def test_a_missing_model_is_reported_not_refused(con: Any) -> None:
    with pytest.raises(Exception, match="SEMANTIC_ADMIN_011"):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
    assert drop(con, MODEL)["status"] == "NOT_FOUND"


def test_an_existing_model_is_dropped_as_drop_model_drops_it(con: Any) -> None:
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('{MODEL}',"
                f" 'SEMANTIC_{MODEL.upper()}', 'Drop if exists', NULL)")
    dropped = drop(con, MODEL)
    assert (dropped["model_name"], dropped["status"]) == (MODEL, "DROPPED")
    assert con.execute("SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS"
                       f" WHERE MODEL_NAME = '{MODEL}'").fetchval() == 0
    assert drop(con, MODEL)["status"] == "NOT_FOUND"


def test_a_dropped_model_leaves_no_rows_behind(semantic_con: Any) -> None:
    # A rebuild drops and re-creates the model on every run. DROP_MODEL left
    # the model's frozen-view records and source-trust rows, and the reviews
    # of its evolution suggestions, behind each time.
    con = semantic_con
    views = f"{MODEL.upper()}_VIEWS"
    m = f"'{MODEL}'"
    try:
        con.execute(f"CREATE SCHEMA IF NOT EXISTS {views}")
        con.execute(f"CREATE OR REPLACE TABLE {views}.ONE_ROW (ID DECIMAL(18,0), LABEL VARCHAR(10))")
        con.execute(f"INSERT INTO {views}.ONE_ROW VALUES (1, 'one')")
        for statement in (
            f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Drop if exists', NULL)",
            f"ADD_ENTITY({m}, 'row', '{views}', 'ONE_ROW', 'r', 'r.ID', 'One row', 'Row')",
            f"ADD_SEMANTIC_OBJECT({m}, 'ONE', 'row', 'One')",
            f"ADD_DIMENSION({m}, 'ONE', 'row', 'label', 'r.LABEL', 'VARCHAR(10)', 'Label',"
            " 'The label', NULL, TRUE)",
            f"PUBLISH_MODEL({m})",
        ):
            con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
        con.execute(f"CREATE OR REPLACE VIEW {views}.V AS SELECT label FROM SEMANTIC_{MODEL.upper()}.ONE")
        suggestion = support.named_row(con.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION({m}, 'DRIFT_REPAIR', 'MODEL',"
            " NULL, '{\"note\": \"x\"}', 'Probe')"))
        assert suggestion is not None
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION("
                    f"{suggestion['suggestion_id']}, 'REJECTED', 'Probe')")
        model_id = con.execute(
            f"SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = '{MODEL}'").fetchval()

        def remaining() -> dict[str, int]:
            counts = {table: con.execute(f"SELECT COUNT(*) FROM SYS_SEMANTIC.{table}"
                                         f" WHERE MODEL_ID = {model_id}").fetchval()
                      for table in ("FROZEN_VIEWS", "SOURCE_TRUST")}
            counts["MODEL_EVOLUTION_REVIEWS"] = con.execute(
                "SELECT COUNT(*) FROM SYS_SEMANTIC.MODEL_EVOLUTION_REVIEWS"
                f" WHERE SUGGESTION_ID = {suggestion['suggestion_id']}").fetchval()
            return counts

        assert all(remaining().values()), remaining()
        assert drop(con, MODEL)["status"] == "DROPPED"
        assert remaining() == {"FROZEN_VIEWS": 0, "SOURCE_TRUST": 0, "MODEL_EVOLUTION_REVIEWS": 0}
    finally:
        con.execute(f"DROP SCHEMA IF EXISTS {views} CASCADE")
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL_IF_EXISTS('{MODEL}')")


def test_any_other_refusal_still_raises(con: Any) -> None:
    with pytest.raises(Exception, match="SEMANTIC_ADMIN_001"):
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL_IF_EXISTS(NULL)")
