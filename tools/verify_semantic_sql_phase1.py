#!/usr/bin/env python3
"""Verify Phase 1 semantic SQL subset improvements against Exasol Nano.

Phase 1 covers:
  - ORDER BY ordinals (e.g. ORDER BY 1 DESC)
  - BETWEEN operator in semantic SQL WHERE clause

Run against a local Nano instance after deploying 003_create_semantic_admin_scripts.sql.

Sales model dimensions: customer_region (VARCHAR), order_month (DATE),
  order_status (VARCHAR), product_category (VARCHAR)
Sales model metrics: total_revenue, completed_revenue, gross_margin, gross_margin_pct, total_cost
Sample data: order_month in {2026-01-01, 2026-02-01, 2026-03-01}
             customer_region in {North, South, West}
             order_status in {CANCELLED, COMPLETE}
"""

from __future__ import annotations

import os
import ssl
import sys
from typing import Any


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)

    host = os.environ.get("EXASOL_HOST", "localhost")
    port = os.environ.get("EXASOL_PORT", "8563")
    return pyexasol.connect(
        dsn=f"{host}:{port}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def fetchall(con, sql: str) -> list[tuple[Any, ...]]:
    return [tuple(row) for row in con.execute(sql).fetchall()]


def compile_sql(con, sql: str) -> dict[str, Any]:
    rows = fetchall(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL({sql_string(sql)})")
    if len(rows) != 1:
        raise AssertionError(f"expected one compiler row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "original_sql": row[3],
        "generated_sql": row[4],
        "plan_json": row[5],
    }


PASSED = 0
FAILED = 0


def ok(name: str, detail: str = "") -> None:
    global PASSED
    PASSED += 1
    suffix = f": {detail}" if detail else ""
    print(f"ok  {name}{suffix}")


def fail(name: str, msg: str) -> None:
    global FAILED
    FAILED += 1
    print(f"FAIL {name}: {msg}", file=sys.stderr)


def assert_ok(name: str, result: dict[str, Any]) -> bool:
    if result["status"] != "OK":
        fail(name, f"expected OK, got {result['status']!r} {result['error_code']!r}: {result['error_message']!r}")
        return False
    if not result["generated_sql"]:
        fail(name, "OK but no generated_sql")
        return False
    ok(name, "OK")
    return True


def assert_error(name: str, result: dict[str, Any], expected_code: str) -> bool:
    if result["status"] != "ERROR":
        fail(name, f"expected ERROR/{expected_code}, got status={result['status']!r}")
        return False
    if result["error_code"] != expected_code:
        fail(name, f"expected error_code={expected_code!r}, got {result['error_code']!r}: {result['error_message']!r}")
        return False
    ok(name, f"ERROR/{expected_code}")
    return True


def assert_contains(name: str, text: str, needle: str) -> bool:
    if needle not in text:
        fail(name, f"expected {needle!r} in {text!r}")
        return False
    ok(name, f"contains {needle!r}")
    return True


def assert_not_contains(name: str, text: str, needle: str) -> bool:
    if needle in text:
        fail(name, f"did not expect {needle!r} in {text!r}")
        return False
    ok(name, f"absent {needle!r}")
    return True


def assert_equal(name: str, actual: Any, expected: Any) -> bool:
    if actual != expected:
        fail(name, f"expected {expected!r}, got {actual!r}")
        return False
    ok(name, repr(actual))
    return True


# ---------------------------------------------------------------------------
# ORDER BY ordinal tests
# ---------------------------------------------------------------------------

def test_order_by_ordinal_desc(con) -> None:
    """ORDER BY 2 DESC resolves to the metric (second SELECT column)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC"
    )
    if assert_ok("order_by_ordinal/desc", result):
        assert_contains("order_by_ordinal/desc/sort", result["generated_sql"], "ORDER BY")
        assert_contains("order_by_ordinal/desc/col", result["generated_sql"], '"total_revenue"')
        assert_contains("order_by_ordinal/desc/direction", result["generated_sql"], "DESC")


def test_order_by_ordinal_asc(con) -> None:
    """ORDER BY 1 ASC resolves to the dimension (first SELECT column)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 1 ASC"
    )
    if assert_ok("order_by_ordinal/asc", result):
        assert_contains("order_by_ordinal/asc/col", result["generated_sql"], '"customer_region"')
        assert_contains("order_by_ordinal/asc/direction", result["generated_sql"], "ASC")


def test_order_by_ordinal_implicit_direction(con) -> None:
    """ORDER BY 2 with no direction keyword is accepted (defaults to ASC)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2"
    )
    assert_ok("order_by_ordinal/implicit_direction", result)


def test_order_by_ordinal_multi_column(con) -> None:
    """ORDER BY 2 DESC, 1 ASC — both ordinals in one clause."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC, 1 ASC"
    )
    if assert_ok("order_by_ordinal/multi_column", result):
        assert_contains("order_by_ordinal/multi_column/revenue", result["generated_sql"], '"total_revenue"')
        assert_contains("order_by_ordinal/multi_column/region", result["generated_sql"], '"customer_region"')


