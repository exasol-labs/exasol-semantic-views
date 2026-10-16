"""An aggregate around a metric selects it where each group is one row.

Tableau emits `MAX(metric)` and `MIN(metric)` for attribute calculations and
cannot be configured not to. Over a SUM metric those were refused with
SEMANTIC_QUERY_007 (GitHub #8). MIN, MAX, SUM and AVG around a metric that
declares a different aggregation are honoured where each group of the statement
holds exactly one row of the object -- there they select the metric's own value
-- and every such lowering is recorded in PLAN_JSON (SUM and AVG since GitHub
#16). COUNT counts the value rather than selecting it, so a mismatch there is
still refused, and where a group would hold several rows the wrapper is refused
with SEMANTIC_QUERY_018.
"""

from __future__ import annotations

import json

import verify_support as support
from verify_support import outcome

SOURCE = '"SEMANTIC_SALES"."ORDER_HEADER" "ORDER_HEADER"'
ALIASES = ["TEMP_attr:TOTAL_FREIGHT:qk________________", "TEMP_attr:TOTAL_FREIGHT:qk________________1"]
ATTR = ('SELECT "ORDER_HEADER"."SHIP_MODE" AS "SHIP_MODE",'
        f' MAX("ORDER_HEADER"."TOTAL_FREIGHT") AS "{ALIASES[0]}",'
        f' MIN("ORDER_HEADER"."TOTAL_FREIGHT") AS "{ALIASES[1]}"'
        f' FROM {SOURCE} GROUP BY 1')


def test_tableau_attr_returns_the_governed_value_under_both_aliases(semantic_con):
    truth = outcome(semantic_con, f'SELECT "SHIP_MODE", "TOTAL_FREIGHT" FROM {SOURCE}')
    kind, (columns, rows) = outcome(semantic_con, ATTR)
    assert kind == "rows"
    assert columns == ["SHIP_MODE", *ALIASES]
    assert rows == sorted((mode, freight, freight) for mode, freight in truth[1][1])


def test_the_plan_records_both_lowerings_and_why(con):
    plan = json.loads(support.compile_sql(con, ATTR)["plan_json"])
    lowered = [(entry["wrapper"], entry["metric"], entry["declared"], entry["equivalence"])
               for entry in plan.get("wrapper_lowerings") or []]
    assert lowered == [("MAX", "total_freight", "SUM", "ONE_ROW_PER_GROUP"),
                       ("MIN", "total_freight", "SUM", "ONE_ROW_PER_GROUP")]


def test_count_around_a_sum_metric_is_still_refused(semantic_con):
    assert outcome(semantic_con, f'SELECT "ORDER_HEADER"."SHIP_MODE",'
                                 f' COUNT("ORDER_HEADER"."TOTAL_FREIGHT") FROM {SOURCE} GROUP BY 1'
                                 ) == ("refused", "SEMANTIC_QUERY_007")


def test_a_group_of_several_rows_is_refused(semantic_con):
    # The ORDER BY names a dimension, so the object is compiled at it, and
    # nothing groups by it: MAX would span every ship mode.
    assert outcome(semantic_con, "SELECT MAX(t0.TOTAL_FREIGHT) FROM SEMANTIC_SALES.ORDER_HEADER t0"
                                 " ORDER BY t0.SHIP_MODE") == ("refused", "SEMANTIC_QUERY_018")


def test_inside_a_subquery_max_is_the_metric(semantic_con):
    wrapped = outcome(semantic_con, "SELECT * FROM (SELECT MAX(t0.TOTAL_FREIGHT) AS M"
                                    " FROM SEMANTIC_SALES.ORDER_HEADER t0) x")
    total = outcome(semantic_con, "SELECT TOTAL_FREIGHT FROM SEMANTIC_SALES.ORDER_HEADER")
    assert wrapped[0] == "rows", wrapped
    assert wrapped[1][1] == total[1][1]


def test_a_qualified_mismatch_inside_a_subquery_is_judged(semantic_con):
    assert outcome(semantic_con, "SELECT * FROM (SELECT COUNT(t0.GROSS_MARGIN_PCT)"
                                 " FROM SEMANTIC_SALES.SALES t0) z") == ("refused", "SEMANTIC_QUERY_007")
