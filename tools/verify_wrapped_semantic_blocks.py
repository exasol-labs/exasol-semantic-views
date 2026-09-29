#!/usr/bin/env python3
"""Verify that a wrapped block aggregating a semantic object is compiled as one.

Power BI DirectQuery aggregates inside a derived table and shapes the result
outside it -- `SELECT r, C1 FROM (SELECT r, SUM(m) AS C1 FROM obj GROUP BY r)
ITBL WHERE NOT C1 IS NULL LIMIT 1000001` is its basic table visual. Replacing
only the reference left that inner GROUP BY to run over an already-grouped
result, so every such query was refused with SEMANTIC_QUERY_015 (GitHub #15).
The inner block is now compiled by the whole-statement lane, at the grain it
names, and spliced in; everything outside it stays ordinary SQL.

This asserts, in a preprocessor-enabled session against the sales model:

- Power BI's table, wide, filtered and Top N shapes answer what their bare
  inner statements answer, with Power BI's aliases;
- the block's aggregate checks still apply (a mismatched AVG is
  SEMANTIC_QUERY_007), and so does the outer re-aggregation guard
  (SEMANTIC_QUERY_016);
- an ungrouped aggregating block, which failed in Exasol, now answers;
- an unquoted alias is output as Exasol names it, so the wrapper finds it.
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

SALES = '"EXA_DB"."SEMANTIC_SALES"."SALES"'


def outcome(con: Any, sql: str) -> tuple[str, Any]:
    try:
        statement = con.execute(sql)
        return "rows", (list(statement.columns().keys()),
                        sorted(tuple(str(v) for v in row) for row in statement.fetchall()))
    except Exception as exc:  # noqa: BLE001 -- the refusal is the result
        code = re.search(r"SEMANTIC_[A-Z]+_\d{3}", str(exc))
        return "refused", code.group(0) if code else " ".join(str(exc).split())[:160]


def main() -> int:
    con = support.connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        shapes = {
            "table visual": (
                'SELECT "CUSTOMER_REGION", "C1" FROM ({inner}) AS "ITBL"'
                ' WHERE NOT "C1" IS NULL LIMIT 1000001',
                f'SELECT "CUSTOMER_REGION", SUM("TOTAL_REVENUE") AS "C1" FROM {SALES}'
                ' GROUP BY "CUSTOMER_REGION"'),
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
        for label, (wrapper, inner) in shapes.items():
            bare = outcome(con, inner)
            wrapped = outcome(con, wrapper.format(inner=inner))
            if bare[0] != "rows" or wrapped[1][1] != bare[1][1]:
                raise AssertionError(f"{label}: wrapped {wrapped} != bare {bare}")
        print(f"ok wrapped equals bare: {', '.join(shapes)}")

        top = outcome(con, 'SELECT "CUSTOMER_REGION", "C1" FROM (SELECT "CUSTOMER_REGION",'
                           f' SUM("TOTAL_REVENUE") AS "C1" FROM {SALES} GROUP BY "CUSTOMER_REGION")'
                           ' AS "ITBL" ORDER BY "C1" DESC LIMIT 2')
        by_region = outcome(con, "SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM SEMANTIC_SALES.SALES")
        largest = sorted(by_region[1][1], key=lambda row: -float(row[1]))[:2]
        if top != ("rows", (["CUSTOMER_REGION", "C1"], sorted(largest))):
            raise AssertionError(f"Top N is not the two largest regions: {top} vs {largest}")
        print("ok Top N over the compiled block keeps Power BI's ORDER BY and LIMIT")

        ungrouped = outcome(con, "SELECT * FROM (SELECT CUSTOMER_REGION, SUM(TOTAL_REVENUE)"
                                 " FROM SEMANTIC_SALES.SALES) esv_wrapper")
        if ungrouped[0] != "rows" or ungrouped[1][1] != by_region[1][1]:
            raise AssertionError(f"ungrouped aggregating block did not answer: {ungrouped}")
        print("ok an aggregating block without GROUP BY answers instead of failing in Exasol")

        for label, sql, code in (
            ("mismatched aggregate", f'SELECT * FROM (SELECT "CUSTOMER_REGION",'
             f' AVG("TOTAL_REVENUE") AS "C1" FROM {SALES} GROUP BY "CUSTOMER_REGION") t',
             "SEMANTIC_QUERY_007"),
            ("outer average of a ratio", "SELECT AVG(x.m) FROM (SELECT CUSTOMER_REGION,"
             " MEASURE(GROSS_MARGIN_PCT) AS m FROM SEMANTIC_SALES.SALES GROUP BY CUSTOMER_REGION) x",
             "SEMANTIC_QUERY_016"),
        ):
            if outcome(con, sql) != ("refused", code):
                raise AssertionError(f"{label} was not refused with {code}: {outcome(con, sql)}")
        print("ok the block's aggregate checks and the outer re-aggregation guard still apply")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
