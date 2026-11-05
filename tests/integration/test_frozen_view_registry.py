"""A frozen view is reported once, as it now stands.

The preprocessor appended a FROZEN_VIEWS record each time a view over a
semantic object was compiled, and CHECK_FROZEN_VIEWS reported every record. So
creating a view three times reported it three times, and re-creating a STALE
view -- the documented remedy -- added a CURRENT row beside the STALE one: a
fixed view reported STALE for good, and the report could never be driven clean.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "frozen_registry"
SRC = "FROZREG_SRC"
VIEWS = "FROZREG_VIEWS"
VIEW = (f"CREATE OR REPLACE VIEW {VIEWS}.V_TOTALS AS"
        f" SELECT status, total_amount FROM SEMANTIC_{MODEL.upper()}.SALES")


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {VIEWS} CASCADE",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE",
                      f"DELETE FROM SYS_SEMANTIC.FROZEN_VIEWS WHERE VIEW_SCHEMA = '{VIEWS}'"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def report(con: Any) -> Counter[str]:
    return Counter(row["status"] for row in support.named_rows(con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS('{MODEL}')"))
        if row["view_name"] == "V_TOTALS")


def redefine(con: Any, expression: str) -> None:
    applied = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"'ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE METRIC total_amount AS"
        f" {expression} ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE', FALSE)"))
    assert applied is not None and applied["status"] == "OK", applied


@pytest.fixture
def model(semantic_con: Any) -> Iterator[Any]:
    con = semantic_con
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), STATUS VARCHAR(20),"
                " AMOUNT DECIMAL(18,2), DISCOUNT DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1, 'OPEN', 10, 1), (2, 'SHIPPED', 20, 2)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Frozen view registry', NULL)",
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
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    con.execute(f"CREATE SCHEMA {VIEWS}")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_recreating_a_view_keeps_one_record(model: Any) -> None:
    for _ in range(3):
        model.execute(VIEW)
    assert report(model) == Counter({"CURRENT": 1})


def test_the_remedy_for_a_stale_view_drives_the_report_clean(model: Any) -> None:
    model.execute(VIEW)
    redefine(model, "SUM(amount) - SUM(discount)")
    assert report(model) == Counter({"STALE": 1})
    model.execute(VIEW)
    assert report(model) == Counter({"CURRENT": 1})


def test_a_dropped_view_still_reads_dropped(model: Any) -> None:
    model.execute(VIEW)
    model.execute(VIEW)
    model.execute(f"DROP VIEW {VIEWS}.V_TOTALS")
    assert report(model) == Counter({"DROPPED": 1})


def test_a_create_that_fails_leaves_the_record_of_the_view_that_stays(model: Any) -> None:
    # The record is written before Exasol runs the statement. A plain CREATE
    # VIEW over an existing view fails, and recording it described SQL the view
    # never held.
    model.execute(VIEW)
    with pytest.raises(Exception, match="already exists"):
        model.execute(f"CREATE VIEW {VIEWS}.V_TOTALS AS"
                      f" SELECT total_amount FROM SEMANTIC_{MODEL.upper()}.SALES")
    assert report(model) == Counter({"CURRENT": 1})


def test_a_view_recreated_without_the_object_is_not_judged_by_its_old_record(
        model: Any) -> None:
    # The preprocessor never sees this statement, so the old record stays. The
    # check compares it with the SQL the view holds before judging it.
    model.execute(VIEW)
    model.execute(f"CREATE OR REPLACE VIEW {VIEWS}.V_TOTALS AS SELECT 1 AS X FROM DUAL")
    assert report(model) == Counter({"UNKNOWN": 1})


def test_an_unqualified_view_is_recorded_in_the_open_schema(model: Any) -> None:
    # It was recorded with an empty schema, which no view matches, so every
    # unqualified view -- ibis's schema probe among them -- read DROPPED.
    model.execute(f"OPEN SCHEMA {VIEWS}")
    model.execute(f"CREATE VIEW V_TOTALS AS SELECT status, total_amount"
                  f" FROM SEMANTIC_{MODEL.upper()}.SALES")
    assert report(model) == Counter({"CURRENT": 1})
