"""Joins that provably cannot repeat a semantic row are answered, not refused.

The composition guard (SEMANTIC_QUERY_012) exists because a join can repeat a
semantic result's rows and re-aggregating the repeats double-counts. It was
syntactic: two governed measures pre-aggregated to region and joined on region,
or a governed result joined to a one-row constant table, were refused although
neither can repeat a row -- so analysts left the governed layer to get them.
And two grouped queries side by side under UNION ALL were refused as a GROUP BY
error (SEMANTIC_QUERY_008), though nothing was joined at all.

A one-row relation, and grouped semantic queries joined one-to-one on their
whole grain, are now answered, with each side's own numbers. Everything else
the guard refused it still refuses.
"""

from __future__ import annotations

from typing import Any

import pytest

import verify_support as support

REVENUE = ("(SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"
           " GROUP BY customer_region)")
COST = ("(SELECT customer_region, total_cost FROM SEMANTIC_SALES.SALES"
        " GROUP BY customer_region)")


def answer(con: Any, sql: str) -> list[tuple[str, ...]]:
    compiled = support.compile_sql(con, sql)
    assert compiled["status"] == "OK", compiled["error_message"]
    return sorted(tuple(str(value) for value in row)
                  for row in con.execute(compiled["generated_sql"]).fetchall())


def per_region(con: Any, metric: str) -> dict[str, float]:
    rows = answer(con, f"SELECT customer_region, {metric} FROM SEMANTIC_SALES.SALES"
                       " GROUP BY customer_region")
    return {region: float(value) for region, value in rows}


@pytest.mark.parametrize("sql", [
    f"SELECT a.customer_region, a.total_revenue, b.total_cost FROM {REVENUE} a"
    f" JOIN {COST} b ON a.customer_region = b.customer_region",
    f"WITH a AS {REVENUE}, b AS {COST} SELECT a.customer_region, a.total_revenue,"
    " b.total_cost FROM a JOIN b ON a.customer_region = b.customer_region",
    f"SELECT a.customer_region, a.total_revenue, b.total_cost FROM {REVENUE} a"
    f" LEFT OUTER JOIN {COST} b ON b.customer_region = a.customer_region",
])
def test_governed_measures_side_by_side_keep_their_own_numbers(con: Any, sql: str) -> None:
    revenue, cost = per_region(con, "total_revenue"), per_region(con, "total_cost")
    rows = answer(con, sql)
    assert {region: float(value) for region, value, _ in rows} == revenue
    assert {region: float(value) for region, _, value in rows} == cost


@pytest.mark.parametrize("relation", [
    f"{REVENUE} s",
    "SEMANTIC_SALES.SALES s",
])
def test_a_one_row_relation_repeats_nothing(con: Any, relation: str) -> None:
    revenue = per_region(con, "total_revenue")
    rows = answer(con, f"SELECT s.customer_region, s.total_revenue * k.rate FROM {relation}"
                       " CROSS JOIN (SELECT 2 AS rate FROM DUAL) k")
    assert {region: float(value) for region, value in rows} == \
        {region: 2 * value for region, value in revenue.items()}


def test_a_multiplication_is_not_a_star(con: Any) -> None:
    # `*` after an operand read as SELECT *, compiling every column: the finest
    # grain, five partial North rows where `/ 2` gave one.
    revenue = per_region(con, "total_revenue")
    rows = answer(con, "SELECT s.customer_region, s.total_revenue * 2"
                       " FROM SEMANTIC_SALES.SALES s")
    assert {region: float(value) for region, value in rows} == \
        {region: 2 * value for region, value in revenue.items()}


def test_union_all_of_grouped_queries_is_answered(con: Any) -> None:
    revenue, cost = per_region(con, "total_revenue"), per_region(con, "total_cost")
    rows = answer(con, "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"
                       " GROUP BY customer_region UNION ALL SELECT customer_region,"
                       " total_cost FROM SEMANTIC_SALES.SALES GROUP BY customer_region"
                       " ORDER BY 1")
    assert sorted(float(value) for _, value in rows) == \
        sorted(list(revenue.values()) + list(cost.values()))


@pytest.mark.parametrize("sql", [
    # The fan-out the guard exists for.
    "SELECT t0.customer_region, SUM(t0.total_revenue) FROM SEMANTIC_SALES.SALES t0"
    " JOIN MART.CUSTOMERS c ON c.REGION = t0.customer_region GROUP BY 1",
    # Grains that differ, so one side repeats.
    f"SELECT * FROM {REVENUE} a JOIN (SELECT customer_region, order_status, total_cost"
    " FROM SEMANTIC_SALES.SALES GROUP BY customer_region, order_status) b"
    " ON a.customer_region = b.customer_region",
    # Conditions that do not pin one row.
    f"SELECT * FROM {REVENUE} a JOIN {COST} b"
    " ON a.customer_region = b.customer_region OR a.total_revenue > 0",
    f"SELECT * FROM {REVENUE} a CROSS JOIN {COST} b",
    # A "constant" relation that is not one row.
    f"SELECT * FROM {REVENUE} a CROSS JOIN (SELECT 1 AS x FROM MART.CUSTOMERS) k",
])
def test_a_join_that_can_repeat_rows_is_still_refused(con: Any, sql: str) -> None:
    refused = support.compile_sql(con, sql)
    assert refused["status"] == "ERROR"
    assert refused["error_code"] == "SEMANTIC_QUERY_012", refused
