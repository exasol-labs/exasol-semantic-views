"""Semantic DDL on a published model refreshes its published views.

A published view declares the model's columns, and BI tools read them from
EXA_ALL_COLUMNS. After `RENAME METRIC completed_revenue TO completed_net_revenue`
the view still declared COMPLETED_REVENUE, and a metric added by DDL was missing
from it, while the model still said PUBLISHED. APPLY_SEMANTIC_DEFINITION now
republishes a published model once the change has validated.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

MODEL = "view_refresh"
SRC = "VIEWREFRESH_SRC"
PUBLISHED = f"SEMANTIC_{MODEL.upper()}"


def apply(con: Any, statement: str) -> dict[str, Any]:
    rows = support.named_rows(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        f"{support.sql_string(statement)}, FALSE)"))
    con.commit()
    assert rows and rows[0]["status"] == "OK", rows
    return rows[0]


def view_columns(con: Any) -> set[str]:
    return {row[0] for row in con.execute(
        "SELECT COLUMN_NAME FROM SYS.EXA_ALL_COLUMNS"
        f" WHERE COLUMN_SCHEMA = '{PUBLISHED}' AND COLUMN_TABLE = 'SALES'").fetchall()}


def teardown(con: Any) -> None:
    for statement in (f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
                      f"DROP SCHEMA IF EXISTS {PUBLISHED} CASCADE",
                      f"DROP SCHEMA IF EXISTS {SRC} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- teardown of whatever exists
            pass
    con.commit()


@pytest.fixture
def draft(con: Any) -> Iterator[Any]:
    teardown(con)
    con.execute(f"CREATE SCHEMA {SRC}")
    con.execute(f"CREATE TABLE {SRC}.ORDERS (ORDER_ID DECIMAL(18,0), REGION VARCHAR(20),"
                " REVENUE DECIMAL(18,2))")
    con.execute(f"INSERT INTO {SRC}.ORDERS VALUES (1, 'North', 100), (2, 'South', 50)")
    m = f"'{MODEL}'"
    for statement in (
        f"CREATE_MODEL({m}, '{PUBLISHED}', 'View refresh', NULL)",
        f"ADD_ENTITY({m}, 'orders', '{SRC}', 'ORDERS', 'o', 'o.order_id', 'One order',"
        " 'Orders')",
        f"ADD_SEMANTIC_OBJECT({m}, 'SALES', 'orders', 'Sales')",
    ):
        con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    con.commit()
    apply(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE DIMENSIONS (DIMENSION region ON ENTITY orders AS o.region RETURNS VARCHAR(20)
  PUBLIC CERTIFIED)""")
    apply(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE FACTS (FACT revenue ON ENTITY orders AS o.revenue RETURNS DECIMAL(18,2)
  ADDITIVE PUBLIC)""")
    apply(con, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
REPLACE METRICS (METRIC completed_revenue AS SUM(revenue) ON ENTITY orders
  RETURNS DECIMAL(18,2) FORMAT 'currency' UNIT 'EUR' ADDITIVE PUBLIC CERTIFIED)""")
    try:
        yield con
    finally:
        teardown(con)


@pytest.fixture
def published(draft: Any) -> Any:
    draft.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")
    draft.commit()
    assert "COMPLETED_REVENUE" in view_columns(draft)
    return draft


def test_a_rename_reaches_the_published_view(published: Any) -> None:
    row = apply(published, f"ALTER SEMANTIC VIEW {MODEL}.SALES"
                           " RENAME METRIC completed_revenue TO completed_net_revenue")
    assert "published views were refreshed" in row["message"]
    columns = view_columns(published)
    assert "COMPLETED_NET_REVENUE" in columns and "COMPLETED_REVENUE" not in columns


def test_an_added_metric_reaches_the_published_view(published: Any) -> None:
    apply(published, f"""ALTER SEMANTIC VIEW {MODEL}.SALES
ADD OR REPLACE METRIC order_count AS COUNT(revenue) ON ENTITY orders RETURNS DECIMAL(18,0)
  ADDITIVE PUBLIC""")
    assert "ORDER_COUNT" in view_columns(published)


def test_a_draft_model_is_not_published_by_ddl(draft: Any) -> None:
    row = apply(draft, f"ALTER SEMANTIC VIEW {MODEL}.SALES"
                       " RENAME METRIC completed_revenue TO completed_net_revenue")
    assert "refreshed" not in row["message"]
    assert view_columns(draft) == set()
