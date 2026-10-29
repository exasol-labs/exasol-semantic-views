"""An aggregate over DISTINCT is refused by name, with the pattern that runs.

`COUNT(DISTINCT product)` was refused as `Unknown semantic field: DISTINCT`:
unwrapped, its argument read as a field `DISTINCT` aliased `product`, which sent
the reader looking for a column nobody wrote. A window in the select list was
refused without saying what to do instead. Both run when the governed query is
wrapped and the ordinary SQL sits outside it, so both refusals now say so.
"""

from __future__ import annotations

from typing import Any

import pytest

import verify_support as support


def refusal(con: Any, sql: str) -> dict[str, Any]:
    result = support.compile_sql(con, sql)
    assert result["status"] == "ERROR", result
    return result


@pytest.mark.parametrize("sql", [
    "SELECT customer_region, COUNT(DISTINCT product_category) FROM SEMANTIC_SALES.SALES"
    " GROUP BY customer_region",
    "SELECT customer_region, MEASURE(DISTINCT total_revenue) FROM SEMANTIC_SALES.SALES"
    " GROUP BY customer_region",
    "SELECT customer_region FROM SEMANTIC_SALES.SALES GROUP BY customer_region"
    " ORDER BY COUNT(DISTINCT product_category)",
    "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"
    " GROUP BY customer_region HAVING COUNT(DISTINCT product_category) > 1",
])
def test_an_aggregate_over_distinct_is_named(con: Any, sql: str) -> None:
    result = refusal(con, sql)
    assert result["error_code"] == "SEMANTIC_QUERY_019", result
    assert "(DISTINCT ...) is not supported" in result["error_message"]
    assert "Wrap the semantic query" in result["error_message"]


def test_a_window_in_the_select_list_says_how_to_run_it(con: Any) -> None:
    result = refusal(con, "SELECT customer_region, RANK() OVER (ORDER BY total_revenue DESC)"
                          " FROM SEMANTIC_SALES.SALES GROUP BY customer_region")
    assert result["error_code"] == "SEMANTIC_QUERY_005", result
    assert "Wrap the semantic query" in result["error_message"]


def test_the_wrapped_forms_the_refusals_point_to_run(con: Any) -> None:
    for sql in (
        "SELECT COUNT(DISTINCT product_category) FROM (SELECT product_category,"
        " total_revenue FROM SEMANTIC_SALES.SALES GROUP BY product_category)",
        "SELECT customer_region, total_revenue,"
        " RANK() OVER (ORDER BY total_revenue DESC) rnk FROM (SELECT customer_region,"
        " total_revenue FROM SEMANTIC_SALES.SALES GROUP BY customer_region)",
    ):
        result = support.compile_sql(con, sql)
        assert result["status"] == "OK", result["error_message"]
        assert con.execute(result["generated_sql"]).fetchall()
