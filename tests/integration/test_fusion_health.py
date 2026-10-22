"""CHECK_FUSION_HEALTH counts how a fused attribute is actually answered.

Validation reports conflicting values (SEMANTIC_MODEL_046) and nothing else. A
key the first-ranked source left NULL was silently filled from a supplemental
source, and a key no source covered answered NULL -- 2,300 of revenue moved into
a NULL segment -- with no count anywhere. The script counts both, over the
primary representation's keys, with the compiler's own fused expression.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "fusion_health"
SRC = "FUSIONHEALTH_SRC"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


@pytest.fixture
def model(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.CUSTOMERS_MDM (CUSTOMER_ID DECIMAL(18,0),"
                " CUSTOMER_NAME VARCHAR(100))")
    con.execute(f"CREATE TABLE {SRC}.CUSTOMERS_CRM (CUSTOMER_ID DECIMAL(18,0),"
                " DISPLAY_NAME VARCHAR(100))")
    # 1 and 4 answered by MDM; 2 filled from the CRM; 3 answered by nobody.
    con.execute(f"INSERT INTO {SRC}.CUSTOMERS_MDM VALUES (1, 'Alice'), (2, NULL), (3, NULL),"
                " (4, 'Dan')")
    con.execute(f"INSERT INTO {SRC}.CUSTOMERS_CRM VALUES (1, 'Alice'), (2, 'Bob'), (3, NULL),"
                " (4, NULL)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Fusion health', NULL)",
        f"ADD_ENTITY({m}, 'customer', '{SRC}', 'CUSTOMERS_MDM', 'c', 'c.customer_id',"
        " 'One customer', 'Customers')",
        f"ADD_UNIQUE_KEY({m}, 'customer', 'customer_pk', 'PRIMARY', 'Customer identity',"
        " 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
        f"ADD_SEMANTIC_OBJECT({m}, 'CUSTOMERS', 'customer', 'Customers')",
        f"ADD_DIMENSION({m}, 'CUSTOMERS', 'customer', 'customer_name', 'c.customer_name',"
        " 'VARCHAR(100)', 'Customer Name', 'Resolved name', NULL, TRUE)",
        f"ADD_ENTITY_REPRESENTATION({m}, 'customer', 'crm', 'RELATION', '{SRC}',"
        " 'CUSTOMERS_CRM', 20, 'MANUAL')",
        f"ADD_ATTRIBUTE_BINDING({m}, 'DIMENSION', 'customer_name', 'crm', 'c.display_name',"
        " 'PREFER', 1)",
        f"SET_REPRESENTATION_AUTHORITY({m}, 'customer', 'primary', 'PREFER')",
        f"SET_REPRESENTATION_AUTHORITY({m}, 'customer', 'crm', 'SUPPLEMENTAL')",
        f"SET_ATTRIBUTE_FUSION_POLICY({m}, 'DIMENSION', 'customer_name', 'COALESCE')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    assert not support.blocking_issues(support.validate_model(con, MODEL))
    try:
        yield con
    finally:
        teardown(con)


def test_fills_and_unresolved_keys_are_counted(model: Any) -> None:
    rows = support.named_rows(model.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FUSION_HEALTH('{MODEL}')"))
    assert [(row["attribute_name"], row["fusion_strategy"], row["first_source"],
             row["total_keys"], row["from_first_source"], row["filled"], row["unresolved"],
             row["probe_error"]) for row in rows] == [
        ("customer_name", "COALESCE", "primary", 4, 2, 1, 1, None)]


def test_the_counts_match_what_a_query_returns(model: Any) -> None:
    compiled = support.compile_request(model, {"model": MODEL, "object": "CUSTOMERS",
                                               "dimensions": ["customer_name"]})
    assert compiled["status"] == "OK", compiled["error_message"]
    names = sorted(str(row[0]) for row in model.execute(compiled["generated_sql"]))
    # Alice and Dan from MDM, Bob filled from the CRM, and one NULL group.
    assert names == ["Alice", "Bob", "Dan", "None"]