def test_order_by_ordinal_mixed_with_name(con) -> None:
    """Mix of ordinal and field name in one ORDER BY clause."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC, customer_region ASC"
    )
    assert_ok("order_by_ordinal/mixed_name_and_ordinal", result)


def test_order_by_ordinal_three_fields(con) -> None:
    """ORDER BY ordinal on a three-field SELECT — covers ordinal 3."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue, gross_margin "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 3 DESC"
    )
    if assert_ok("order_by_ordinal/three_fields", result):
        assert_contains("order_by_ordinal/three_fields/col", result["generated_sql"], '"gross_margin"')


def test_order_by_ordinal_out_of_range(con) -> None:
    """Ordinal that exceeds the SELECT list length returns SEMANTIC_QUERY_060."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 5 DESC"
    )
    assert_error("order_by_ordinal/out_of_range", result, "SEMANTIC_QUERY_060")


def test_order_by_ordinal_zero(con) -> None:
    """Ordinal 0 is out of range (1-based) and returns SEMANTIC_QUERY_060."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 0"
    )
    assert_error("order_by_ordinal/zero", result, "SEMANTIC_QUERY_060")


def test_order_by_ordinal_with_limit(con) -> None:
    """ORDER BY ordinal combined with LIMIT."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC "
        "LIMIT 5"
    )
    if assert_ok("order_by_ordinal/with_limit", result):
        assert_contains("order_by_ordinal/with_limit/limit", result["generated_sql"], "LIMIT 5")


def test_order_by_ordinal_with_where(con) -> None:
    """ORDER BY ordinal combined with a WHERE filter."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_status = 'COMPLETE' "
        "ORDER BY 2 DESC"
    )
    if assert_ok("order_by_ordinal/with_where", result):
        assert_contains("order_by_ordinal/with_where/col", result["generated_sql"], '"total_revenue"')


def test_order_by_ordinal_wildcard_select(con) -> None:
    """ORDER BY ordinal on SELECT * — ordinals resolve against the expanded field list."""
    result = compile_sql(con,
        "SELECT * FROM SEMANTIC_SALES.SALES "
        "ORDER BY 1"
    )
    assert_ok("order_by_ordinal/wildcard_select", result)


def test_order_by_ordinal_results_match_name(con) -> None:
    """Executing ORDER BY 2 DESC produces the same top row as ORDER BY total_revenue DESC."""
    ordinal_result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC "
        "LIMIT 1"
    )
    name_result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY total_revenue DESC "
        "LIMIT 1"
    )
    if ordinal_result["status"] == "OK" and name_result["status"] == "OK":
        ordinal_rows = fetchall(con, ordinal_result["generated_sql"])
        name_rows = fetchall(con, name_result["generated_sql"])
        assert_equal("order_by_ordinal/result_matches_name", ordinal_rows, name_rows)


def test_order_by_ordinal_preprocessor(con) -> None:
    """ORDER BY ordinal works through the session preprocessor path."""
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    try:
        rows = fetchall(con,
            "SELECT customer_region, total_revenue "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region "
            "ORDER BY 2 DESC "
            "LIMIT 2"
        )
        if len(rows) == 0:
            fail("order_by_ordinal/preprocessor", "no rows returned")
        else:
            ok("order_by_ordinal/preprocessor", f"{len(rows)} rows")
            # Verify descending order: first row should have higher revenue
            if len(rows) == 2:
                rev0 = float(rows[0][1])
                rev1 = float(rows[1][1])
                if rev0 < rev1:
                    fail("order_by_ordinal/preprocessor/order", f"expected descending, got {rows}")
                else:
                    ok("order_by_ordinal/preprocessor/order", "descending confirmed")
    finally:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")


