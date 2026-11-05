"""A coverage window does not depend on the session's NLS_TIMESTAMP_FORMAT.

dbt-exasol sets NLS_TIMESTAMP_FORMAT = 'YYYY-MM-DDTHH:MI:SS.FF6' on every session.
The coverage writers bound VALID_FROM / VALID_TO as text into TIMESTAMP columns,
so the session's format parsed them, and an ordinary '2026-01-01 00:00:00' was
refused inside a dbt build: "invalid character value for cast ... in write of
column ENTITY_REPRESENTATIONS.VALID_TO". A model definition must not depend on a
client's display settings. The bounds are now written and read in one fixed
format, and the same model answers the same under either session.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "coverage_format"
SRC = "COVFMT_SRC"
BOUNDARY = "2026-01-01 00:00:00"
DBT_FORMAT = "YYYY-MM-DDTHH:MI:SS.FF6"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def coverage(boundary: str) -> str:
    return json.dumps([
        {"representation_name": "archive",
         "coverage_predicate": f"o.order_ts < TIMESTAMP '{BOUNDARY}'",
         "valid_from": None, "valid_to": boundary},
        {"representation_name": "primary",
         "coverage_predicate": f"o.order_ts >= TIMESTAMP '{BOUNDARY}'",
         "valid_from": boundary, "valid_to": None},
    ])


def total(con: Any) -> float:
    compiled = support.compile_request(con, {"model": MODEL, "object": "SALES",
                                             "metrics": ["total_amount"]})
    assert compiled["status"] == "OK", compiled["error_message"]
    return float(con.execute(compiled["generated_sql"]).fetchone()[0])


def stored(con: Any) -> list[tuple[str, str | None, str | None]]:
    return [tuple(row) for row in con.execute(
        "SELECT r.REPRESENTATION_NAME,"
        " TO_CHAR(r.VALID_FROM, 'YYYY-MM-DD HH24:MI:SS'), TO_CHAR(r.VALID_TO, 'YYYY-MM-DD HH24:MI:SS')"
        " FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r JOIN SYS_SEMANTIC.MODELS m"
        f" ON m.MODEL_ID = r.MODEL_ID WHERE m.MODEL_NAME = '{MODEL}' ORDER BY 1").fetchall()]


def complete(con: Any) -> None:
    """The rest of the model, once the coverage windows are declared."""
    m = f"'{MODEL}'"
    for statement in (
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_FACT({m}, 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Amount', 'Order amount', FALSE, TRUE)",
        f"REPLACE_ATTRIBUTE_BINDING({m}, 'FACT', 'amount', 'archive', 'o.amount', 'PREFER', 1)",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION_OR_FAIL("
                f"'ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE METRICS (METRIC total_amount AS"
                " SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)',"
                " FALSE)")


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS_HOT (ORDER_ID DECIMAL(18,0), ORDER_TS TIMESTAMP,"
                " AMOUNT DECIMAL(18,2))")
    con.execute(f"CREATE TABLE {SRC}.ORDERS_ARCHIVE LIKE {SRC}.ORDERS_HOT")
    con.execute(f"INSERT INTO {SRC}.ORDERS_ARCHIVE VALUES (1, TIMESTAMP '2025-11-01 00:00:00', 10)")
    con.execute(f"INSERT INTO {SRC}.ORDERS_HOT VALUES (2, TIMESTAMP '2026-02-01 00:00:00', 20)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Coverage format', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS_HOT', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_UNIQUE_KEY({m}, 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
        f"ADD_ENTITY_REPRESENTATION({m}, 'orders', 'archive', 'RELATION', '{SRC}',"
        " 'ORDERS_ARCHIVE', 20, 'MANUAL')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    try:
        yield con
    finally:
        con.execute("ALTER SESSION SET NLS_TIMESTAMP_FORMAT='YYYY-MM-DD HH24:MI:SS.FF6'")
        teardown(con)


@pytest.mark.parametrize("boundary", [BOUNDARY, "2026-01-01T00:00:00.000000", "2026-01-01"])
def test_a_dbt_session_writes_the_window_it_was_given(model: Any, boundary: str) -> None:
    model.execute(f"ALTER SESSION SET NLS_TIMESTAMP_FORMAT='{DBT_FORMAT}'")
    model.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH("
                  f"'{MODEL}', 'orders', {support.sql_string(coverage(boundary))})")
    complete(model)
    assert stored(model) == [("archive", None, BOUNDARY), ("primary", BOUNDARY, None)]
    assert not support.blocking_issues(support.validate_model(model, MODEL))
    assert total(model) == 30


def test_the_single_call_and_a_restore_hold_under_a_dbt_session(model: Any) -> None:
    model.execute(f"ALTER SESSION SET NLS_TIMESTAMP_FORMAT='{DBT_FORMAT}'")
    model.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH("
                  f"'{MODEL}', 'orders', {support.sql_string(coverage(BOUNDARY))})")
    complete(model)
    model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    # A published change that would leave a gap is refused and the previous
    # window restored -- written back through the same fixed format.
    with pytest.raises(Exception, match="SEMANTIC_ADMIN_059"):
        model.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE("
                      f"'{MODEL}', 'orders', 'archive', 'o.order_ts < TIMESTAMP"
                      " ''2025-12-01 00:00:00''', NULL, '2025-12-01 00:00:00')")
    assert stored(model) == [("archive", None, BOUNDARY), ("primary", BOUNDARY, None)]
    assert total(model) == 30


def test_the_exported_window_is_the_same_under_either_session(model: Any) -> None:
    model.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH("
                  f"'{MODEL}', 'orders', {support.sql_string(coverage(BOUNDARY))})")
    complete(model)

    def exported() -> str:
        row = support.named_row(model.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_FUSION_DECLARATION('{MODEL}', NULL)"))
        assert row is not None
        return next(v for v in row.values() if isinstance(v, str) and v.startswith("{"))

    plain = exported()
    model.execute(f"ALTER SESSION SET NLS_TIMESTAMP_FORMAT='{DBT_FORMAT}'")
    assert exported() == plain
    # And it re-applies under the dbt session as a no-op.
    row = support.named_row(model.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION_OR_FAIL("
        f"'{MODEL}', {support.sql_string(plain)}, TRUE)"))
    assert row is not None and row["applied_count"] == 0, row
