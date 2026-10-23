"""A definition hash moves exactly when a definition does.

A model has one version that authoring mutates in place, so nothing a
consumer could read told it that a metric had been redefined: VERSION_ID never
moved, and LATEST_VALIDATION_RUN_ID moved on a no-op validation too. Rolling a
dashboard back restored a pre-fix number with every check green.
SEMANTIC_AGENT.DEFINITION_HASHES_FOR_AGENT and PLAN_JSON.definition_hashes are
the record a consumer stores and compares.

Each property below is one way the hash could be wrong: moving when nothing
was redefined (validation, publishing, a label), or not moving when something
was (an expression, a fact under a metric, a coverage boundary).
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "definition_hash"
SRC = "DEFHASH_SRC"
PUBLISHED = f"SEMANTIC_{MODEL.upper()}"
USER = "DEFHASH_ANALYST"
ROLE = "DEFHASH_OTHER_ROLE"


def ddl(con: Any, statement: str) -> None:
    rows = support.named_rows(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{support.sql_string(statement)}, FALSE)"))
    assert rows and rows[0]["status"] == "OK", rows
    con.commit()


def hashes(con: Any) -> dict[str, str]:
    """{'MODEL': hash, 'METRIC:total_amount': hash, ...}"""
    rows = con.execute(
        "SELECT FIELD_KIND, FIELD_NAME, DEFINITION_HASH"
        " FROM SEMANTIC_AGENT.DEFINITION_HASHES_FOR_AGENT"
        f" WHERE MODEL_NAME = '{MODEL}'").fetchall()
    return {kind if name is None else f"{kind}:{name}": value for kind, name, value in rows}


def changed(before: dict[str, str], after: dict[str, str]) -> set[str]:
    return {name for name in before.keys() | after.keys() if before.get(name) != after.get(name)}


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {PUBLISHED} CASCADE",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE",
                      f"DROP USER IF EXISTS {USER} CASCADE",
                      f"DROP ROLE IF EXISTS {ROLE} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    # Validation probes keys across representations, and refuses to without one.
    con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS_HOT (ORDER_ID DECIMAL(18,0), ORDER_TS TIMESTAMP,"
                " ORDER_STATUS VARCHAR(20), AMOUNT DECIMAL(18,2), FREIGHT DECIMAL(18,2))")
    con.execute(f"CREATE TABLE {SRC}.ORDERS_COLD LIKE {SRC}.ORDERS_HOT")
    con.execute(f"INSERT INTO {SRC}.ORDERS_COLD VALUES"
                " (1, TIMESTAMP '2025-11-01 00:00:00', 'CLOSED', 10, 1),"
                " (2, TIMESTAMP '2025-12-01 00:00:00', 'OPEN', 20, 2)")
    con.execute(f"INSERT INTO {SRC}.ORDERS_HOT VALUES"
                " (3, TIMESTAMP '2026-01-01 00:00:00', 'CLOSED', 30, 3),"
                " (4, TIMESTAMP '2026-02-01 00:00:00', 'OPEN', 40, 4)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, '{PUBLISHED}', 'Definition hashes', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS_HOT', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_UNIQUE_KEY({m}, 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
        f"ADD_ENTITY_REPRESENTATION({m}, 'orders', 'cold', 'RELATION', '{SRC}',"
        " 'ORDERS_COLD', 20, 'MANUAL')",
        f"SET_REPRESENTATION_COVERAGE({m}, 'orders', 'cold', 'o.order_ts < TIMESTAMP"
        " ''2026-01-01 00:00:00''', NULL, TIMESTAMP '2026-01-01 00:00:00')",
        f"SET_REPRESENTATION_COVERAGE({m}, 'orders', 'primary', 'o.order_ts >= TIMESTAMP"
        " ''2026-01-01 00:00:00''', TIMESTAMP '2026-01-01 00:00:00', NULL)",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    ddl(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE DIMENSIONS (DIMENSION order_status ON ENTITY orders AS o.order_status
  RETURNS VARCHAR(20) DISPLAY 'Order Status' PUBLIC CERTIFIED)""")
    ddl(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE FACTS (
  FACT amount ON ENTITY orders AS o.amount RETURNS DECIMAL(18,2) ADDITIVE PUBLIC,
  FACT freight ON ENTITY orders AS o.freight RETURNS DECIMAL(18,2) ADDITIVE PUBLIC)""")
    ddl(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE METRICS (
  METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2)
    DISPLAY 'Total' ADDITIVE PUBLIC CERTIFIED,
  METRIC total_freight AS SUM(freight) ON ENTITY orders RETURNS DECIMAL(18,2)
    DISPLAY 'Freight' ADDITIVE PUBLIC CERTIFIED,
  METRIC freight_share AS total_freight / NULLIF(total_amount, 0) ON ENTITY orders
    RETURNS DOUBLE DISPLAY 'Freight share' RATIO PUBLIC CERTIFIED)""")
    assert not support.blocking_issues(support.validate_model(con, MODEL))
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_every_field_and_the_model_have_a_hash(model: Any) -> None:
    current = hashes(model)
    assert set(current) == {"MODEL", "DIMENSION:order_status", "FACT:amount", "FACT:freight",
                            "METRIC:total_amount", "METRIC:total_freight",
                            "METRIC:freight_share"}
    assert all(len(value) == 64 for value in current.values())


