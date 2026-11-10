"""A selected metric may be a redundant Tableau group key at the chosen grain."""

from __future__ import annotations

import pytest

from verify_support import outcome

# The statement captured in issue #38, including its SELECT and GROUP BY order.
CAPTURED = '''SELECT "SALES"."COMPLETED_REVENUE" AS "COMPLETED_REVENUE",
"SALES"."CUSTOMER_REGION" AS "CUSTOMER_REGION"
FROM "SEMANTIC_SALES"."SALES" "SALES"
GROUP BY 1,
2'''
NAMED = CAPTURED.replace("GROUP BY 1,\n2", 'GROUP BY "SALES"."COMPLETED_REVENUE",\n'
                         '"SALES"."CUSTOMER_REGION"')
UNQUALIFIED = CAPTURED.replace("GROUP BY 1,\n2", "GROUP BY COMPLETED_REVENUE,\nCUSTOMER_REGION")

BASELINE = ("SELECT COMPLETED_REVENUE AS \"COMPLETED_REVENUE\","
            " CUSTOMER_REGION AS \"CUSTOMER_REGION\""
            " FROM SEMANTIC_SALES.SALES GROUP BY CUSTOMER_REGION")


@pytest.mark.parametrize("sql", [CAPTURED, NAMED, UNQUALIFIED,
                                 f"SELECT * FROM ({CAPTURED}) t",
                                 f"SELECT * FROM ({NAMED}) t",
                                 f"SELECT * FROM ({UNQUALIFIED}) t"],
                         ids=["ordinals", "qualified names", "names",
                              "nested ordinals", "nested qualified names", "nested names"])
def test_tableau_metric_group_key_preserves_each_region(semantic_con, sql):
    expected = outcome(semantic_con, BASELINE)
    assert expected[0] == "rows", expected
    assert outcome(semantic_con, sql) == expected


UNSAFE = {
    "metric only": ("SELECT COMPLETED_REVENUE FROM SEMANTIC_SALES.SALES"
                    " GROUP BY COMPLETED_REVENUE", "SEMANTIC_QUERY_008"),
    "missing dimension": ("SELECT COMPLETED_REVENUE, CUSTOMER_REGION"
                          " FROM SEMANTIC_SALES.SALES GROUP BY COMPLETED_REVENUE", "SEMANTIC_QUERY_008"),
    "unselected metric": ("SELECT CUSTOMER_REGION FROM SEMANTIC_SALES.SALES"
                          " GROUP BY CUSTOMER_REGION, COMPLETED_REVENUE", "SEMANTIC_QUERY_052"),
}


@pytest.mark.parametrize("statement, code", UNSAFE.values(), ids=UNSAFE.keys())
@pytest.mark.parametrize("nested", [False, True], ids=["bare", "nested"])
def test_unsafe_metric_group_keys_are_refused(semantic_con, statement, code, nested):
    sql = f"SELECT * FROM ({statement}) t" if nested else statement
    assert outcome(semantic_con, sql) == ("refused", code)