# ---------------------------------------------------------------------------
# BETWEEN in semantic SQL WHERE tests
# ---------------------------------------------------------------------------

def test_between_date_range_compiles(con) -> None:
    """BETWEEN on order_month (DATE) compiles and generates BETWEEN in physical SQL."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-03-31'"
    )
    if assert_ok("between/date_range_compiles", result):
        assert_contains("between/date_range_compiles/between_in_sql",
            result["generated_sql"], "BETWEEN")


def test_between_date_range_executes(con) -> None:
    """BETWEEN date range executes and returns expected rows."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-01-31' "
        "ORDER BY customer_region"
    )
    if assert_ok("between/date_range_executes", result):
        rows = fetchall(con, result["generated_sql"])
        # Jan 2026 has data for North (1495) and West (0?) — just check we got rows
        if len(rows) == 0:
            fail("between/date_range_executes/rows", "expected at least one row")
        else:
            ok("between/date_range_executes/rows", f"{len(rows)} regions")


def test_between_varchar_range(con) -> None:
    """BETWEEN on a VARCHAR dimension (alphabetical range)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region BETWEEN 'M' AND 'P'"
    )
    if assert_ok("between/varchar_range", result):
        assert_contains("between/varchar_range/between_in_sql",
            result["generated_sql"], "BETWEEN")
        rows = fetchall(con, result["generated_sql"])
        # 'North' is between M and P; 'South' (S > P) and 'West' (W > P) are not
        regions = [r[0] for r in rows]
        if "North" not in regions:
            fail("between/varchar_range/north_included", f"expected North in {regions}")
        else:
            ok("between/varchar_range/north_included", repr(regions))
        if "South" in regions or "West" in regions:
            fail("between/varchar_range/excluded", f"expected only North, got {regions}")
        else:
            ok("between/varchar_range/excluded", "South and West correctly excluded")


def test_between_sole_filter(con) -> None:
    """BETWEEN as the sole WHERE predicate."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-03-31'"
    )
    assert_ok("between/sole_filter", result)


def test_between_preceded_by_and(con) -> None:
    """BETWEEN with an AND conjunction before it."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_status = 'COMPLETE' AND order_month BETWEEN '2026-01-01' AND '2026-03-31'"
    )
    if assert_ok("between/preceded_by_and", result):
        assert_contains("between/preceded_by_and/status", result["generated_sql"], "COMPLETE")
        assert_contains("between/preceded_by_and/between", result["generated_sql"], "BETWEEN")


def test_between_followed_by_and(con) -> None:
    """BETWEEN with an AND conjunction after it."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-03-31' AND order_status = 'COMPLETE'"
    )
    if assert_ok("between/followed_by_and", result):
        assert_contains("between/followed_by_and/between", result["generated_sql"], "BETWEEN")
        assert_contains("between/followed_by_and/status", result["generated_sql"], "COMPLETE")


def test_between_sandwiched_by_ands(con) -> None:
    """BETWEEN with AND conjunctions on both sides."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region != 'West' "
        "AND order_month BETWEEN '2026-01-01' AND '2026-03-31' "
        "AND order_status = 'COMPLETE'"
    )
    if assert_ok("between/sandwiched", result):
        assert_contains("between/sandwiched/between", result["generated_sql"], "BETWEEN")
        assert_contains("between/sandwiched/status", result["generated_sql"], "COMPLETE")


def test_between_two_ranges(con) -> None:
    """Two independent BETWEEN predicates joined by AND."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-02-28' "
        "AND customer_region BETWEEN 'M' AND 'P'"
    )
    if assert_ok("between/two_ranges", result):
        # Should have two BETWEEN clauses in the generated SQL
        count = result["generated_sql"].count("BETWEEN")
        if count < 2:
            fail("between/two_ranges/count", f"expected 2 BETWEEN, got {count}")
        else:
            ok("between/two_ranges/count", f"{count} BETWEEN clauses")


