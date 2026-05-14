#!/usr/bin/env python3
"""Verify Phase 2 semantic SQL subset improvements against Exasol Nano.

Phase 2 covers:
  - HAVING clause (HAVING metric > N)
  - Metric predicates in WHERE auto-routed to HAVING (WHERE metric > N)
  - COMPILE_REQUEST_JSON with explicit 'having' array
  - Materialization bypass when having predicates are present

Sales model dimensions: customer_region (VARCHAR), order_month (DATE),
  order_status (VARCHAR), product_category (VARCHAR)
Sales model metrics: total_revenue, completed_revenue, gross_margin,
  gross_margin_pct, total_cost
Sample data totals by customer_region:
  North: total_revenue=3635, completed_revenue=3635, gross_margin_pct≈0.318
  South: total_revenue=135,  completed_revenue=135,  gross_margin_pct≈0.556
  West:  total_revenue=1500, completed_revenue=0,    gross_margin_pct≈0.333
"""

from __future__ import annotations

import json
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


def compile_request_json(con, request: dict) -> dict[str, Any]:
    req_str = sql_string(json.dumps(request))
    rows = fetchall(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({req_str})")
    if len(rows) != 1:
        raise AssertionError(f"expected one row, got {len(rows)}")
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "generated_sql": row[3],
        "plan_json": row[4],
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
# HAVING clause (direct)
# ---------------------------------------------------------------------------

def test_having_basic_compiles(con) -> None:
    """HAVING total_revenue > 0 compiles and produces HAVING in SQL."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING total_revenue > 0"
    )
    if assert_ok("having/basic/compiles", result):
        sql = result["generated_sql"]
        assert_contains("having/basic/having_keyword", sql, "HAVING")
        assert_not_contains("having/basic/not_in_where", sql, "WHERE")


def test_having_basic_executes(con) -> None:
    """HAVING total_revenue > 1000 filters out South (135)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING total_revenue > 1000"
    )
    if not assert_ok("having/executes/compiles", result):
        return
    rows = fetchall(con, result["generated_sql"])
    regions = sorted(r[0] for r in rows)
    assert_equal("having/executes/row_count", len(rows), 2)
    assert_equal("having/executes/regions", regions, ["North", "West"])


def test_having_excludes_all(con) -> None:
    """HAVING total_revenue > 99999 returns zero rows."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING total_revenue > 99999"
    )
    if not assert_ok("having/excludes_all/compiles", result):
        return
    rows = fetchall(con, result["generated_sql"])
    assert_equal("having/excludes_all/rows", len(rows), 0)


def test_having_multiple_predicates(con) -> None:
    """HAVING p1 AND p2: both predicates in HAVING clause."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue, gross_margin_pct "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING total_revenue > 100 AND gross_margin_pct > 0.4"
    )
    if not assert_ok("having/multiple/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("having/multiple/having", sql, "HAVING")
    rows = fetchall(con, sql)
    # North: rev=3635, gm_pct≈0.318 → fails gm_pct > 0.4
    # South: rev=135,  gm_pct≈0.556 → passes both
    # West:  rev=1500, gm_pct≈0.333 → fails gm_pct > 0.4
    regions = [r[0] for r in rows]
    assert_equal("having/multiple/only_south", regions, ["South"])


def test_having_between(con) -> None:
    """HAVING total_revenue BETWEEN 100 AND 1600 includes South and West."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING total_revenue BETWEEN 100 AND 1600"
    )
    if not assert_ok("having/between/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("having/between/having_keyword", sql, "HAVING")
    assert_contains("having/between/between_keyword", sql, "BETWEEN")
    rows = fetchall(con, sql)
    regions = sorted(r[0] for r in rows)
    assert_equal("having/between/regions", regions, ["South", "West"])


def test_having_with_order_by(con) -> None:
    """HAVING + ORDER BY produces correct clause order in SQL."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING total_revenue > 1000 "
        "ORDER BY total_revenue DESC"
    )
    if not assert_ok("having/with_order_by/compiles", result):
        return
    sql = result["generated_sql"]
    having_pos = sql.find("HAVING")
    order_pos = sql.find("ORDER BY")
    assert_equal("having/with_order_by/having_before_order", having_pos < order_pos, True)
    rows = fetchall(con, sql)
    revenues = [r[1] for r in rows]
    assert_equal("having/with_order_by/desc_order", revenues, ["3635", "1500"])


