#!/usr/bin/env python3
"""Verify Phase 1 semantic SQL subset improvements against Exasol Nano.

Phase 1 covers:
  - ORDER BY ordinals (e.g. ORDER BY 1 DESC)
  - BETWEEN operator in semantic SQL WHERE clause

Run against a local Nano instance after deploying 003_create_semantic_admin_scripts.sql.
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


def assert_status(name: str, result: dict[str, Any], expected: str) -> bool:
    if result["status"] != expected:
        fail(name, f"expected status={expected!r}, got status={result['status']!r} error={result['error_code']!r} {result['error_message']!r}")
        return False
    ok(name, expected)
    return True


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

def test_order_by_ordinal_single(con) -> None:
    """ORDER BY 1 DESC on a single-metric query."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC"
    )
    if assert_ok("order_by_ordinal/single_desc", result):
        assert_contains("order_by_ordinal/single_desc/sort",
            result["generated_sql"], 'ORDER BY')
        assert_contains("order_by_ordinal/single_desc/revenue_col",
            result["generated_sql"], '"total_revenue"')


def test_order_by_ordinal_asc(con) -> None:
    """ORDER BY 1 ASC on dimension."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 1 ASC"
    )
    if assert_ok("order_by_ordinal/asc", result):
        assert_contains("order_by_ordinal/asc/sort", result["generated_sql"], 'ORDER BY')
        assert_contains("order_by_ordinal/asc/region_col", result["generated_sql"], '"customer_region"')


def test_order_by_ordinal_implicit_asc(con) -> None:
    """ORDER BY 2 with no direction keyword defaults to ASC."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2"
    )
    assert_ok("order_by_ordinal/implicit_asc", result)


def test_order_by_ordinal_multi(con) -> None:
    """ORDER BY 2 DESC, 1 ASC on two selected fields."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC, 1 ASC"
    )
    assert_ok("order_by_ordinal/multi", result)


def test_order_by_ordinal_mixed(con) -> None:
    """ORDER BY mixes ordinal and field name."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC, customer_region ASC"
    )
    assert_ok("order_by_ordinal/mixed_name_and_ordinal", result)


def test_order_by_ordinal_out_of_range(con) -> None:
    """ORDER BY ordinal that exceeds the SELECT list is an error."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 5 DESC"
    )
    assert_error("order_by_ordinal/out_of_range", result, "SEMANTIC_QUERY_060")


def test_order_by_ordinal_zero(con) -> None:
    """ORDER BY 0 is out of range (1-based ordinals)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 0"
    )
    assert_error("order_by_ordinal/zero", result, "SEMANTIC_QUERY_060")


def test_order_by_name_still_works(con) -> None:
    """Existing field-name ORDER BY continues to work after the ordinal change."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY total_revenue DESC"
    )
    assert_ok("order_by_ordinal/name_regression", result)


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
        assert_contains("order_by_ordinal/with_limit/limit",
            result["generated_sql"], "LIMIT 5")


def test_order_by_ordinal_results(con) -> None:
    """ORDER BY 2 DESC produces correct result order (same as ORDER BY total_revenue DESC)."""
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


# ---------------------------------------------------------------------------
# BETWEEN in semantic SQL WHERE tests
# ---------------------------------------------------------------------------

def test_between_date_range(con) -> None:
    """BETWEEN filter on a date dimension."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-03-31'"
    )
    if assert_ok("between/date_range", result):
        assert_contains("between/date_range/sql",
            result["generated_sql"], "BETWEEN")


def test_between_numeric(con) -> None:
    """BETWEEN filter on a numeric dimension (order_year)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_year BETWEEN 2024 AND 2026"
    )
    assert_ok("between/numeric", result)


def test_between_with_preceding_and(con) -> None:
    """BETWEEN preceded by another AND conjunction."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_status = 'COMPLETE' AND order_year BETWEEN 2024 AND 2026"
    )
    if assert_ok("between/preceded_by_and", result):
        assert_contains("between/preceded_by_and/status",
            result["generated_sql"], "COMPLETE")
        assert_contains("between/preceded_by_and/between",
            result["generated_sql"], "BETWEEN")


def test_between_with_following_and(con) -> None:
    """BETWEEN followed by another AND conjunction."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_year BETWEEN 2024 AND 2026 AND order_status = 'COMPLETE'"
    )
    if assert_ok("between/followed_by_and", result):
        assert_contains("between/followed_by_and/between",
            result["generated_sql"], "BETWEEN")
        assert_contains("between/followed_by_and/status",
            result["generated_sql"], "COMPLETE")


def test_between_sandwiched_by_ands(con) -> None:
    """BETWEEN with AND conjunctions on both sides."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region != 'South' AND order_year BETWEEN 2024 AND 2026 AND order_status = 'COMPLETE'"
    )
    if assert_ok("between/sandwiched", result):
        assert_contains("between/sandwiched/between",
            result["generated_sql"], "BETWEEN")
        assert_contains("between/sandwiched/status",
            result["generated_sql"], "COMPLETE")


