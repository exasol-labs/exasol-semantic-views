#!/usr/bin/env python3
"""Verify that filtering on an unselected dimension never changes the grain.

Reference expansion compiled every field a statement names into the derived
table and applied the block's WHERE over the grouped result. A dimension that
was only filtered on therefore joined the grain:
`SELECT gross_margin_pct FROM obj WHERE customer_region IN ('North', 'West')`
answered one row bare and two rows wrapped -- and a statement served by
expansion, such as one with IN (subquery), returned one row per region bare too.
The wrapper, or the lane, changed the answer.

The filter is now applied inside the compile, before aggregation. This asserts
against the live sales model that:

- every wrapped form of a filter-only statement answers what the bare
  statement answers, row for row;
- a filter the compile cannot run before aggregation is refused with
  SEMANTIC_QUERY_017 rather than grouped by the filtered dimension;
- a filter on a selected dimension, or in the outer block, is left alone.
"""

from __future__ import annotations

from typing import Any
import importlib.util
from pathlib import Path

# Connection defaults, SQL escaping and named result reads live in
# tools/verify_support.py so verifiers do not each carry their own. See the
# ratchet in tests/test_conventions.py.
_SUPPORT = importlib.util.spec_from_file_location(
    "verify_support", Path(__file__).with_name("verify_support.py"))
support = importlib.util.module_from_spec(_SUPPORT)
_SUPPORT.loader.exec_module(support)

OBJECT = "SEMANTIC_SALES.SALES"
FILTER = "customer_region IN ('North', 'West')"


def rows(con: Any, sql: str) -> tuple[str, Any]:
    result = support.compile_sql(con, sql)
    if result.get("status") != "OK":
        return "refused", result.get("error_code")
    return "rows", sorted(tuple(str(v) for v in row)
                          for row in con.execute(result["generated_sql"]).fetchall())


def main() -> int:
    con = support.connect()
    try:
        questions = {
            "a ratio": f"SELECT gross_margin_pct FROM {OBJECT} WHERE {FILTER}",
            "an additive metric": f"SELECT total_revenue FROM {OBJECT} WHERE {FILTER}",
            "with a selected dimension": (f"SELECT order_status, total_revenue FROM {OBJECT}"
                                          f" WHERE {FILTER}"),
            "a metric predicate beside it": (f"SELECT total_revenue FROM {OBJECT}"
                                             f" WHERE {FILTER} AND total_revenue > 0"),
        }
        for label, bare in questions.items():
            expected = rows(con, bare)
            if expected[0] != "rows":
                raise AssertionError(f"bare {label} did not compile: {expected}")
            wrapped = {
                "subquery": f"SELECT * FROM ({bare}) t",
                "CTE": f"WITH x AS ({bare}) SELECT * FROM x",
                "alias-qualified": "SELECT * FROM (" + bare.replace(
                    f"FROM {OBJECT} WHERE customer_region",
                    f"FROM {OBJECT} t0 WHERE t0.customer_region") + ") t",
                "multi-line": "SELECT *\nFROM (\n" + bare.replace(" WHERE ", "\n WHERE ") + "\n) t",
            }
            for shape, sql in wrapped.items():
                if rows(con, sql) != expected:
                    raise AssertionError(f"{label}, {shape}: {rows(con, sql)} != {expected}")
        print(f"ok wrapped equals bare: {', '.join(questions)} -- subquery, CTE, alias, multi-line")

        # Served by expansion even bare, and used to answer one row per region.
        for sql in (f"SELECT total_revenue FROM {OBJECT} WHERE customer_region IN"
                    " (SELECT REGION FROM MART.CUSTOMERS)",
                    f"SELECT total_revenue FROM {OBJECT} t0 WHERE EXISTS"
                    " (SELECT 1 FROM MART.CUSTOMERS c WHERE c.REGION = t0.customer_region)",
                    f"SELECT * FROM (SELECT total_revenue FROM {OBJECT} WHERE customer_region IN"
                    f" (SELECT t1.customer_region FROM {OBJECT} t1)) t"):
            if rows(con, sql) != ("refused", "SEMANTIC_QUERY_017"):
                raise AssertionError(f"not refused with SEMANTIC_QUERY_017: {sql} -> {rows(con, sql)}")
        print("ok a filter the compile cannot run first is refused: IN (subquery), EXISTS, nested object")

        by_region = rows(con, f"SELECT customer_region, total_revenue FROM {OBJECT}")
        north = [row for row in by_region[1] if row[0] == "North"]
        for sql in (f"SELECT * FROM (SELECT customer_region, total_revenue FROM {OBJECT}"
                    " WHERE customer_region = 'North') t",
                    f"SELECT * FROM (SELECT customer_region, total_revenue FROM {OBJECT}) t"
                    " WHERE t.customer_region = 'North'",
                    f"SELECT customer_region, total_revenue FROM {OBJECT} WHERE customer_region IN"
                    " (SELECT 'North' FROM DUAL)"):
            if rows(con, sql) != ("rows", north):
                raise AssertionError(f"selected-dimension filter changed: {sql} -> {rows(con, sql)}")
        print("ok a filter on a selected dimension, or in the outer block, is unchanged")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
