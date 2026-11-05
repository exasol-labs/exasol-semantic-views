"""An entity's source is checked, and stored as the database spells it, when declared.

dbt's ref() renders `slv_customer` for a table Exasol created as SLV_CUSTOMER,
and the compiler quotes a stored source exactly. ADD_ENTITY accepted the
lower-case name; the mistake surfaced five steps later, as SEMANTIC_MODEL_072
on every dimension of a different object. A source that does not exist at all
was accepted the same way.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "source_resolution"
SRC = "SRCRES_SILVER"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def stored(con: Any, table: str) -> list[tuple[str, str]]:
    return [tuple(row) for row in con.execute(
        f"SELECT t.SOURCE_SCHEMA, t.SOURCE_OBJECT FROM SYS_SEMANTIC.{table} t"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = t.MODEL_ID"
        f" WHERE m.MODEL_NAME = '{MODEL}' ORDER BY 1, 2").fetchall()]


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.SLV_CUSTOMER (CUSTOMER_KEY DECIMAL(18,0), REGION VARCHAR(20))")
    con.execute(f"CREATE TABLE {SRC}.SLV_CUSTOMER_CRM (CUSTOMER_KEY DECIMAL(18,0), REGION VARCHAR(20))")
    con.execute(f"INSERT INTO {SRC}.SLV_CUSTOMER VALUES (1, 'North'), (2, 'South')")
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('{MODEL}',"
                f" 'SEMANTIC_{MODEL.upper()}', 'Source resolution', NULL)")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_a_ref_rendered_name_is_stored_as_the_database_spells_it(model: Any) -> None:
    model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('{MODEL}', 'customer',"
                  " 'srcres_silver', 'slv_customer', 'c', 'c.customer_key', NULL, NULL)")
    assert stored(model, "ENTITIES") == [(SRC, "SLV_CUSTOMER")]
    assert stored(model, "ENTITY_REPRESENTATIONS") == [(SRC, "SLV_CUSTOMER")]
    model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('{MODEL}',"
                  " 'customer', 'crm', 'RELATION', 'srcres_silver', 'slv_customer_crm', 2, NULL)")
    assert (SRC, "SLV_CUSTOMER_CRM") in stored(model, "ENTITY_REPRESENTATIONS")


def test_a_source_that_does_not_exist_is_refused_where_it_is_named(model: Any) -> None:
    with pytest.raises(Exception, match="SEMANTIC_ADMIN_227: source relation"
                                        f" {SRC}.SLV_CUSTOMR does not exist"):
        model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('{MODEL}', 'customer',"
                      f" '{SRC}', 'SLV_CUSTOMR', 'c', 'c.customer_key', NULL, NULL)")
    assert stored(model, "ENTITIES") == []


def test_validation_names_the_spelling_of_a_source_stored_in_another_case(model: Any) -> None:
    # A catalog written before declaring resolved the name: the validator now
    # asks the exact question the compiler's quoting does.
    model.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('{MODEL}', 'customer',"
                  f" '{SRC}', 'SLV_CUSTOMER', 'c', 'c.customer_key', NULL, NULL)")
    model.execute("UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS SET SOURCE_OBJECT = 'slv_customer'"
                  f" WHERE SOURCE_SCHEMA = '{SRC}'")
    rows = support.named_rows(model.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')"))
    messages = [row["message"] for row in rows if row["rule_code"] == "SEMANTIC_MODEL_001"]
    assert any(f"The database spells it {SRC}.SLV_CUSTOMER" in m for m in messages), rows
