#!/usr/bin/env python3
"""Verify ORDER BY ordinals with null placement, as Tableau writes them.

Tableau populates a filter card with
`SELECT "SALES"."ORDER_STATUS" AS "ORDER_STATUS" FROM ... GROUP BY 1
ORDER BY 1 ASC NULLS FIRST`. The null placement stopped the ordinal being
recognised, so the statement was refused with SEMANTIC_QUERY_060 and the card
stayed empty (GitHub #14). This asserts against the sales model that:

- the exact Tableau statement answers, and its SQL keeps ASC NULLS FIRST;
- every ordinal of a multi-projection statement resolves, direction and null
  placement kept;
- zero, negative, fractional and out-of-range ordinals are SEMANTIC_QUERY_064;
- a structured request carries the same null placement.
"""

from __future__ import annotations

from typing import Any
import importlib.util
import re
from pathlib import Path

# Connection defaults, SQL escaping and named result reads live in
# tools/verify_support.py so verifiers do not each carry their own. See the
# ratchet in tests/test_conventions.py.
_SUPPORT = importlib.util.spec_from_file_location(
    "verify_support", Path(__file__).with_name("verify_support.py"))
support = importlib.util.module_from_spec(_SUPPORT)
_SUPPORT.loader.exec_module(support)

TABLEAU = ('SELECT "SALES"."ORDER_STATUS" AS "ORDER_STATUS" FROM "SEMANTIC_SALES"."SALES" "SALES"'
           ' GROUP BY 1 ORDER BY 1 ASC NULLS FIRST')


def flat(sql: str) -> str:
    return " ".join(sql.split())


def main() -> int:
    con = support.connect()
    try:
        result = support.compile_sql(con, TABLEAU)
        if result.get("status") != "OK" or 'ASC NULLS FIRST' not in flat(result["generated_sql"]):
            raise AssertionError(f"Tableau's filter-domain statement: {result}")
        rows = [row[0] for row in con.execute(result["generated_sql"]).fetchall()]
        if rows != sorted(rows):
            raise AssertionError(f"filter domain not in ascending order: {rows}")
        print(f"ok Tableau's filter-domain statement answers in order: {rows}")

        multi = support.compile_sql(con, "SELECT customer_region, order_status, total_revenue"
                                         " FROM SEMANTIC_SALES.SALES"
                                         " ORDER BY 3 DESC NULLS LAST, 1 ASC NULLS FIRST, 2")
        sql = flat(multi.get("generated_sql") or "")
        for fragment in ('"total_revenue" DESC NULLS LAST', '"customer_region" ASC NULLS FIRST',
                         '"order_status" ASC'):
            if fragment not in sql:
                raise AssertionError(f"multi-projection ordinals lost {fragment!r}: {multi}")
        revenue = [float(row[2]) for row in con.execute(multi["generated_sql"]).fetchall()]
        if revenue != sorted(revenue, reverse=True):
            raise AssertionError(f"not ordered by the third item: {revenue}")
        print("ok every ordinal resolves with its direction and null placement")

        for bad in ("0", "4", "-1", "1.5"):
            refused = support.compile_sql(con, "SELECT customer_region, order_status, total_revenue"
                                               f" FROM SEMANTIC_SALES.SALES ORDER BY {bad} ASC NULLS FIRST")
            if refused.get("error_code") != "SEMANTIC_QUERY_064" \
                    or "which has 3 items" not in str(refused.get("error_message")):
                raise AssertionError(f"ORDER BY {bad} was not SEMANTIC_QUERY_064: {refused}")
        print("ok zero, negative, fractional and out-of-range ordinals are SEMANTIC_QUERY_064")

        request = support.compile_request(con, {
            "model": "sales", "object": "SALES", "dimensions": ["order_status"],
            "metrics": ["total_revenue"],
            "order_by": [{"field": "order_status", "direction": "DESC", "nulls": "LAST"}]})
        if request.get("status") != "OK" or '"order_status" DESC NULLS LAST' not in flat(request["generated_sql"]):
            raise AssertionError(f"structured request lost the null placement: {request}")
        print("ok a structured request carries the same null placement")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