def test_between_date_keyword_prefix(con) -> None:
    """BETWEEN with DATE 'literal' prefix syntax for both bounds."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN DATE '2026-01-01' AND DATE '2026-03-31'"
    )
    assert_ok("between/date_keyword_prefix", result)


def test_between_combined_with_ordinal_order_by(con) -> None:
    """BETWEEN filter combined with an ordinal ORDER BY (both Phase 1 features together)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-03-31' "
        "ORDER BY 2 DESC "
        "LIMIT 5"
    )
    if assert_ok("between/combined_with_ordinal", result):
        assert_contains("between/combined_with_ordinal/between", result["generated_sql"], "BETWEEN")
        assert_contains("between/combined_with_ordinal/revenue", result["generated_sql"], '"total_revenue"')


def test_between_narrow_range_equals_eq_filter(con) -> None:
    """BETWEEN '2026-01-01' AND '2026-01-01' returns same rows as = '2026-01-01'."""
    between_result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-01-01' "
        "ORDER BY customer_region"
    )
    eq_result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month = '2026-01-01' "
        "ORDER BY customer_region"
    )
    if between_result["status"] == "OK" and eq_result["status"] == "OK":
        between_rows = fetchall(con, between_result["generated_sql"])
        eq_rows = fetchall(con, eq_result["generated_sql"])
        assert_equal("between/narrow_range_equals_eq", between_rows, eq_rows)


def test_between_missing_and_error(con) -> None:
    """BETWEEN without the AND separator returns SEMANTIC_QUERY_034."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' '2026-03-31'"
    )
    assert_error("between/missing_and", result, "SEMANTIC_QUERY_034")


def test_between_non_literal_value_error(con) -> None:
    """BETWEEN with a multi-token (non-literal) value returns SEMANTIC_QUERY_035.

    'some_expr' alone is a word token and literal_from_tokens returns its value,
    so we need a multi-token expression like '2026-01-01' + 1 to force nil.
    """
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' + 1 AND '2026-03-31'"
    )
    assert_error("between/non_literal", result, "SEMANTIC_QUERY_035")


def test_between_preprocessor(con) -> None:
    """BETWEEN works through the session preprocessor path."""
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    try:
        rows = fetchall(con,
            "SELECT customer_region, total_revenue "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region "
            "WHERE order_month BETWEEN '2026-01-01' AND '2026-01-31' "
            "ORDER BY customer_region"
        )
        ok("between/preprocessor", f"{len(rows)} rows for Jan 2026")
    finally:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")


# ---------------------------------------------------------------------------
# Regression tests — existing behaviour must be unchanged
# ---------------------------------------------------------------------------

def test_regression_where_eq(con) -> None:
    """Plain = filter continues to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_status = 'COMPLETE'"
    )
    assert_ok("regression/where_eq", result)


def test_regression_where_neq(con) -> None:
    """!= filter continues to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region != 'South'"
    )
    assert_ok("regression/where_neq", result)


def test_regression_where_like(con) -> None:
    """LIKE filter continues to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_status LIKE 'COMP%'"
    )
    assert_ok("regression/where_like", result)


def test_regression_where_in(con) -> None:
    """IN filter continues to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region IN ('North', 'West')"
    )
    assert_ok("regression/where_in", result)


def test_regression_where_multiple_and(con) -> None:
    """Multiple AND predicates continue to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_status = 'COMPLETE' AND customer_region != 'South'"
    )
    assert_ok("regression/where_multiple_and", result)


def test_regression_group_by_ordinal(con) -> None:
    """GROUP BY ordinals continue to work (pre-existing feature)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY 1"
    )
    assert_ok("regression/group_by_ordinal", result)


def test_regression_group_by_ordinal_matches_name(con) -> None:
    """GROUP BY 1 produces same rows as GROUP BY customer_region."""
    ordinal_result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY 1 "
        "ORDER BY customer_region"
    )
    name_result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY customer_region"
    )
    if ordinal_result["status"] == "OK" and name_result["status"] == "OK":
        ordinal_rows = fetchall(con, ordinal_result["generated_sql"])
        name_rows = fetchall(con, name_result["generated_sql"])
        assert_equal("regression/group_by_ordinal_matches_name", ordinal_rows, name_rows)


def test_regression_order_by_field_name(con) -> None:
    """ORDER BY field name continues to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY total_revenue DESC"
    )
    assert_ok("regression/order_by_field_name", result)


