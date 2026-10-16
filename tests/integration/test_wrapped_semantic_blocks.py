"""A wrapped block aggregating a semantic object is compiled as one.

Power BI DirectQuery aggregates inside a derived table and shapes the result
outside it -- `SELECT r, C1 FROM (SELECT r, SUM(m) AS C1 FROM obj GROUP BY r)
ITBL WHERE NOT C1 IS NULL LIMIT 1000001` is its basic table visual. Replacing
only the reference left that inner GROUP BY to run over an already-grouped
result, so every such query was refused with SEMANTIC_QUERY_015 (GitHub #15).
The inner block is now compiled by the whole-statement lane, at the grain it
names, and spliced in; everything outside it stays ordinary SQL.
"""

from __future__ import annotations

import pytest

from verify_support import outcome

SALES = '"EXA_DB"."SEMANTIC_SALES"."SALES"'
BY_REGION = "SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM SEMANTIC_SALES.SALES"

# Power BI's table visual over every metric of SALES, as sent (GitHub #16).
TABLE_VISUAL = (
    'select "CUSTOMER_REGION", "ORDER_MONTH", "ORDER_STATUS", "PRODUCT_CATEGORY",'
    ' "C1", "C2", "C3", "C4", "C5" from (select "CUSTOMER_REGION", "ORDER_MONTH",'
    ' "ORDER_STATUS", "PRODUCT_CATEGORY", sum("COMPLETED_REVENUE") as "C1",'
    ' sum("TOTAL_REVENUE") as "C2", sum("TOTAL_COST") as "C3",'
    ' sum("GROSS_MARGIN_PCT") as "C4", sum("GROSS_MARGIN") as "C5"'
    f' from {SALES} group by "CUSTOMER_REGION", "ORDER_MONTH", "ORDER_STATUS",'
    ' "PRODUCT_CATEGORY") as "ITBL" where ((not "C1" is null or not "C2" is null)'
    ' or (not "C3" is null or not "C4" is null)) or not "C5" is null limit 1000001')

# Power BI's filter-domain query (GitHub #17).
FILTER_DOMAIN = f'SELECT "ORDER_STATUS", COUNT(1) AS "C1" FROM {SALES} GROUP BY "ORDER_STATUS" LIMIT 1000001'

SHAPES = {
    "table visual": (
        'SELECT "CUSTOMER_REGION", "C1" FROM ({inner}) AS "ITBL" WHERE NOT "C1" IS NULL LIMIT 1000001',
        f'SELECT "CUSTOMER_REGION", SUM("TOTAL_REVENUE") AS "C1" FROM {SALES} GROUP BY "CUSTOMER_REGION"'),
    "wide projection": (
        'SELECT "CUSTOMER_REGION", "ORDER_STATUS", "C1", "C2" FROM ({inner}) AS "ITBL"'
        ' WHERE NOT "C1" IS NULL OR NOT "C2" IS NULL LIMIT 1000001',
        f'SELECT "CUSTOMER_REGION", "ORDER_STATUS", SUM("TOTAL_REVENUE") AS "C1",'
        f' SUM("TOTAL_COST") AS "C2" FROM {SALES} GROUP BY "CUSTOMER_REGION", "ORDER_STATUS"'),
    "filter inside the block": (
        'SELECT "ORDER_STATUS", "C1" FROM ({inner}) AS "ITBL" LIMIT 1000001',
        f'SELECT "ORDER_STATUS", SUM("TOTAL_REVENUE") AS "C1" FROM {SALES}'
        ' WHERE "CUSTOMER_REGION" = \'North\' GROUP BY "ORDER_STATUS"'),
    "unquoted aliases": (
        "SELECT r, m FROM ({inner}) x",
        "SELECT CUSTOMER_REGION AS r, MEASURE(GROSS_MARGIN_PCT) AS m"
        " FROM SEMANTIC_SALES.SALES GROUP BY CUSTOMER_REGION"),
}


@pytest.mark.parametrize("wrapper, inner", SHAPES.values(), ids=SHAPES.keys())
def test_wrapped_answers_what_bare_answers(semantic_con, wrapper, inner):
    bare = outcome(semantic_con, inner)
    assert bare[0] == "rows", bare
    wrapped = outcome(semantic_con, wrapper.format(inner=inner))
    assert wrapped[0] == "rows", wrapped
    assert wrapped[1][1] == bare[1][1]


def test_top_n_keeps_power_bis_order_and_limit(semantic_con):
    top = outcome(semantic_con, 'SELECT "CUSTOMER_REGION", "C1" FROM (SELECT "CUSTOMER_REGION",'
                                f' SUM("TOTAL_REVENUE") AS "C1" FROM {SALES} GROUP BY "CUSTOMER_REGION")'
                                ' AS "ITBL" ORDER BY "C1" DESC LIMIT 2')
    largest = sorted(outcome(semantic_con, BY_REGION)[1][1], key=lambda row: -float(row[1]))[:2]
    assert top == ("rows", (["CUSTOMER_REGION", "C1"], sorted(largest)))


def test_table_visual_selects_every_metric_as_defined(semantic_con):
    summed = outcome(semantic_con, TABLE_VISUAL)
    assert summed[0] == "rows", summed
    assert summed == outcome(semantic_con, TABLE_VISUAL.replace("sum(", "MEASURE("))


@pytest.mark.parametrize("sql", [FILTER_DOMAIN, f"SELECT * FROM ({FILTER_DOMAIN}) t"],
                         ids=["bare", "wrapped"])
def test_filter_domain_lists_the_governed_values(semantic_con, sql):
    values = outcome(semantic_con, f'SELECT "ORDER_STATUS" FROM {SALES} GROUP BY "ORDER_STATUS"')
    expected = ("rows", (["ORDER_STATUS", "C1"], sorted(row + ("1",) for row in values[1][1])))
    assert outcome(semantic_con, sql) == expected


def test_an_ungrouped_aggregating_block_answers(semantic_con):
    # Used to run as plain SQL and fail in Exasol with `not a single-group group function`.
    ungrouped = outcome(semantic_con, "SELECT * FROM (SELECT CUSTOMER_REGION, SUM(TOTAL_REVENUE)"
                                      " FROM SEMANTIC_SALES.SALES) esv_wrapper")
    assert ungrouped[0] == "rows", ungrouped
    assert ungrouped[1][1] == outcome(semantic_con, BY_REGION)[1][1]


@pytest.mark.parametrize("sql, code", [
    (f'SELECT * FROM (SELECT "CUSTOMER_REGION", COUNT("TOTAL_REVENUE") AS "C1" FROM {SALES}'
     ' GROUP BY "CUSTOMER_REGION") t', "SEMANTIC_QUERY_007"),
    (f"SELECT COUNT(1) AS n FROM {SALES}", "SEMANTIC_QUERY_010"),
    ("SELECT AVG(x.m) FROM (SELECT CUSTOMER_REGION, MEASURE(GROSS_MARGIN_PCT) AS m"
     " FROM SEMANTIC_SALES.SALES GROUP BY CUSTOMER_REGION) x", "SEMANTIC_QUERY_016"),
], ids=["mismatched aggregate", "COUNT(1) naming no grain", "outer average of a ratio"])
def test_the_blocks_checks_still_apply(semantic_con, sql, code):
    assert outcome(semantic_con, sql) == ("refused", code)
