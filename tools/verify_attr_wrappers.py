#!/usr/bin/env python3
"""Verify Tableau's ATTR-style MIN/MAX wrappers over a governed metric.

Tableau emits `MAX(metric)` and `MIN(metric)` for attribute calculations and
cannot be configured not to. Over a SUM metric those were refused with
SEMANTIC_QUERY_007 (GitHub #8). The policy now accepted: MIN and MAX around a
metric that declares a different aggregation are honoured where each group of
the statement holds exactly one row of the object -- there they select the
metric's own value, which is what ATTR means -- and every such lowering is
recorded in PLAN_JSON. SUM, AVG and COUNT combine values, so a mismatch there is
still refused. Where a group would hold several rows the MIN/MAX is refused with
SEMANTIC_QUERY_018 rather than answered as something else.

This asserts, in a preprocessor-enabled session against the sales model:

- Tableau's exact statement returns the governed value under both aliases;
- the plan records both lowerings;
- mismatched SUM/AVG/COUNT stay SEMANTIC_QUERY_007;
- a group holding several rows is SEMANTIC_QUERY_018;
- a qualified wrapper inside a subquery is judged as the bare one is.
"""

from __future__ import annotations

from typing import Any
import importlib.util
import json
import re
from pathlib import Path

# Connection defaults, SQL escaping and named result reads live in
# tools/verify_support.py so verifiers do not each carry their own. See the
# ratchet in tests/test_conventions.py.
_SUPPORT = importlib.util.spec_from_file_location(
    "verify_support", Path(__file__).with_name("verify_support.py"))
support = importlib.util.module_from_spec(_SUPPORT)
_SUPPORT.loader.exec_module(support)

SOURCE = '"SEMANTIC_SALES"."ORDER_HEADER" "ORDER_HEADER"'
ATTR = ('SELECT "ORDER_HEADER"."SHIP_MODE" AS "SHIP_MODE",'
        ' MAX("ORDER_HEADER"."TOTAL_FREIGHT") AS "TEMP_attr:TOTAL_FREIGHT:qk________________",'
        ' MIN("ORDER_HEADER"."TOTAL_FREIGHT") AS "TEMP_attr:TOTAL_FREIGHT:qk________________1"'
        f' FROM {SOURCE} GROUP BY 1')


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
        truth = outcome(con, f'SELECT "SHIP_MODE", "TOTAL_FREIGHT" FROM {SOURCE}')
        kind, (columns, rows) = outcome(con, ATTR)
        if kind != "rows" or columns != ["SHIP_MODE", "TEMP_attr:TOTAL_FREIGHT:qk________________",
                                         "TEMP_attr:TOTAL_FREIGHT:qk________________1"]:
            raise AssertionError(f"Tableau's ATTR statement did not run as written: {kind} {columns}")
        expected = sorted((mode, freight, freight) for mode, freight in truth[1][1])
        if rows != expected:
            raise AssertionError(f"ATTR values are not the governed metric: {rows} != {expected}")
        print("ok Tableau's ATTR statement returns the governed value under both aliases")

        plan = json.loads(support.compile_sql(con, ATTR)["plan_json"])
        lowered = [(entry["wrapper"], entry["metric"], entry["declared"], entry["equivalence"])
                   for entry in plan.get("wrapper_lowerings") or []]
        if lowered != [("MAX", "total_freight", "SUM", "ONE_ROW_PER_GROUP"),
                       ("MIN", "total_freight", "SUM", "ONE_ROW_PER_GROUP")]:
            raise AssertionError(f"lowerings not recorded in the plan: {lowered}")
        print("ok the plan records both lowerings and why they are exact")

        for wrapper in ("AVG", "COUNT"):
            refused = outcome(con, f'SELECT "ORDER_HEADER"."SHIP_MODE",'
                                   f' {wrapper}("ORDER_HEADER"."TOTAL_FREIGHT") FROM {SOURCE} GROUP BY 1')
            if refused != ("refused", "SEMANTIC_QUERY_007"):
                raise AssertionError(f"{wrapper} mismatch was not refused: {refused}")
        print("ok AVG and COUNT around a SUM metric are still SEMANTIC_QUERY_007")

        several = outcome(con, "SELECT MAX(t0.TOTAL_FREIGHT) FROM SEMANTIC_SALES.ORDER_HEADER t0"
                               " ORDER BY t0.SHIP_MODE")
        if several != ("refused", "SEMANTIC_QUERY_018"):
            raise AssertionError(f"a group of several rows was not refused: {several}")
        print("ok a MIN/MAX where a group holds several rows is SEMANTIC_QUERY_018")

        wrapped = outcome(con, "SELECT * FROM (SELECT MAX(t0.TOTAL_FREIGHT) AS M"
                               " FROM SEMANTIC_SALES.ORDER_HEADER t0) x")
        total = outcome(con, "SELECT TOTAL_FREIGHT FROM SEMANTIC_SALES.ORDER_HEADER")
        if wrapped[0] != "rows" or wrapped[1][1] != total[1][1]:
            raise AssertionError(f"wrapped MAX is not the metric: {wrapped} vs {total}")
        ratio = outcome(con, "SELECT * FROM (SELECT SUM(t0.GROSS_MARGIN_PCT)"
                             " FROM SEMANTIC_SALES.SALES t0) z")
        if ratio != ("refused", "SEMANTIC_QUERY_007"):
            raise AssertionError(f"a qualified mismatch inside a subquery slipped through: {ratio}")
        print("ok inside a subquery: MAX is the metric, a qualified SUM(ratio) is SEMANTIC_QUERY_007")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
