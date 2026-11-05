"""A frozen view that no longer matches its model stops answering.

`CREATE VIEW` over a semantic object stores compiled SQL, and the view went on
answering with the model as it was: after a definition change it returned the
old number with no warning and no error, and only a separate
CHECK_FROZEN_VIEWS call could tell. An agent handed the view by a BI tool or a
cached dashboard has no reason to make that call.

A clean VALIDATE_MODEL -- which every definition change runs -- now retires a
STALE view: the same name and columns, raising SEMANTIC_SURFACE_015. Reads pay
nothing; the check is paid once per change. The view's text and grants are
kept, and it is put back when the model compiles what it froze again, which is
also what undoes a dry run.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "frozen_retire"
SRC = "FROZRET_SRC"
VIEWS = "FROZRET_VIEWS"
ROLE = "FROZRET_READER"
VIEW = f"{VIEWS}.V_TOTALS"
CREATE = (f"CREATE OR REPLACE VIEW {VIEW} AS"
          f" SELECT status, total_amount FROM SEMANTIC_{MODEL.upper()}.SALES")
ORIGINAL = "SUM(amount)"
CHANGED = "SUM(amount) - SUM(discount)"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {VIEWS} CASCADE",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE",
                      f"DROP ROLE {ROLE}",
                      f"DELETE FROM SYS_SEMANTIC.FROZEN_VIEWS WHERE VIEW_SCHEMA = '{VIEWS}'"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def redefine(con: Any, expression: str, dry_run: bool = False) -> None:
    applied = support.named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"'ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE METRIC total_amount AS"
        f" {expression} ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE',"
        f" {'TRUE' if dry_run else 'FALSE'})"))
    assert applied is not None and applied["status"] in ("OK", "DRY_RUN"), applied


def answers(con: Any, view: str = VIEW) -> dict[str, float]:
    return {str(row[0]): float(row[1])
            for row in con.execute(f"SELECT * FROM {view}").fetchall()}


def presence(con: Any) -> str:
    return str(con.execute(
        "SELECT PRESENCE FROM SEMANTIC_CATALOG.FROZEN_VIEWS"
        f" WHERE VIEW_SCHEMA = '{VIEWS}' AND VIEW_NAME = 'V_TOTALS'").fetchval())


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
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Frozen view retirement', NULL)",
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
                f" {ORIGINAL} ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE)', FALSE)")
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    con.execute(f"CREATE SCHEMA {VIEWS}")
    con.execute(CREATE)
    con.execute(f"CREATE ROLE {ROLE}")
    con.execute(f"GRANT SELECT ON {VIEW} TO {ROLE}")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_a_current_view_answers_and_validation_leaves_it_alone(model: Any) -> None:
    model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")
    assert answers(model) == {"OPEN": 10.0, "SHIPPED": 20.0}
    assert presence(model) == "LIVE"


def test_a_changed_definition_retires_the_view(model: Any) -> None:
    redefine(model, CHANGED)
    for statement in (f"SELECT * FROM {VIEW}", f"SELECT COUNT(*) FROM {VIEW}"):
        with pytest.raises(Exception, match="SEMANTIC_SURFACE_015"):
            model.execute(statement).fetchall()
    assert presence(model) == "RETIRED"
    checked = support.named_row(model.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS('{MODEL}')"))
    assert checked is not None and checked["status"] == "STALE"
    assert "retired" in checked["detail"]


def test_validation_reports_the_retirement(model: Any) -> None:
    # Every authoring path validates, and the validation it runs retires the
    # view. Changing the catalog underneath leaves it to a direct VALIDATE_MODEL,
    # which says what it did.
    model.execute("UPDATE SYS_SEMANTIC.METRICS SET EXPRESSION = '(' || EXPRESSION || ') * 2'"
                  f" WHERE METRIC_NAME = 'total_amount' AND MODEL_ID = (SELECT MODEL_ID"
                  f" FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = '{MODEL}')")
    rows = support.named_rows(model.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')"))
    retired = [row for row in rows if row["rule_code"] == "SEMANTIC_MODEL_078"]
    assert [row["object_name"] for row in retired] == [VIEW], rows
    assert presence(model) == "RETIRED"


def test_grants_survive_retirement_and_restoration(model: Any) -> None:
    def granted() -> list[Any]:
        return model.execute(
            "SELECT PRIVILEGE FROM EXA_DBA_OBJ_PRIVS"
            f" WHERE OBJECT_SCHEMA = '{VIEWS}' AND OBJECT_NAME = 'V_TOTALS'"
            f" AND GRANTEE = '{ROLE}'").fetchall()

    redefine(model, CHANGED)
    assert presence(model) == "RETIRED"
    assert granted() == [("SELECT",)]
    redefine(model, ORIGINAL)
    assert presence(model) == "LIVE"
    assert granted() == [("SELECT",)]


def test_returning_to_the_frozen_definition_restores_the_view(model: Any) -> None:
    redefine(model, CHANGED)
    redefine(model, ORIGINAL)
    assert answers(model) == {"OPEN": 10.0, "SHIPPED": 20.0}
    assert presence(model) == "LIVE"


def test_a_dry_run_leaves_the_view_answering(model: Any) -> None:
    redefine(model, CHANGED, dry_run=True)
    assert answers(model) == {"OPEN": 10.0, "SHIPPED": 20.0}
    assert presence(model) == "LIVE"


def test_re_creating_a_retired_view_answers_the_current_definition(model: Any) -> None:
    redefine(model, CHANGED)
    model.execute(CREATE)
    assert answers(model) == {"OPEN": 9.0, "SHIPPED": 18.0}
    assert presence(model) == "LIVE"


def test_an_unqualified_view_is_restored_where_it_was_created(model: Any) -> None:
    # Its kept text names no schema, so it is replayed in the one it was
    # created in, and the caller's open schema is left as it was.
    model.execute(f"DROP VIEW {VIEW}")
    model.execute(f"OPEN SCHEMA {VIEWS}")
    model.execute(f"CREATE VIEW V_TOTALS AS SELECT status, total_amount"
                  f" FROM SEMANTIC_{MODEL.upper()}.SALES")
    redefine(model, CHANGED)
    assert presence(model) == "RETIRED"
    model.execute("UPDATE SYS_SEMANTIC.METRICS SET EXPRESSION = 'SUM(amount)'"
                  " WHERE METRIC_NAME = 'total_amount' AND MODEL_ID = (SELECT MODEL_ID"
                  f" FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = '{MODEL}')")
    model.execute(f"OPEN SCHEMA {SRC}")
    synced = support.named_rows(model.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.SYNC_FROZEN_VIEWS('{MODEL}')"))
    assert [row["outcome"] for row in synced] == ["RESTORED"], synced
    assert model.execute("SELECT CURRENT_SCHEMA").fetchval() == SRC
    assert answers(model) == {"OPEN": 10.0, "SHIPPED": 20.0}
