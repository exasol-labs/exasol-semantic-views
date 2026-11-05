"""A fact can be removed, through the surface that owns it.

No surface could remove a fact: the script API has adders for facts and
metrics only, Semantic DDL had DROP METRIC but no DROP FACT, and REPLACE FACTS
leaves an omitted fact active. DROP FACT retires a fact from the model -- a fact
belongs to its entity, not to the view the statement names -- and is refused
while any metric is built on it. The duplicate refusals of ADD_FACT and
ADD_METRIC name the DDL that redefines and removes what they cannot.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "fact_removal"
SRC = "FACTREM_SRC"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def apply(con: Any, statement: str, dry_run: bool = False) -> dict[str, Any]:
    row = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{support.sql_string(statement)}, {'TRUE' if dry_run else 'FALSE'})"))
    assert row is not None
    return row


def fact_status(con: Any, name: str) -> str | None:
    row = con.execute(
        "SELECT f.STATUS FROM SYS_SEMANTIC.FACTS f"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = f.MODEL_ID"
        f" WHERE m.MODEL_NAME = '{MODEL}' AND f.FACT_NAME = '{name}'").fetchone()
    return None if row is None else str(row[0])


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0),"
                " AMOUNT DECIMAL(18,2), DISCOUNT DECIMAL(18,2))")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Fact removal', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
        f"ADD_FACT({m}, 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Amount', 'Order amount', FALSE, TRUE)",
        f"ADD_FACT({m}, 'orders', 'discount', 'o.discount', 'DECIMAL(18,2)', 'ADDITIVE',"
        " 'Discount', 'Order discount', FALSE, TRUE)",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    applied = apply(con, f"ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE METRICS (METRIC"
                         " total_amount AS SUM(amount) ON ENTITY orders RETURNS"
                         " DECIMAL(18,2) ADDITIVE)")
    assert applied["status"] == "OK", applied
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_an_unused_fact_is_dropped(model: Any) -> None:
    dry = apply(model, f"ALTER SEMANTIC VIEW {MODEL}.SALES DROP FACT discount", dry_run=True)
    assert dry["status"] == "DRY_RUN", dry
    assert fact_status(model, "discount") == "ACTIVE"
    dropped = apply(model, f"ALTER SEMANTIC VIEW {MODEL}.SALES DROP FACT discount")
    assert dropped["status"] == "OK", dropped
    assert fact_status(model, "discount") == "INACTIVE"
    assert not support.blocking_issues(support.validate_model(model, MODEL))


def test_a_fact_a_metric_is_built_on_is_refused(model: Any) -> None:
    refused = apply(model, f"ALTER SEMANTIC VIEW {MODEL}.SALES DROP FACT amount")
    assert refused["status"] == "ERROR"
    assert "SEMANTIC_DDL_094" in refused["message"]
    assert "total_amount" in refused["message"]
    assert fact_status(model, "amount") == "ACTIVE"


def test_the_preprocessor_takes_drop_fact_directly(model: Any) -> None:
    model.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    model.execute(f"ALTER SEMANTIC VIEW {MODEL}.SALES DROP FACT discount")
    assert fact_status(model, "discount") == "INACTIVE"


def test_a_dropped_fact_comes_back_with_add_or_replace(model: Any) -> None:
    apply(model, f"ALTER SEMANTIC VIEW {MODEL}.SALES DROP FACT discount")
    restored = apply(model, f"ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE FACT discount"
                            " ON ENTITY orders AS o.discount RETURNS DECIMAL(18,2) ADDITIVE")
    assert restored["status"] == "OK", restored
    assert fact_status(model, "discount") == "ACTIVE"


@pytest.mark.parametrize("statement, code, remedy", [
    (f"ADD_FACT('{MODEL}', 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE',"
     " 'x', 'x', FALSE, FALSE)", "SEMANTIC_ADMIN_020", "ADD OR REPLACE FACT amount"),
    (f"ADD_METRIC('{MODEL}', 'SALES', 'total_amount', 'SUM(amount)', NULL, 'ADDITIVE',"
     " 'orders', 'DECIMAL(18,2)', 'x', 'x', NULL, FALSE, FALSE)",
     "SEMANTIC_ADMIN_226", "ADD OR REPLACE METRIC total_amount"),
])
def test_a_duplicate_names_the_ddl_that_edits_it(model: Any, statement: str, code: str,
                                                 remedy: str) -> None:
    with pytest.raises(Exception, match=code) as refused:
        model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    assert remedy in str(refused.value)
    assert "APPLY_SEMANTIC_DEFINITION" in str(refused.value)