def test_between_only_filter(con) -> None:
    """BETWEEN as the sole WHERE filter."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_year BETWEEN 2025 AND 2026"
    )
    assert_ok("between/sole_filter", result)


def test_between_with_ordinal_order_by(con) -> None:
    """BETWEEN filter combined with an ordinal ORDER BY (both Phase 1 features together)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_year BETWEEN 2025 AND 2026 "
        "ORDER BY 2 DESC "
        "LIMIT 5"
    )
    if assert_ok("between/combined_with_ordinal_order_by", result):
        assert_contains("between/combined_with_ordinal_order_by/between",
            result["generated_sql"], "BETWEEN")


def test_between_two_ranges(con) -> None:
    """Two independent BETWEEN predicates joined by AND."""
    result = compile_sql(con,
        "SELECT total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "WHERE order_year BETWEEN 2024 AND 2026 AND order_month BETWEEN '2025-01-01' AND '2025-12-31'"
    )
    if assert_ok("between/two_ranges", result):
        assert_contains("between/two_ranges/sql",
            result["generated_sql"], "BETWEEN")


def test_between_missing_and_error(con) -> None:
    """BETWEEN without the AND separator returns a clear error."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_year BETWEEN 2024 2026"
    )
    assert_error("between/missing_and", result, "SEMANTIC_QUERY_034")


def test_between_non_literal_error(con) -> None:
    """BETWEEN with a non-literal value returns a clear error."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_year BETWEEN some_expr AND 2026"
    )
    assert_error("between/non_literal", result, "SEMANTIC_QUERY_035")


def test_between_results_match_eq_filters(con) -> None:
    """BETWEEN 2026 AND 2026 returns same rows as = 2026 equality filter."""
    between_result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_year BETWEEN 2026 AND 2026 "
        "ORDER BY customer_region"
    )
    eq_result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_year = 2026 "
        "ORDER BY customer_region"
    )
    if between_result["status"] == "OK" and eq_result["status"] == "OK":
        between_rows = fetchall(con, between_result["generated_sql"])
        eq_rows = fetchall(con, eq_result["generated_sql"])
        assert_equal("between/results_match_eq", between_rows, eq_rows)


# ---------------------------------------------------------------------------
# Regression tests — existing behaviours must be unchanged
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


def test_regression_where_in(con) -> None:
    """IN filter continues to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region IN ('North', 'West')"
    )
    assert_ok("regression/where_in", result)


def test_regression_where_and(con) -> None:
    """Multiple AND predicates continue to work."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_status = 'COMPLETE' AND customer_region != 'South'"
    )
    assert_ok("regression/where_and", result)


def test_regression_group_by_ordinal(con) -> None:
    """GROUP BY ordinals continue to work (pre-existing feature)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY 1"
    )
    assert_ok("regression/group_by_ordinal", result)


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
        assert_contains("regression/limit/sql", result["generated_sql"], "LIMIT 3")


def test_regression_wildcard_select(con) -> None:
    """SELECT * continues to work."""
    result = compile_sql(con, "SELECT * FROM SEMANTIC_SALES.SALES")
    assert_ok("regression/wildcard_select", result)


def test_regression_bad_field_still_errors(con) -> None:
    """Unknown field name still returns an error."""
    result = compile_sql(con,
        "SELECT nonexistent_field "
        "FROM SEMANTIC_SALES.SALES"
    )
    assert_error("regression/unknown_field", result, "SEMANTIC_QUERY_020")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    con = connect()
    try:
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")

        print("=== ORDER BY ordinal ===")
        test_order_by_ordinal_single(con)
        test_order_by_ordinal_asc(con)
        test_order_by_ordinal_implicit_asc(con)
        test_order_by_ordinal_multi(con)
        test_order_by_ordinal_mixed(con)
        test_order_by_ordinal_out_of_range(con)
        test_order_by_ordinal_zero(con)
        test_order_by_name_still_works(con)
        test_order_by_ordinal_with_limit(con)
        test_order_by_ordinal_results(con)

        print()
        print("=== BETWEEN in WHERE ===")
        test_between_date_range(con)
        test_between_numeric(con)
        test_between_with_preceding_and(con)
        test_between_with_following_and(con)
        test_between_sandwiched_by_ands(con)
        test_between_only_filter(con)
        test_between_with_ordinal_order_by(con)
        test_between_two_ranges(con)
        test_between_missing_and_error(con)
        test_between_non_literal_error(con)
        test_between_results_match_eq_filters(con)

        print()
        print("=== Regression ===")
        test_regression_where_eq(con)
        test_regression_where_in(con)
        test_regression_where_and(con)
        test_regression_group_by_ordinal(con)
        test_regression_order_by_alias(con)
        test_regression_limit(con)
        test_regression_wildcard_select(con)
        test_regression_bad_field_still_errors(con)

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
