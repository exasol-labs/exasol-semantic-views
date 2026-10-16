"""A catalog-qualified reference is the same reference.

Power BI writes every relation as `"EXA_DB"."<schema>"."<object>"`. Both SQL
lanes read the first two parts as schema.object, so the published schema came
out as EXA_DB, the statement matched no model, and it fell through to the view
guard with SEMANTIC_SURFACE_001 -- in a session where the preprocessor was on
(GitHub #9). That also blocked the rest of Power BI's shape: the `1 AS "C1"`
constant (#10) and the `LIMIT 1000001` fetch sentinel (#11) both worked only
with a two-part name.
"""

from __future__ import annotations

import re

import pytest

from verify_support import outcome

TWO_PART = '"SEMANTIC_SALES"."{obj}"'
THREE_PART = '"EXA_DB"."SEMANTIC_SALES"."{obj}"'
DIRECTQUERY = 'SELECT 1 AS "C1", "CUSTOMER_REGION", "TOTAL_REVENUE" FROM {ref} LIMIT 1000001'

SHAPES = {
    "Power BI column fetch": ('SELECT "SHIP_MODE", "CUSTOMER_SEGMENT", "TOTAL_FREIGHT"'
                              " FROM {ref} LIMIT 100", "ORDER_HEADER"),
    "Power BI DirectQuery": (DIRECTQUERY, "SALES"),
    "aggregate with GROUP BY": ('SELECT "SHIP_MODE", SUM("TOTAL_FREIGHT") AS "S" FROM {ref}'
                                ' GROUP BY "SHIP_MODE"', "ORDER_HEADER"),
    "aliased and qualified": ('SELECT "OH"."SHIP_MODE" FROM {ref} "OH"', "ORDER_HEADER"),
    "inside a subquery": ('SELECT * FROM (SELECT "CUSTOMER_REGION", "TOTAL_REVENUE"'
                          " FROM {ref}) t", "SALES"),
}


@pytest.mark.parametrize("template, obj", SHAPES.values(), ids=SHAPES.keys())
def test_three_parts_answer_as_two(semantic_con, template, obj):
    expected = outcome(semantic_con, template.format(ref=TWO_PART.format(obj=obj)))
    assert expected[0] == "rows", expected
    assert outcome(semantic_con, template.format(ref=THREE_PART.format(obj=obj))) == expected


def test_power_bi_directquery_runs_with_its_constant_first(semantic_con):
    kind, (columns, rows) = outcome(semantic_con, DIRECTQUERY.format(ref=THREE_PART.format(obj="SALES")))
    assert kind == "rows"
    assert columns[0] == "C1"
    assert {row[0] for row in rows} == {"1"} and len(rows) >= 2


def test_an_unquoted_catalog_folds(semantic_con):
    unquoted = outcome(semantic_con, "SELECT customer_region, total_revenue"
                                     " FROM exa_db.semantic_sales.sales")
    assert unquoted[0] == "rows", unquoted


def test_any_other_catalog_is_left_to_exasol(semantic_con):
    kind, message = outcome(semantic_con, 'SELECT "CUSTOMER_REGION" FROM "OTHERDB"."SEMANTIC_SALES"."SALES"')
    assert kind == "refused"
    assert "not found" in message
    assert not re.search(r"SEMANTIC_[A-Z]+_\d{3}", message)