def test_having_with_limit(con) -> None:
    """HAVING + LIMIT: only rows passing HAVING are counted for LIMIT."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING total_revenue > 100 "
        "ORDER BY total_revenue DESC "
        "LIMIT 1"
    )
    if not assert_ok("having/with_limit/compiles", result):
        return
    rows = fetchall(con, result["generated_sql"])
    assert_equal("having/with_limit/rows", len(rows), 1)
    assert_equal("having/with_limit/top_region", rows[0][0], "North")


def test_having_no_group_by(con) -> None:
    """HAVING on a metrics-only query (no dimensions, no GROUP BY)."""
    result = compile_sql(con,
        "SELECT total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "HAVING total_revenue > 0"
    )
    if not assert_ok("having/no_group_by/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("having/no_group_by/having", sql, "HAVING")
    rows = fetchall(con, sql)
    assert_equal("having/no_group_by/one_row", len(rows), 1)


def test_having_filtered_metric(con) -> None:
    """HAVING on a filtered/conditional metric: completed_revenue > 0 excludes West."""
    result = compile_sql(con,
        "SELECT customer_region, completed_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING completed_revenue > 0"
    )
    if not assert_ok("having/filtered_metric/compiles", result):
        return
    rows = fetchall(con, result["generated_sql"])
    regions = sorted(r[0] for r in rows)
    assert_equal("having/filtered_metric/regions", regions, ["North", "South"])


def test_having_dimension_error(con) -> None:
    """HAVING on a dimension field returns SEMANTIC_QUERY_040."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING customer_region = 'North'"
    )
    assert_error("having/dimension_error", result, "SEMANTIC_QUERY_040")


def test_having_unknown_field_error(con) -> None:
    """HAVING on an unknown field returns an appropriate error."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING no_such_metric > 0"
    )
    if result["status"] != "ERROR":
        fail("having/unknown_field/status", f"expected ERROR, got {result['status']!r}")
    else:
        ok("having/unknown_field", f"ERROR/{result['error_code']}")


# ---------------------------------------------------------------------------
# WHERE metric auto-routing
# ---------------------------------------------------------------------------

def test_where_metric_auto_routed(con) -> None:
    """WHERE total_revenue > 0 is silently routed to HAVING in the generated SQL."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE total_revenue > 0"
    )
    if not assert_ok("auto_route/basic/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("auto_route/basic/having", sql, "HAVING")
    # The metric expression must not appear in WHERE
    where_pos = sql.find("WHERE")
    having_pos = sql.find("HAVING")
    if where_pos != -1:
        fail("auto_route/basic/no_where", f"metric predicate should not be in WHERE, sql: {sql!r}")
    else:
        ok("auto_route/basic/no_where", "WHERE absent (metric in HAVING)")
    _ = having_pos


def test_where_metric_auto_routed_filters_correctly(con) -> None:
    """WHERE total_revenue > 1000 auto-routes and produces the same result as HAVING."""
    result_where = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE total_revenue > 1000 "
        "ORDER BY customer_region"
    )
    result_having = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "HAVING total_revenue > 1000 "
        "ORDER BY customer_region"
    )
    if not (assert_ok("auto_route/equiv/where_ok", result_where) and
            assert_ok("auto_route/equiv/having_ok", result_having)):
        return
    rows_where = fetchall(con, result_where["generated_sql"])
    rows_having = fetchall(con, result_having["generated_sql"])
    assert_equal("auto_route/equiv/same_rows", rows_where, rows_having)


def test_where_mixed_dimension_and_metric(con) -> None:
    """WHERE with both dimension and metric predicates routes each correctly."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region != 'South' AND total_revenue > 0"
    )
    if not assert_ok("auto_route/mixed/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("auto_route/mixed/where", sql, "WHERE")
    assert_contains("auto_route/mixed/having", sql, "HAVING")
    rows = fetchall(con, sql)
    regions = sorted(r[0] for r in rows)
    assert_equal("auto_route/mixed/regions", regions, ["North", "West"])


def test_where_metric_only_predicate(con) -> None:
    """WHERE total_revenue > 2000 with no other filter: only North passes."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE total_revenue > 2000"
    )
    if not assert_ok("auto_route/only_metric/compiles", result):
        return
    rows = fetchall(con, result["generated_sql"])
    regions = [r[0] for r in rows]
    assert_equal("auto_route/only_metric/north_only", regions, ["North"])


