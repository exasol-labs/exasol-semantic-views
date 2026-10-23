"""Rows a temporal partition holds outside its coverage window are reported.

Coverage was trusted as declared. An archive job moved July-September from the
hot table to the archive before the coverage boundary moved, and the governed
answer fell from 28,000 to 9,250 -- the rows sat in the archive outside its
window, so every query filtered them out -- while VALIDATE_MODEL reported the
same warnings as before. SEMANTIC_MODEL_074 and CHECK_PARTITION_COVERAGE now
say how many rows sit outside their partition's window, and how many of them no
other partition covers.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "partition_coverage"
SRC = "PARTCOV_SRC"
BOUNDARY = "2026-01-01 00:00:00"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def check(con: Any) -> dict[str, dict[str, Any]]:
    rows = support.named_rows(con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_PARTITION_COVERAGE('{MODEL}')"))
    return {row["representation_name"]: row for row in rows}


def coverage_warnings(con: Any) -> list[dict[str, Any]]:
    return [issue for issue in support.validate_model(con, MODEL)
            if issue["rule_code"] == "SEMANTIC_MODEL_074"]


def total(con: Any) -> float:
    compiled = support.compile_request(con, {"model": MODEL, "object": "SALES",
                                             "metrics": ["total_amount"]})
    assert compiled["status"] == "OK", compiled["error_message"]
    return float(con.execute(compiled["generated_sql"]).fetchone()[0])


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS_HOT (ORDER_ID DECIMAL(18,0), ORDER_TS TIMESTAMP,"
                " AMOUNT DECIMAL(18,2))")
    con.execute(f"CREATE TABLE {SRC}.ORDERS_ARCHIVE LIKE {SRC}.ORDERS_HOT")
    con.execute(f"INSERT INTO {SRC}.ORDERS_ARCHIVE VALUES"
                " (1, TIMESTAMP '2025-11-01 00:00:00', 10),"
                " (2, TIMESTAMP '2025-12-01 00:00:00', 20)")
    con.execute(f"INSERT INTO {SRC}.ORDERS_HOT VALUES"
                " (3, TIMESTAMP '2026-01-15 00:00:00', 30),"
                " (4, TIMESTAMP '2026-02-01 00:00:00', 40)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Partition coverage', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS_HOT', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_UNIQUE_KEY({m}, 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
        f"ADD_ENTITY_REPRESENTATION({m}, 'orders', 'archive', 'RELATION', '{SRC}',"
        " 'ORDERS_ARCHIVE', 20, 'MANUAL')",
        f"SET_REPRESENTATION_COVERAGE({m}, 'orders', 'archive', 'o.order_ts < TIMESTAMP"
        f" ''{BOUNDARY}''', NULL, TIMESTAMP '{BOUNDARY}')",
        f"SET_REPRESENTATION_COVERAGE({m}, 'orders', 'primary', 'o.order_ts >= TIMESTAMP"
        f" ''{BOUNDARY}''', TIMESTAMP '{BOUNDARY}', NULL)",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_FACT({m}, 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Amount', 'Order amount', FALSE, TRUE)",
        f"REPLACE_ATTRIBUTE_BINDING({m}, 'FACT', 'amount', 'archive', 'o.amount', 'PREFER', 1)",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
                f"'ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE METRICS (METRIC total_amount AS"
                " SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)',"
                " FALSE)")
    con.commit()
    assert not support.blocking_issues(support.validate_model(con, MODEL))
    try:
        yield con
    finally:
        teardown(con)


def test_a_consistent_model_reports_nothing(model: Any) -> None:
    assert check(model) == {}
    assert coverage_warnings(model) == []
    assert total(model) == 100


def test_rows_moved_before_the_boundary_are_reported_as_stranded(model: Any) -> None:
    # The archive job copies January to the archive and deletes it from hot,
    # but the boundary has not moved: the archive's window ends at January.
    model.execute(f"INSERT INTO {SRC}.ORDERS_ARCHIVE SELECT * FROM {SRC}.ORDERS_HOT"
                  " WHERE ORDER_TS < TIMESTAMP '2026-02-01 00:00:00'")
    model.execute(f"DELETE FROM {SRC}.ORDERS_HOT WHERE ORDER_TS < TIMESTAMP '2026-02-01 00:00:00'")
    model.commit()
    assert total(model) == 70  # order 3 is gone from the answer
    findings = check(model)
    assert (findings["archive"]["outside_rows"], findings["archive"]["stranded_keys"]) == (1, 1)
    warnings = coverage_warnings(model)
    assert len(warnings) == 1 and "1 of their keys" in warnings[0]["message"]


def test_a_copy_still_inside_the_covering_window_is_not_a_warning(model: Any) -> None:
    # Between the archive job's copy and its delete: duplicated, nothing lost.
    model.execute(f"INSERT INTO {SRC}.ORDERS_ARCHIVE SELECT * FROM {SRC}.ORDERS_HOT"
                  " WHERE ORDER_TS < TIMESTAMP '2026-02-01 00:00:00'")
    model.commit()
    findings = check(model)
    assert (findings["archive"]["outside_rows"], findings["archive"]["stranded_keys"]) == (1, 0)
    assert coverage_warnings(model) == []


def test_a_row_with_no_partition_key_is_stranded(model: Any) -> None:
    model.execute(f"INSERT INTO {SRC}.ORDERS_HOT VALUES (5, NULL, 50)")
    model.commit()
    findings = check(model)
    assert (findings["primary"]["outside_rows"], findings["primary"]["stranded_keys"]) == (1, 1)
