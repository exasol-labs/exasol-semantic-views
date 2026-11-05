"""Under the composition opt-in, the Semantic SQL forms still mean what they say.

SEMANTIC_QUERY_012 refuses a join and names SET_MODEL_DERIVED_COMPOSITION, and
SEMANTIC_QUERY_005 teaches the GROUP BY and MEASURE() forms. Opting in turned
exactly those forms into raw engine errors: the reference was spliced as a
derived table already aggregated, and the author's GROUP BY over a bare metric
was "not a valid GROUP BY expression", MEASURE() a function Exasol does not
have. A wrapped semantic query with no join at all broke the same way.

Each form now answers with the metric's value per group -- not inflated by the
join, which is the hazard the opt-in accepts only for explicit re-aggregation --
or, where the GROUP BY splits the object's grain, is refused with
SEMANTIC_QUERY_021 and a remedy.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

JOIN = (" FROM SEMANTIC_SALES.SALES t0 JOIN MART.CUSTOMERS c"
        " ON c.REGION = t0.customer_region")


def answer(con: Any, sql: str) -> dict[str, float]:
    compiled = support.compile_sql(con, sql)
    assert compiled["status"] == "OK", compiled["error_message"]
    return {str(row[0]): float(row[1])
            for row in con.execute(compiled["generated_sql"]).fetchall()}


@pytest.fixture
def composing(con: Any) -> Iterator[Any]:
    truth = answer(con, "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"
                        " GROUP BY customer_region")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('sales', 'TRUE')")
    try:
        yield con, truth
    finally:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('sales', 'FALSE')")


@pytest.mark.parametrize("sql", [
    # The forms SEMANTIC_QUERY_005 teaches, beside the join SEMANTIC_QUERY_012
    # refused. North matches two customers; its revenue is still 3635.
    "SELECT t0.customer_region, t0.total_revenue" + JOIN + " GROUP BY t0.customer_region",
    "SELECT t0.customer_region, t0.total_revenue" + JOIN + " GROUP BY 1",
    "SELECT t0.customer_region, MEASURE(t0.total_revenue)" + JOIN + " GROUP BY 1",
    "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES, MART.CUSTOMERS c"
    " WHERE c.REGION = customer_region GROUP BY customer_region",
    # No join at all: a wrapped semantic query is still compiled as one.
    "SELECT * FROM (SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"
    " GROUP BY customer_region) x",
    "SELECT * FROM (SELECT customer_region, MEASURE(total_revenue) FROM SEMANTIC_SALES.SALES"
    " GROUP BY customer_region) x",
])
def test_the_semantic_forms_answer_the_metric(composing: Any, sql: str) -> None:
    con, truth = composing
    assert answer(con, sql) == truth


def test_explicit_reaggregation_keeps_ordinary_sql_meaning(composing: Any) -> None:
    # What the opt-in accepts: SUM over the joined rows counts North twice.
    con, truth = composing
    summed = answer(con, "SELECT t0.customer_region, SUM(t0.total_revenue)" + JOIN + " GROUP BY 1")
    assert summed["North"] == 2 * truth["North"]


def test_a_group_by_that_splits_the_grain_is_refused(composing: Any) -> None:
    con, _ = composing
    refused = support.compile_sql(con, "SELECT c.REGION, t0.total_revenue" + JOIN
                                       + " GROUP BY c.REGION")
    assert refused["status"] == "ERROR"
    assert refused["error_code"] == "SEMANTIC_QUERY_021", refused
    assert "SUM(t0.total_revenue)" in refused["error_message"]