def test_where_metric_between_auto_routed(con) -> None:
    """WHERE total_revenue BETWEEN 100 AND 1600 auto-routes to HAVING."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE total_revenue BETWEEN 100 AND 1600"
    )
    if not assert_ok("auto_route/between/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("auto_route/between/having", sql, "HAVING")
    assert_contains("auto_route/between/between", sql, "BETWEEN")
    rows = fetchall(con, sql)
    regions = sorted(r[0] for r in rows)
    assert_equal("auto_route/between/regions", regions, ["South", "West"])


def test_where_metric_preprocessor(con) -> None:
    """Session preprocessor correctly auto-routes WHERE metric > N to HAVING."""
    fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    try:
        rows = fetchall(con,
            "SELECT customer_region, total_revenue "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region "
            "WHERE total_revenue > 1000 "
            "ORDER BY customer_region"
        )
        regions = [r[0] for r in rows]
        assert_equal("auto_route/preprocessor/regions", regions, ["North", "West"])
    finally:
        fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")


# ---------------------------------------------------------------------------
# HAVING with WHERE (combined)
# ---------------------------------------------------------------------------

def test_having_combined_where_and_having(con) -> None:
    """Explicit WHERE (dimension) + HAVING (metric) — both clauses in output SQL."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region != 'South' "
        "HAVING total_revenue > 1000"
    )
    if not assert_ok("combined/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("combined/where", sql, "WHERE")
    assert_contains("combined/having", sql, "HAVING")
    rows = fetchall(con, sql)
    regions = [r[0] for r in rows]
    assert_equal("combined/north_west", sorted(regions), ["North", "West"])


def test_having_combined_with_order_and_limit(con) -> None:
    """WHERE + HAVING + ORDER BY + LIMIT all together."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_status = 'COMPLETE' "
        "HAVING total_revenue > 0 "
        "ORDER BY total_revenue DESC "
        "LIMIT 2"
    )
    if not assert_ok("combined/full_clauses/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("combined/full_clauses/where", sql, "WHERE")
    assert_contains("combined/full_clauses/having", sql, "HAVING")
    assert_contains("combined/full_clauses/order", sql, "ORDER BY")
    assert_contains("combined/full_clauses/limit", sql, "LIMIT 2")
    # Clause order: WHERE < GROUP BY < HAVING < ORDER BY < LIMIT
    where_pos = sql.find("WHERE")
    group_pos = sql.find("GROUP BY")
    having_pos = sql.find("HAVING")
    order_pos = sql.find("ORDER BY")
    limit_pos = sql.find("LIMIT")
    if not (where_pos < group_pos < having_pos < order_pos < limit_pos):
        fail("combined/full_clauses/order", f"clause ordering wrong: WHERE={where_pos} GROUP={group_pos} HAVING={having_pos} ORDER={order_pos} LIMIT={limit_pos}")
    else:
        ok("combined/full_clauses/clause_order", "WHERE < GROUP BY < HAVING < ORDER BY < LIMIT")


# ---------------------------------------------------------------------------
# COMPILE_REQUEST_JSON with explicit 'having'
# ---------------------------------------------------------------------------

def test_compile_request_json_having(con) -> None:
    """COMPILE_REQUEST_JSON with explicit having array produces HAVING SQL."""
    result = compile_request_json(con, {
        "model": "SALES",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [],
        "having": [{"field": "total_revenue", "op": ">", "value": 1000}],
        "order_by": [{"field": "customer_region", "direction": "ASC"}],
    })
    if not assert_ok("request_json/having/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("request_json/having/having_keyword", sql, "HAVING")
    rows = fetchall(con, sql)
    regions = sorted(r[0] for r in rows)
    assert_equal("request_json/having/regions", regions, ["North", "West"])


def test_compile_request_json_having_between(con) -> None:
    """COMPILE_REQUEST_JSON having with BETWEEN operator."""
    result = compile_request_json(con, {
        "model": "SALES",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [],
        "having": [{"field": "total_revenue", "op": "BETWEEN", "value": [100, 1600]}],
        "order_by": [],
    })
    if not assert_ok("request_json/having_between/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("request_json/having_between/having", sql, "HAVING")
    assert_contains("request_json/having_between/between", sql, "BETWEEN")
    rows = fetchall(con, sql)
    regions = sorted(r[0] for r in rows)
    assert_equal("request_json/having_between/regions", regions, ["South", "West"])


def test_compile_request_json_having_with_filters(con) -> None:
    """COMPILE_REQUEST_JSON: dimension filter + metric having together."""
    result = compile_request_json(con, {
        "model": "SALES",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [{"field": "customer_region", "op": "!=", "value": "South"}],
        "having": [{"field": "total_revenue", "op": ">", "value": 1000}],
        "order_by": [],
    })
    if not assert_ok("request_json/having_with_filter/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("request_json/having_with_filter/where", sql, "WHERE")
    assert_contains("request_json/having_with_filter/having", sql, "HAVING")
    rows = fetchall(con, sql)
    regions = sorted(r[0] for r in rows)
    assert_equal("request_json/having_with_filter/regions", regions, ["North", "West"])


def test_compile_request_json_having_dimension_error(con) -> None:
    """COMPILE_REQUEST_JSON: dimension in having array returns error."""
    result = compile_request_json(con, {
        "model": "SALES",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [],
        "having": [{"field": "customer_region", "op": "=", "value": "North"}],
        "order_by": [],
    })
    if result["status"] != "ERROR":
        fail("request_json/having_dim_error", f"expected ERROR, got {result['status']!r}")
    else:
        ok("request_json/having_dim_error", f"ERROR/{result['error_code']}")


def test_compile_request_json_no_having(con) -> None:
    """COMPILE_REQUEST_JSON without having key still works (backward compat)."""
    result = compile_request_json(con, {
        "model": "SALES",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [],
        "order_by": [],
    })
    assert_ok("request_json/no_having/compiles", result)


# ---------------------------------------------------------------------------
# Materialization bypass
# ---------------------------------------------------------------------------

def test_materialization_used_without_having(con) -> None:
    """Without HAVING, a no-dimension query uses materialization."""
    result = compile_sql(con, "SELECT total_revenue FROM SEMANTIC_SALES.SALES")
    if not assert_ok("mat_bypass/baseline/compiles", result):
        return
    plan_str = result["plan_json"] or ""
    if '"selected_materialization": null' in plan_str or '"selected_materialization":null' in plan_str:
        fail("mat_bypass/baseline/mat_selected", "expected materialization to be selected, got null")
    else:
        ok("mat_bypass/baseline/mat_selected", "materialization selected")


def test_materialization_bypassed_with_having(con) -> None:
    """With HAVING, materialization is skipped and full physical SQL is used."""
    result = compile_sql(con,
        "SELECT total_revenue FROM SEMANTIC_SALES.SALES HAVING total_revenue > 0"
    )
    if not assert_ok("mat_bypass/having/compiles", result):
        return
    sql = result["generated_sql"]
    plan_str = result["plan_json"] or ""
    assert_contains("mat_bypass/having/having_in_sql", sql, "HAVING")
    # Materialization SQL references 'MART' schema; full physical SQL uses table aliases
    if "MART" in sql and "SALES_REVENUE_BY_REGION" in sql:
        fail("mat_bypass/having/no_mat_sql", f"materialized SQL was used despite HAVING: {sql!r}")
    else:
        ok("mat_bypass/having/no_mat_sql", "full physical SQL used (not materialized)")


def test_materialization_bypassed_with_having_compile_request_json(con) -> None:
    """COMPILE_REQUEST_JSON: having bypass verified via plan_json."""
    result = compile_request_json(con, {
        "model": "SALES",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": [],
        "filters": [],
        "having": [{"field": "total_revenue", "op": ">", "value": 0}],
        "order_by": [],
    })
    if not assert_ok("mat_bypass/request_json/compiles", result):
        return
    plan = json.loads(result["plan_json"]) if result["plan_json"] else {}
    selected = plan.get("selected_materialization")
    if selected is not None and selected != "null":
        fail("mat_bypass/request_json/no_mat", f"expected materialization null, got {selected!r}")
    else:
        ok("mat_bypass/request_json/no_mat", "selected_materialization is null")
    sql = result["generated_sql"]
    assert_contains("mat_bypass/request_json/having_in_sql", sql, "HAVING")


# ---------------------------------------------------------------------------
# HAVING preprocessor
# ---------------------------------------------------------------------------

def test_having_preprocessor(con) -> None:
    """Session preprocessor: HAVING clause compiles and executes correctly."""
    fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    try:
        rows = fetchall(con,
            "SELECT customer_region, total_revenue "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region "
            "HAVING total_revenue > 1000 "
            "ORDER BY customer_region"
        )
        regions = [r[0] for r in rows]
        assert_equal("having/preprocessor/regions", regions, ["North", "West"])
    finally:
        fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")


def test_having_preprocessor_between(con) -> None:
    """Session preprocessor: HAVING BETWEEN executes correctly."""
    fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    try:
        rows = fetchall(con,
            "SELECT customer_region, total_revenue "
            "FROM SEMANTIC_SALES.SALES "
            "GROUP BY customer_region "
            "HAVING total_revenue BETWEEN 100 AND 1600 "
            "ORDER BY customer_region"
        )
        regions = [r[0] for r in rows]
        assert_equal("having/preprocessor_between/regions", regions, ["South", "West"])
    finally:
        fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")


# ---------------------------------------------------------------------------
# Regression: existing features still work
# ---------------------------------------------------------------------------

def test_regression_where_still_works(con) -> None:
    """Existing WHERE dimension filters still compile and produce WHERE (not HAVING)."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE customer_region = 'North'"
    )
    if not assert_ok("regression/where_dim/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("regression/where_dim/where", sql, "WHERE")
    assert_not_contains("regression/where_dim/no_having", sql, "HAVING")
    rows = fetchall(con, sql)
    assert_equal("regression/where_dim/rows", len(rows), 1)


def test_regression_between_in_where_still_works(con) -> None:
    """BETWEEN in WHERE on dimension (Phase 1) still works after Phase 2 changes."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "WHERE order_month BETWEEN '2026-01-01' AND '2026-01-31'"
    )
    if not assert_ok("regression/between_where/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("regression/between_where/where", sql, "WHERE")
    assert_contains("regression/between_where/between", sql, "BETWEEN")
    assert_not_contains("regression/between_where/no_having", sql, "HAVING")


def test_regression_order_by_ordinal_still_works(con) -> None:
    """ORDER BY ordinal (Phase 1) still works after Phase 2 changes."""
    result = compile_sql(con,
        "SELECT customer_region, total_revenue "
        "FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region "
        "ORDER BY 2 DESC"
    )
    if not assert_ok("regression/ordinal/compiles", result):
        return
    sql = result["generated_sql"]
    assert_contains("regression/ordinal/order", sql, "ORDER BY")
    assert_contains("regression/ordinal/revenue", sql, '"total_revenue"')
    assert_contains("regression/ordinal/desc", sql, "DESC")


def test_regression_compile_request_json_no_having(con) -> None:
    """COMPILE_REQUEST_JSON without having still works exactly as before."""
    result = compile_request_json(con, {
        "model": "SALES",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [{"field": "customer_region", "op": "!=", "value": "South"}],
        "order_by": [{"field": "total_revenue", "direction": "DESC"}],
    })
    if not assert_ok("regression/request_json/compiles", result):
        return
    rows = fetchall(con, result["generated_sql"])
    assert_equal("regression/request_json/rows", len(rows), 2)


def test_regression_filters_reject_metrics(con) -> None:
    """COMPILE_REQUEST_JSON: explicit metric in filters array still returns error."""
    result = compile_request_json(con, {
        "model": "SALES",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [{"field": "total_revenue", "op": ">", "value": 0}],
        "order_by": [],
    })
    if result["status"] != "ERROR":
        fail("regression/filters_reject_metrics", f"expected ERROR, got {result['status']!r}")
    else:
        ok("regression/filters_reject_metrics", f"ERROR/{result['error_code']}: metric in filters rejected")


# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------

def main() -> None:
    con = connect()

    print("=== HAVING clause (direct) ===")
    test_having_basic_compiles(con)
    test_having_basic_executes(con)
    test_having_excludes_all(con)
    test_having_multiple_predicates(con)
    test_having_between(con)
    test_having_with_order_by(con)
    test_having_with_limit(con)
    test_having_no_group_by(con)
    test_having_filtered_metric(con)
    test_having_dimension_error(con)
    test_having_unknown_field_error(con)

    print("\n=== WHERE metric auto-routing ===")
    test_where_metric_auto_routed(con)
    test_where_metric_auto_routed_filters_correctly(con)
    test_where_mixed_dimension_and_metric(con)
    test_where_metric_only_predicate(con)
    test_where_metric_between_auto_routed(con)
    test_where_metric_preprocessor(con)

    print("\n=== HAVING combined with WHERE ===")
    test_having_combined_where_and_having(con)
    test_having_combined_with_order_and_limit(con)

    print("\n=== COMPILE_REQUEST_JSON with having ===")
    test_compile_request_json_having(con)
    test_compile_request_json_having_between(con)
    test_compile_request_json_having_with_filters(con)
    test_compile_request_json_having_dimension_error(con)
    test_compile_request_json_no_having(con)

    print("\n=== Materialization bypass ===")
    test_materialization_used_without_having(con)
    test_materialization_bypassed_with_having(con)
    test_materialization_bypassed_with_having_compile_request_json(con)

    print("\n=== HAVING preprocessor ===")
    test_having_preprocessor(con)
    test_having_preprocessor_between(con)

    print("\n=== Regression ===")
    test_regression_where_still_works(con)
    test_regression_between_in_where_still_works(con)
    test_regression_order_by_ordinal_still_works(con)
    test_regression_compile_request_json_no_having(con)
    test_regression_filters_reject_metrics(con)

    print()
    outcome = "PASSED" if FAILED == 0 else "FAILED"
    print(f"{outcome}: {PASSED} passed, {FAILED} failed")
    if FAILED > 0:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
