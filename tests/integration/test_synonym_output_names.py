"""A column selected by a synonym comes back under the name the caller wrote.

`RENAME METRIC` keeps the old name as a synonym so existing statements keep
working, but the SQL lane named every unaliased column after the field it
resolved to. `SELECT completed_revenue` therefore returned a column called
COMPLETED_NET_REVENUE, and every consumer reading results by column name lost
the value. A column reference in SQL is named after what was written; so is
this one. `revenue` is a declared synonym of `total_revenue` in the sales model.
"""

from __future__ import annotations

from typing import Any


def columns(con: Any, sql: str) -> tuple[list[str], list[tuple[Any, ...]]]:
    statement = con.execute(sql)
    return list(statement.columns().keys()), [tuple(row) for row in statement.fetchall()]


def test_synonym_names_its_column(semantic_con: Any) -> None:
    names, rows = columns(semantic_con, "SELECT customer_region, revenue"
                          " FROM SEMANTIC_SALES.SALES ORDER BY customer_region")
    assert names == ["CUSTOMER_REGION", "REVENUE"]
    _, canonical = columns(semantic_con, "SELECT customer_region, total_revenue"
                           " FROM SEMANTIC_SALES.SALES ORDER BY customer_region")
    assert rows == canonical


def test_canonical_name_and_alias_are_unchanged(semantic_con: Any) -> None:
    names, _ = columns(semantic_con, "SELECT customer_region, total_revenue,"
                       " revenue AS r FROM SEMANTIC_SALES.SALES")
    assert names == ["CUSTOMER_REGION", "TOTAL_REVENUE", "R"]


def test_measure_wrapped_synonym_names_its_column(semantic_con: Any) -> None:
    names, _ = columns(semantic_con, "SELECT customer_region, MEASURE(revenue)"
                       " FROM SEMANTIC_SALES.SALES GROUP BY customer_region")
    assert names == ["CUSTOMER_REGION", "REVENUE"]