def test_regression_order_by_alias(con) -> None:
    """ORDER BY column alias continues to work."""
    result = compile_sql(con,
        "SELECT customer_region AS region, total_revenue AS rev "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY rev DESC"
    )
    assert_ok("regression/order_by_alias", result)


def test_regression_limit(con) -> None:
    """LIMIT continues to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY total_revenue DESC "
        "LIMIT 3"
    )
    if assert_ok("regression/limit", result):
        assert_contains("regression/limit/in_sql", result["generated_sql"], "LIMIT 3")


def test_regression_wildcard_select(con) -> None:
    """SELECT * continues to work."""
    result = compile_sql(con, "SELECT * FROM SEMANTIC_SALES.SALES")
    assert_ok("regression/wildcard_select", result)


def test_regression_unknown_field_error(con) -> None:
    """Unknown field name still returns SEMANTIC_QUERY_020."""
    result = compile_sql(con,
        "SELECT nonexistent_field "
        "FROM SEMANTIC_SALES.SALES"
    )
    assert_error("regression/unknown_field", result, "SEMANTIC_QUERY_020")


def test_regression_compile_request_json_between(con) -> None:
    """COMPILE_REQUEST_JSON BETWEEN filter still works (pre-existing, must not regress)."""
    import json
    payload = json.dumps({
        "model": "sales",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [{"field": "order_month", "op": "BETWEEN", "value": ["2026-01-01", "2026-03-31"]}],
        "client": "verify_phase1",
    })
    rows = fetchall(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})")
    row = rows[0]
    if row[0] != "OK":
        fail("regression/compile_request_json_between", f"expected OK, got {row[0]} {row[1]}: {row[2]}")
    else:
        ok("regression/compile_request_json_between", "OK")
        # COMPILE_REQUEST_JSON returns the same 9-column layout as COMPILE_SQL:
        # GENERATED_SQL is at index 4 (index 3 is ORIGINAL_SQL, NULL for JSON requests).
        assert_contains("regression/compile_request_json_between/sql", row[4], "BETWEEN")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    con = connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")

        print("=== ORDER BY ordinal ===")
        test_order_by_ordinal_desc(con)
        test_order_by_ordinal_asc(con)
        test_order_by_ordinal_implicit_direction(con)
        test_order_by_ordinal_multi_column(con)
        test_order_by_ordinal_mixed_with_name(con)
        test_order_by_ordinal_three_fields(con)
        test_order_by_ordinal_out_of_range(con)
        test_order_by_ordinal_zero(con)
        test_order_by_ordinal_with_limit(con)
        test_order_by_ordinal_with_where(con)
        test_order_by_ordinal_wildcard_select(con)
        test_order_by_ordinal_results_match_name(con)
        test_order_by_ordinal_preprocessor(con)

        print()
        print("=== BETWEEN in WHERE ===")
        test_between_date_range_compiles(con)
        test_between_date_range_executes(con)
        test_between_varchar_range(con)
        test_between_sole_filter(con)
        test_between_preceded_by_and(con)
        test_between_followed_by_and(con)
        test_between_sandwiched_by_ands(con)
        test_between_two_ranges(con)
        test_between_date_keyword_prefix(con)
        test_between_combined_with_ordinal_order_by(con)
        test_between_narrow_range_equals_eq_filter(con)
        test_between_missing_and_error(con)
        test_between_non_literal_value_error(con)
        test_between_preprocessor(con)

        print()
        print("=== Regression ===")
        test_regression_where_eq(con)
        test_regression_where_neq(con)
        test_regression_where_like(con)
        test_regression_where_in(con)
        test_regression_where_multiple_and(con)
        test_regression_group_by_ordinal(con)
        test_regression_group_by_ordinal_matches_name(con)
        test_regression_order_by_field_name(con)
        test_regression_order_by_alias(con)
        test_regression_limit(con)
        test_regression_wildcard_select(con)
        test_regression_unknown_field_error(con)
        test_regression_compile_request_json_between(con)

        print()
        outcome = "PASSED" if FAILED == 0 else "FAILED"
        print(f"{outcome}: {PASSED} passed, {FAILED} failed")
        return 0 if FAILED == 0 else 1
    finally:
        try:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        finally:
            con.close()


if __name__ == "__main__":
    raise SystemExit(main())