def test_validating_and_publishing_change_nothing(model: Any) -> None:
    before = hashes(model)
    support.validate_model(model, MODEL)
    model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    model.commit()
    assert changed(before, hashes(model)) == set()


def test_a_label_changes_nothing(model: Any) -> None:
    before = hashes(model)
    ddl(model, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
ADD OR REPLACE METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2)
  DISPLAY 'Total amount, relabelled' COMMENT 'now described' ADDITIVE PUBLIC""")
    assert changed(before, hashes(model)) == set()


def test_redefining_a_metric_moves_it_and_what_is_built_on_it(model: Any) -> None:
    before = hashes(model)
    ddl(model, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
ADD OR REPLACE METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2)
  FILTER order_status <> 'OPEN' DISPLAY 'Total' ADDITIVE PUBLIC CERTIFIED""")
    assert changed(before, hashes(model)) == {
        "MODEL", "METRIC:total_amount", "METRIC:freight_share"}


def test_redefining_a_fact_moves_the_metrics_over_it(model: Any) -> None:
    before = hashes(model)
    ddl(model, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
ADD OR REPLACE FACT amount ON ENTITY orders AS o.amount * 2 RETURNS DECIMAL(18,2)
  ADDITIVE PUBLIC""")
    support.validate_model(model, MODEL)
    assert changed(before, hashes(model)) == {
        "MODEL", "FACT:amount", "METRIC:total_amount", "METRIC:freight_share"}


def test_moving_a_coverage_boundary_moves_every_field_of_the_entity(model: Any) -> None:
    before = hashes(model)
    declarations = [
        {"representation_name": "cold",
         "coverage_predicate": "o.order_ts < TIMESTAMP '2026-02-01 00:00:00'",
         "valid_from": None, "valid_to": "2026-02-01 00:00:00"},
        {"representation_name": "primary",
         "coverage_predicate": "o.order_ts >= TIMESTAMP '2026-02-01 00:00:00'",
         "valid_from": "2026-02-01 00:00:00", "valid_to": None},
    ]
    model.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH("
                  f"'{MODEL}', 'orders', {support.sql_string(json.dumps(declarations))})")
    model.commit()
    assert changed(before, hashes(model)) == set(before)


def test_a_rename_keeps_the_field_hash_and_moves_the_model(model: Any) -> None:
    before = hashes(model)
    ddl(model, f"ALTER SEMANTIC VIEW {MODEL}.SALES RENAME METRIC total_freight TO freight_total")
    after = hashes(model)
    assert after["METRIC:freight_total"] == before["METRIC:total_freight"]
    assert after["MODEL"] != before["MODEL"]


def test_the_plan_carries_the_same_hashes(model: Any) -> None:
    model.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    model.commit()
    compiled = support.compile_request(model, {
        "model": MODEL, "object": "SALES", "dimensions": ["order_status"],
        "metrics": ["freight_share"]})
    assert compiled["status"] == "OK", compiled["error_message"]
    plan = json.loads(compiled["plan_json"])
    current = hashes(model)
    assert plan["definition_hashes"] == {
        "dimensions": {"order_status": current["DIMENSION:order_status"]},
        "metrics": {"freight_share": current["METRIC:freight_share"]}}


def test_a_model_the_caller_may_not_see_has_no_hashes(model: Any) -> None:
    model.execute(f'CREATE USER {USER} IDENTIFIED BY "Defhash1"')
    model.execute(f"GRANT CREATE SESSION TO {USER}")
    model.execute(f"GRANT SEMANTIC_USER TO {USER}")
    model.execute(f"CREATE ROLE {ROLE}")
    model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('{MODEL}', '{ROLE}')")
    model.commit()
    model_id = model.execute(
        f"SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = '{MODEL}'").fetchone()[0]
    analyst = support.connect(user=USER, password="Defhash1")
    try:
        for view in ("SEMANTIC_AGENT.DEFINITION_HASHES_FOR_AGENT",
                     "SEMANTIC_CATALOG.FIELD_DEFINITION_HASHES",
                     "SEMANTIC_CATALOG.MODEL_DEFINITION_HASHES"):
            count = analyst.execute(
                f"SELECT COUNT(*) FROM {view} WHERE MODEL_ID = {model_id}").fetchone()[0]
            assert count == 0, view
    finally:
        analyst.close()
    # And granting it makes them readable, or the zero above proves nothing.
    model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('{MODEL}', '{USER}')")
    model.commit()
    granted = support.connect(user=USER, password="Defhash1")
    try:
        assert granted.execute(
            "SELECT COUNT(*) FROM SEMANTIC_AGENT.DEFINITION_HASHES_FOR_AGENT"
            f" WHERE MODEL_ID = {model_id}").fetchone()[0] == 7
    finally:
        granted.close()
