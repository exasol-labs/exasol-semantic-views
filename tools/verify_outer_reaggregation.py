#!/usr/bin/env python3
"""Verify that an outer SUM/AVG over a metric that does not add up is refused.

Aggregating a semantic object in an outer block is the supported form, and for
an additive metric it is exact. For one that does not add up across groups it
is not the metric at any grain: AVG over per-bucket averages answered 71.59
where the truth was 48.52 (BUG-26), and on the sales model SUM over per-region
margin ratios answers a 120 % margin -- both with STATUS = OK. This asserts
against the live sales model that:

- those shapes are refused with SEMANTIC_QUERY_016, including when the grain
  dimension is only filtered on inside the subquery;
- every exact shape still compiles and returns the metric's own value;
- SET_MODEL_DERIVED_COMPOSITION opts out, like SEMANTIC_QUERY_015.
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
PER_REGION = f"(SELECT customer_region, gross_margin_pct FROM {OBJECT}) t"

REFUSED = {
    "AVG of a ratio": f"SELECT AVG(t.gross_margin_pct) FROM {PER_REGION}",
    "SUM of a ratio": f"SELECT SUM(t.gross_margin_pct) FROM {PER_REGION}",
    "through a CTE": (f"WITH x AS (SELECT customer_region, gross_margin_pct FROM {OBJECT}) "
                      "SELECT AVG(x.gross_margin_pct) FROM x"),
    "inside an expression": f"SELECT ROUND(AVG(t.gross_margin_pct), 4) FROM {PER_REGION}",
    "grain only filtered on": (
        f"SELECT AVG(t.gross_margin_pct) FROM (SELECT gross_margin_pct FROM {OBJECT} "
        "WHERE customer_region IN ('North', 'West')) t"),
}


def compile_and_run(con: Any, sql: str) -> tuple[dict[str, Any], list[tuple[Any, ...]]]:
    result = support.compile_sql(con, sql)
    if result.get("status") != "OK":
        return result, []
    return result, [tuple(row) for row in con.execute(result["generated_sql"]).fetchall()]


def value(con: Any, sql: str) -> list[tuple[Any, ...]]:
    result, rows = compile_and_run(con, sql)
    if result.get("status") != "OK":
        raise AssertionError(f"expected {sql!r} to compile: {result}")
    return rows


def close(left: list[tuple[Any, ...]], right: list[tuple[Any, ...]]) -> bool:
    def norm(rows):
        return sorted(tuple(round(float(v), 9) if isinstance(v, (int, float, str))
                            and str(v).replace(".", "", 1).replace("-", "", 1).isdigit()
                            else v for v in row) for row in rows)
    return norm(left) == norm(right)


def main() -> int:
    con = support.connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('sales', 'FALSE')")
        for label, sql in REFUSED.items():
            result, _ = compile_and_run(con, sql)
            if result.get("error_code") != "SEMANTIC_QUERY_016":
                raise AssertionError(f"{label} was not refused with SEMANTIC_QUERY_016: {result}")
        message = compile_and_run(con, REFUSED["AVG of a ratio"])[0]["error_message"]
        for fragment in ("AVG(t.gross_margin_pct) re-aggregates gross_margin_pct",
                         "grouped by customer_region", "MIN and MAX"):
            if fragment not in message:
                raise AssertionError(f"message lacks {fragment!r}: {message}")
        print(f"ok refused: {', '.join(REFUSED)}")

        truth = value(con, f"SELECT gross_margin_pct FROM {OBJECT}")
        revenue = value(con, f"SELECT total_revenue FROM {OBJECT}")
        margin = value(con, f"SELECT gross_margin FROM {OBJECT}")
        by_region = value(con, f"SELECT customer_region, gross_margin_pct FROM {OBJECT}")
        exact = [
            ("SUM of an additive metric", revenue,
             f"SELECT SUM(t.total_revenue) FROM (SELECT customer_region, total_revenue FROM {OBJECT}) t"),
            ("SUM of a linear derived metric", margin,
             f"SELECT SUM(t.gross_margin) FROM (SELECT customer_region, gross_margin FROM {OBJECT}) t"),
            ("no dimensions in the subquery", truth,
             f"SELECT AVG(t.gross_margin_pct) FROM (SELECT gross_margin_pct FROM {OBJECT}) t"),
            ("outer grouped by the whole grain", by_region,
             f"SELECT customer_region, AVG(t.gross_margin_pct) FROM {PER_REGION} GROUP BY customer_region"),
            ("grain grouped by ordinal", by_region,
             f"SELECT t.customer_region, SUM(t.gross_margin_pct) FROM {PER_REGION} GROUP BY 1"),
        ]
        for label, expected, sql in exact:
            if not close(value(con, sql), expected):
                raise AssertionError(f"{label}: {value(con, sql)} != {expected}")
        highest = max(float(row[1]) for row in by_region)
        if float(value(con, f"SELECT MAX(t.gross_margin_pct) FROM {PER_REGION}")[0][0]) != highest:
            raise AssertionError("MAX over per-group values is not the highest group value")
        print("ok accepted and exact: " + ", ".join(label for label, _, _ in exact) + ", MAX")

        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('sales', 'TRUE')")
        result, _ = compile_and_run(con, REFUSED["AVG of a ratio"])
        if result.get("status") != "OK":
            raise AssertionError(f"SET_MODEL_DERIVED_COMPOSITION did not opt out: {result}")
        print("ok SET_MODEL_DERIVED_COMPOSITION: ordinary-SQL semantics compile")
        return 0
    finally:
        try:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('sales', 'FALSE')")
        finally:
            con.close()


if __name__ == "__main__":
    raise SystemExit(main())
