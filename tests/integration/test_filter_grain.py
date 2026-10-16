"""Filtering on an unselected dimension never changes the grain.

Reference expansion compiled every field a statement names into the derived
table and applied the block's WHERE over the grouped result. A dimension that
was only filtered on therefore joined the grain:
`SELECT gross_margin_pct FROM obj WHERE customer_region IN ('North', 'West')`
answered one row bare and two rows wrapped -- and a statement served by
expansion, such as one with IN (subquery), returned one row per region bare too.
The wrapper, or the lane, changed the answer. The filter is now applied inside
the compile, before aggregation.
"""

from __future__ import annotations

from typing import Any

import pytest

import verify_support as support

OBJECT = "SEMANTIC_SALES.SALES"
FILTER = "customer_region IN ('North', 'West')"

QUESTIONS = {
    "a ratio": f"SELECT gross_margin_pct FROM {OBJECT} WHERE {FILTER}",
    "an additive metric": f"SELECT total_revenue FROM {OBJECT} WHERE {FILTER}",
    "with a selected dimension": f"SELECT order_status, total_revenue FROM {OBJECT} WHERE {FILTER}",
    "a metric predicate beside it": (f"SELECT total_revenue FROM {OBJECT}"
                                     f" WHERE {FILTER} AND total_revenue > 0"),
}

WRAPPERS = {
    "subquery": lambda bare: f"SELECT * FROM ({bare}) t",
    "CTE": lambda bare: f"WITH x AS ({bare}) SELECT * FROM x",
    "alias-qualified": lambda bare: "SELECT * FROM (" + bare.replace(
        f"FROM {OBJECT} WHERE customer_region", f"FROM {OBJECT} t0 WHERE t0.customer_region") + ") t",
    "multi-line": lambda bare: "SELECT *\nFROM (\n" + bare.replace(" WHERE ", "\n WHERE ") + "\n) t",
}


def rows(con: Any, sql: str) -> tuple[str, Any]:
    result = support.compile_sql(con, sql)
    if result.get("status") != "OK":
        return "refused", result.get("error_code")
    return "rows", sorted(tuple(str(v) for v in row)
                          for row in con.execute(result["generated_sql"]).fetchall())


@pytest.mark.parametrize("wrap", WRAPPERS.values(), ids=WRAPPERS.keys())
@pytest.mark.parametrize("bare", QUESTIONS.values(), ids=QUESTIONS.keys())
def test_wrapped_answers_what_bare_answers(con, bare, wrap):
    expected = rows(con, bare)
    assert expected[0] == "rows", expected
    assert rows(con, wrap(bare)) == expected


@pytest.mark.parametrize("sql", [
    f"SELECT total_revenue FROM {OBJECT} WHERE customer_region IN (SELECT REGION FROM MART.CUSTOMERS)",
    f"SELECT total_revenue FROM {OBJECT} t0 WHERE EXISTS"
    " (SELECT 1 FROM MART.CUSTOMERS c WHERE c.REGION = t0.customer_region)",
    f"SELECT * FROM (SELECT total_revenue FROM {OBJECT} WHERE customer_region IN"
    f" (SELECT t1.customer_region FROM {OBJECT} t1)) t",
], ids=["IN (subquery)", "EXISTS", "nested object"])
def test_a_filter_the_compile_cannot_run_first_is_refused(con, sql):
    # Served by expansion even bare, and used to answer one row per region.
    assert rows(con, sql) == ("refused", "SEMANTIC_QUERY_017")


@pytest.mark.parametrize("sql", [
    f"SELECT * FROM (SELECT customer_region, total_revenue FROM {OBJECT}"
    " WHERE customer_region = 'North') t",
    f"SELECT * FROM (SELECT customer_region, total_revenue FROM {OBJECT}) t"
    " WHERE t.customer_region = 'North'",
    f"SELECT customer_region, total_revenue FROM {OBJECT} WHERE customer_region IN"
    " (SELECT 'North' FROM DUAL)",
], ids=["inside the block", "outer block", "IN constant subquery"])
def test_a_filter_on_a_selected_dimension_is_unchanged(con, sql):
    by_region = rows(con, f"SELECT customer_region, total_revenue FROM {OBJECT}")
    north = [row for row in by_region[1] if row[0] == "North"]
    assert rows(con, sql) == ("rows", north)
