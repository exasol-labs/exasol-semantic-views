"""A column selected by a synonym comes back under the name the caller wrote.

`RENAME METRIC` keeps the old name as a synonym so existing statements keep
working, but both lanes named every unaliased column after the field it
resolved to. `SELECT completed_revenue` therefore returned a column called
COMPLETED_NET_REVENUE, and every consumer reading results by column name lost
the value. A column reference in SQL is named after what was written; so is
this one. `revenue` is a declared synonym of `total_revenue` in the sales model.
"""

from __future__ import annotations

from typing import Any

import verify_support as support


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


def json_columns(con: Any, request: dict[str, Any]) -> tuple[list[str], list[tuple[Any, ...]], str]:
    compiled = support.compile_request(con, {"model": "sales", "object": "SALES", **request})
    assert compiled["status"] == "OK", compiled["error_message"]
    sql = str(compiled["generated_sql"])
    names, rows = columns(con, sql)
    return names, rows, sql


def test_structured_request_names_a_synonym_as_written(con: Any) -> None:
    request = {"dimensions": ["customer_region"],
               "order_by": [{"field": "revenue", "direction": "DESC"}]}
    names, rows, sql = json_columns(con, {**request, "metrics": ["revenue"]})
    assert names == ["customer_region", "revenue"]
    _, canonical, _ = json_columns(con, {**request, "metrics": ["total_revenue"]})
    assert rows == canonical
    assert sql.rstrip().endswith("\nORDER BY 2 DESC"), sql


def test_structured_request_without_a_synonym_is_not_rewrapped(con: Any) -> None:
    names, _, sql = json_columns(con, {"dimensions": ["customer_region"],
                                       "metrics": ["total_revenue"]})
    assert names == ["customer_region", "total_revenue"]
    assert "\nFROM (\n" not in sql, sql
