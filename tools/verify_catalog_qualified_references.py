#!/usr/bin/env python3
"""Verify that a catalog-qualified reference is the same reference.

Power BI writes every relation as `"EXA_DB"."<schema>"."<object>"`. Both SQL
lanes read the first two parts as schema.object, so the published schema came
out as EXA_DB, the statement matched no model, and it fell through to the view
guard with SEMANTIC_SURFACE_001 -- in a session where the preprocessor was on
(GitHub #9). That also blocked the rest of Power BI's shape: the `1 AS "C1"`
constant (#10) and the `LIMIT 1000001` fetch sentinel (#11) both worked only
with a two-part name.

This asserts, in a preprocessor-enabled session against the sales model, that
every catalog-qualified shape answers exactly what its two-part form answers,
that Power BI's full DirectQuery statement runs, and that a catalog other than
EXA_DB is left for Exasol to report.
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

TWO_PART = '"SEMANTIC_SALES"."{obj}"'
THREE_PART = '"EXA_DB"."SEMANTIC_SALES"."{obj}"'

SHAPES = {
    "Power BI column fetch": ('SELECT "SHIP_MODE", "CUSTOMER_SEGMENT", "TOTAL_FREIGHT"'
                              " FROM {ref} LIMIT 100", "ORDER_HEADER"),
    "Power BI DirectQuery": ('SELECT 1 AS "C1", "CUSTOMER_REGION", "TOTAL_REVENUE"'
                             " FROM {ref} LIMIT 1000001", "SALES"),
    "aggregate with GROUP BY": ('SELECT "SHIP_MODE", SUM("TOTAL_FREIGHT") AS "S" FROM {ref}'
                                ' GROUP BY "SHIP_MODE"', "ORDER_HEADER"),
    "aliased and qualified": ('SELECT "OH"."SHIP_MODE" FROM {ref} "OH"', "ORDER_HEADER"),
    "inside a subquery": ('SELECT * FROM (SELECT "CUSTOMER_REGION", "TOTAL_REVENUE"'
                          " FROM {ref}) t", "SALES"),
}


def outcome(con: Any, sql: str) -> tuple[str, Any]:
    try:
        statement = con.execute(sql)
        return "rows", (list(statement.columns().keys()),
                        sorted(tuple(str(v) for v in row) for row in statement.fetchall()))
    except Exception as exc:  # noqa: BLE001 -- the refusal is the result
        return "error", " ".join(str(exc).split())


def main() -> int:
    con = support.connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        for label, (template, obj) in SHAPES.items():
            expected = outcome(con, template.format(ref=TWO_PART.format(obj=obj)))
            actual = outcome(con, template.format(ref=THREE_PART.format(obj=obj)))
            if expected[0] != "rows" or actual != expected:
                raise AssertionError(f"{label}: {actual} != {expected}")
        print(f"ok EXA_DB.<schema>.<object> answers as <schema>.<object>: {', '.join(SHAPES)}")

        columns, rows = outcome(con, SHAPES["Power BI DirectQuery"][0].format(
            ref=THREE_PART.format(obj="SALES")))[1]
        if columns[0] != "C1" or {row[0] for row in rows} != {"1"} or len(rows) < 2:
            raise AssertionError(f"Power BI shape lost its constant column: {columns} {rows}")
        print("ok Power BI's DirectQuery statement runs end to end, C1 first")

        unquoted = outcome(con, "SELECT customer_region, total_revenue FROM exa_db.semantic_sales.sales")
        if unquoted[0] != "rows":
            raise AssertionError(f"unquoted catalog name refused: {unquoted}")
        other = outcome(con, 'SELECT "CUSTOMER_REGION" FROM "OTHERDB"."SEMANTIC_SALES"."SALES"')
        if other[0] != "error" or "not found" not in other[1] \
                or re.search(r"SEMANTIC_[A-Z]+_\d{3}", other[1]):
            raise AssertionError(f"another catalog was not left to Exasol: {other}")
        print("ok an unquoted catalog folds; any catalog but EXA_DB is left to Exasol")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
