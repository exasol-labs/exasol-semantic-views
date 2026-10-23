"""Redefining a dimension carries the metric filters that name it along.

A metric filter is stored as written (`order_status = 'COMPLETE'`) and resolved
to the dimension's physical expression at the time (`o.order_status = ...`).
After `ALTER TABLE ... RENAME COLUMN ORDER_STATUS TO STATUS_CODE`, every lane
failed with `object O.ORDER_STATUS not found`, and the repair -- redefining the
dimension over the new column -- was refused with SEMANTIC_MODEL_017, because
the filter still read the old one. Both ways of redefining a dimension now
re-resolve the filters that name it.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "dimension_repair"
SRC = "DIMREPAIR_SRC"


def ddl(con: Any, statement: str) -> dict[str, Any]:
    rows = support.named_rows(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{support.sql_string(statement)}, FALSE)"))
    con.commit()
    return rows[0]


def completed_total(con: Any) -> float:
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    con.commit()
    compiled = support.compile_request(con, {"model": MODEL, "object": "SALES",
                                             "metrics": ["completed_revenue"]})
    assert compiled["status"] == "OK", compiled["error_message"]
    return float(con.execute(compiled["generated_sql"]).fetchone()[0])


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


@pytest.fixture
def renamed_column(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), ORDER_STATUS VARCHAR(20),"
                " REVENUE DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1, 'COMPLETE', 100), (2, 'CANCELLED', 50),"
                " (3, 'COMPLETE', 25)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, 'SEMANTIC_{MODEL.upper()}', 'Dimension repair', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    for statement in (
        f"""ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE DIMENSIONS (DIMENSION order_status
  ON ENTITY orders AS o.order_status RETURNS VARCHAR(20) PUBLIC)""",
        f"""ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE FACTS (FACT revenue ON ENTITY orders
  AS o.revenue RETURNS DECIMAL(18,2) ADDITIVE PUBLIC)""",
        f"""ALTER SEMANTIC VIEW {MODEL}.SALES REPLACE METRICS (METRIC completed_revenue
  AS SUM(revenue) ON ENTITY orders RETURNS DECIMAL(18,2) FILTER order_status = 'COMPLETE'
  FORMAT 'currency' UNIT 'EUR' ADDITIVE PUBLIC)""",
    ):
        assert ddl(con, statement)["status"] == "OK"
    assert completed_total(con) == 125
    con.execute(f"ALTER TABLE {SRC}.ORDERS RENAME COLUMN ORDER_STATUS TO STATUS_CODE")
    con.commit()
    try:
        yield con
    finally:
        teardown(con)


def test_semantic_ddl_repair_moves_the_filter(renamed_column: Any) -> None:
    row = ddl(renamed_column, f"""ALTER SEMANTIC VIEW {MODEL}.SALES ADD OR REPLACE DIMENSION
  order_status ON ENTITY orders AS o.status_code RETURNS VARCHAR(20) PUBLIC""")
    assert row["status"] == "OK", row["message"]
    assert completed_total(renamed_column) == 125


def test_admin_script_repair_moves_the_filter(renamed_column: Any) -> None:
    support.call_admin(renamed_column, "ADD_OR_REPLACE_DIMENSION", MODEL_NAME=MODEL,
                       OBJECT_NAME="SALES", ENTITY_NAME="orders", DIMENSION_NAME="order_status",
                       EXPRESSION="o.status_code", DATA_TYPE="VARCHAR(20)")
    renamed_column.commit()
    assert completed_total(renamed_column) == 125
