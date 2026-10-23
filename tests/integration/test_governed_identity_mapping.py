"""GOVERNED mode vouches for an F5 identity mapping relation.

The trust derivation classified the relations a representation or a
materialization reads, and nothing else. An F5 MAPPED binding puts a third kind
into rendered SQL -- the certified mapping relation the compiler joins through --
so its name was never in SOURCE_TRUST, the plan reported it NOT_CLASSIFIED, and a
GOVERNED model refused every request that used the mapping with _028. The mode
that promises to refuse what it cannot vouch for was refusing what it had
certified. The plan also listed the mapping twice, once per reference.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "governed_f5"
SRC = "GOVF5_SRC"
GOV = "GOVF5_GOVERNED"
PUBLISHED = f"SEMANTIC_{MODEL.upper()}"
REQUEST = {"model": MODEL, "object": "CUSTOMER_360", "dimensions": ["customer_name"]}
XREF = f"{SRC}.CUSTOMER_XREF"


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {PUBLISHED} CASCADE",
                      f"DROP SCHEMA IF EXISTS {GOV} CASCADE",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


def cold_compile(con: Any) -> dict[str, Any]:
    """From a cold cache: a cache hit returns the plan stored with it."""
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    con.commit()
    return support.compile_request(con, REQUEST)


@pytest.fixture
def governed_f5(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.CUSTOMERS_MDM (CUSTOMER_ID DECIMAL(18,0),"
                " CUSTOMER_NAME VARCHAR(100))")
    con.execute(f"CREATE TABLE {SRC}.ACCOUNTS_CRM (ACCOUNT_ID VARCHAR(20),"
                " DISPLAY_NAME VARCHAR(100))")
    con.execute(f"CREATE TABLE {XREF} (ACCOUNT_ID VARCHAR(20), CUSTOMER_ID DECIMAL(18,0))")
    con.execute(f"INSERT INTO {SRC}.CUSTOMERS_MDM VALUES (1, 'Alice'), (2, NULL), (3, 'Carol')")
    con.execute(f"INSERT INTO {SRC}.ACCOUNTS_CRM VALUES ('A-1', 'Alice'), ('A-2', 'Bob'),"
                " ('A-3', 'Carol')")
    con.execute(f"INSERT INTO {XREF} VALUES ('A-1', 1), ('A-2', 2), ('A-3', 3)")
    # Both representations read through views, so GOVERNED mode accepts them.
    # The mapping relation stays a base table: RAW, which the mode allows.
    con.execute(f"CREATE SCHEMA {GOV}")
    con.execute(f"CREATE VIEW {GOV}.CUSTOMERS_MDM AS SELECT * FROM {SRC}.CUSTOMERS_MDM")
    con.execute(f"CREATE VIEW {GOV}.ACCOUNTS_CRM AS SELECT * FROM {SRC}.ACCOUNTS_CRM")

    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, '{PUBLISHED}', 'Governed F5', NULL)",
        f"ADD_ENTITY({m}, 'customer', '{GOV}', 'CUSTOMERS_MDM', 'c', 'c.customer_id',"
        " 'One customer', 'Customer 360')",
        f"ADD_UNIQUE_KEY({m}, 'customer', 'customer_pk', 'PRIMARY', 'MDM key', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({m}, 'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
        f"ADD_SEMANTIC_OBJECT({m}, 'CUSTOMER_360', 'customer', 'Customer 360')",
        f"ADD_DIMENSION({m}, 'CUSTOMER_360', 'customer', 'customer_name', 'c.customer_name',"
        " 'VARCHAR(100)', 'Customer Name', 'Resolved customer name', NULL, TRUE)",
        f"ADD_ENTITY_REPRESENTATION({m}, 'customer', 'crm', 'RELATION', '{GOV}',"
        " 'ACCOUNTS_CRM', 20, 'MANUAL')",
        f"ADD_ATTRIBUTE_BINDING({m}, 'DIMENSION', 'customer_name', 'crm', 'c.display_name',"
        " 'PREFER', 1)",
        f"ADD_SEMANTIC_IDENTITY({m}, 'customer', 'customer_identity', 'GLOBAL',"
        " 'DECIMAL(18,0)', 'Certified customer identity')",
        f"ADD_IDENTITY_BINDING({m}, 'customer_identity', 'primary', 'c.customer_id', 'DIRECT')",
        f"ADD_IDENTITY_BINDING({m}, 'customer_identity', 'crm', 'c.account_id', 'MAPPED')",
        f"ADD_IDENTITY_MAPPING_RELATION({m}, 'customer_identity', 'crm', '{SRC}',"
        " 'CUSTOMER_XREF', 'ACCOUNT_ID', 'CUSTOMER_ID', 'CERTIFIED')",
        f"SET_REPRESENTATION_AUTHORITY({m}, 'customer', 'primary', 'PREFER')",
        f"SET_REPRESENTATION_AUTHORITY({m}, 'customer', 'crm', 'SUPPLEMENTAL')",
        f"SET_ATTRIBUTE_FUSION_POLICY({m}, 'DIMENSION', 'customer_name', 'COALESCE')",
        f"SET_MODEL_GOVERNANCE_MODE({m}, 'GOVERNED')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    issues = support.validate_model(con, MODEL)
    assert not support.blocking_issues(issues), issues
    try:
        yield con
    finally:
        teardown(con)


def test_mapping_relation_is_classified(governed_f5: Any) -> None:
    rows = governed_f5.execute(
        "SELECT RELATION_KIND, TRUST_CLASS FROM SEMANTIC_CATALOG.SOURCE_TRUST_FOR_MODEL"
        f" WHERE MODEL_NAME = '{MODEL}' AND PHYSICAL_OBJECT = 'CUSTOMER_XREF'").fetchall()
    assert [tuple(row) for row in rows] == [("IDENTITY_MAPPING", "RAW")]


def test_governed_model_serves_the_mapped_request(governed_f5: Any) -> None:
    compiled = cold_compile(governed_f5)
    assert compiled["status"] == "OK", compiled["error_message"]
    assert '"CUSTOMER_XREF"' in compiled["generated_sql"]
    names = sorted(str(row[0]) for row in governed_f5.execute(compiled["generated_sql"]))
    assert names == ["Alice", "Bob", "Carol"]


def test_plan_lists_each_source_once(governed_f5: Any) -> None:
    plan = json.loads(cold_compile(governed_f5)["plan_json"])
    relations = [source["relation"] for source in plan["governance"]["sources"]]
    assert len(relations) == len(set(relations)), relations
    assert plan["governance"]["unvouched_sources"] == []
