"""The SQL lane's ORDER BY is the outermost clause of the SQL it emits.

The lane wraps the compiled statement to return the caller's select list, and
the caller's ORDER BY stayed inside that derived table. The order happened to
survive, but SQL does not promise that it will.
"""

from __future__ import annotations

from typing import Any

import verify_support as support


def compiled(con: Any, sql: str) -> str:
    result = support.compile_sql(con, sql)
    assert result["status"] == "OK", result["error_message"]
    return str(result["generated_sql"])


def test_order_by_is_restated_outside_the_wrapper(con: Any) -> None:
    sql = compiled(con, "SELECT total_revenue, customer_region FROM SEMANTIC_SALES.SALES"
                        " ORDER BY total_revenue DESC NULLS LAST LIMIT 2")
    assert sql.rstrip().endswith("\nORDER BY 1 DESC NULLS LAST"), sql
    rows = [tuple(row) for row in con.execute(sql).fetchall()]
    assert rows == sorted(rows, key=lambda row: row[0], reverse=True)


def test_order_by_a_synonym_or_an_ordinal(con: Any) -> None:
    by_synonym = compiled(con, "SELECT customer_region, revenue FROM SEMANTIC_SALES.SALES"
                               " ORDER BY revenue")
    assert by_synonym.rstrip().endswith("\nORDER BY 2 ASC"), by_synonym
    by_ordinal = compiled(con, "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"
                               " ORDER BY 1 DESC")
    assert by_ordinal.rstrip().endswith("\nORDER BY 1 DESC"), by_ordinal
