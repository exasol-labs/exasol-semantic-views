#!/usr/bin/env python3
"""Verify optional GROUP BY inference on the semantic SQL surface against Exasol.

When dimensions are selected without a GROUP BY clause, the compiler now infers
GROUP BY from the selected dimensions (instead of returning SEMANTIC_QUERY_007).
A GROUP BY that *is* supplied must still exactly cover the selected dimensions.

Run against a local instance after installing the edited runtime:
  python3 tools/install.py --example --reset

Sales model dimensions: customer_region, order_month, order_status, product_category
Sales model metrics: total_revenue, completed_revenue, gross_margin, gross_margin_pct, total_cost
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
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "original_sql": row[3],
        "generated_sql": row[4],
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


def expect_ok(name: str, result: dict[str, Any]) -> bool:
    if result["status"] != "OK" or not result["generated_sql"]:
        fail(name, f"expected OK with SQL, got {result['status']!r} {result['error_code']!r}: {result['error_message']!r}")
        return False
    ok(name, "OK")
    return True


def expect_error(name: str, result: dict[str, Any], code: str) -> bool:
    if result["status"] != "ERROR" or result["error_code"] != code:
        fail(name, f"expected ERROR/{code}, got {result['status']!r}/{result['error_code']!r}")
        return False
    ok(name, f"ERROR/{code}")
    return True


def contains(name: str, text: str, needle: str) -> bool:
    if not text or needle not in text:
        fail(name, f"expected {needle!r} in {text!r}")
        return False
    ok(name, f"contains {needle!r}")
    return True


def main() -> int:
    con = connect()
    try:
        fetchall(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")

        # 1. Single dimension + metric, no GROUP BY -> inferred.
        r = compile_sql(con, "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES")
        if expect_ok("single_dim/no_group_by", r):
            contains("single_dim/no_group_by/has_group_by", r["generated_sql"], "GROUP BY")

        # 2. Inferred result equals the explicit GROUP BY result (rows + values).
        inferred_sql = compile_sql(con, "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES")["generated_sql"]
        explicit_sql = compile_sql(con, "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES GROUP BY customer_region")["generated_sql"]
        inferred_rows = sorted(str(row) for row in fetchall(con, inferred_sql))
        explicit_rows = sorted(str(row) for row in fetchall(con, explicit_sql))
        if inferred_rows == explicit_rows and len(inferred_rows) == 3:
            ok("inferred_equals_explicit", f"{len(inferred_rows)} rows match")
        else:
            fail("inferred_equals_explicit", f"inferred={inferred_rows} explicit={explicit_rows}")

        # 3. Multiple dimensions, no GROUP BY -> all dimensions inferred into GROUP BY.
        r = compile_sql(con, "SELECT customer_region, product_category, total_revenue FROM SEMANTIC_SALES.SALES")
        if expect_ok("multi_dim/no_group_by", r):
            contains("multi_dim/no_group_by/region", r["generated_sql"], "c.region")
            contains("multi_dim/no_group_by/category", r["generated_sql"], "p.category")

        # 4. Metric-only (no dimensions) still compiles without GROUP BY.
        expect_ok("metric_only/no_group_by", compile_sql(con, "SELECT total_revenue FROM SEMANTIC_SALES.SALES"))

        # 5. A supplied GROUP BY that does not cover the selected dimensions is still rejected.
        expect_error("wrong_group_by/rejected", compile_sql(
            con, "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES GROUP BY product_category"
        ), "SEMANTIC_QUERY_008")

        # 6. A correct explicit GROUP BY still works (no regression).
        expect_ok("explicit_group_by/still_ok", compile_sql(
            con, "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES GROUP BY customer_region"
        ))

        # 7. GROUP BY on a metric-only query is still rejected.
        expect_error("metric_only/with_group_by/rejected", compile_sql(
            con, "SELECT total_revenue FROM SEMANTIC_SALES.SALES GROUP BY customer_region"
        ), "SEMANTIC_QUERY_008")

        # 8. Inference composes with WHERE / ORDER BY / LIMIT.
        r = compile_sql(con,
            "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES "
            "WHERE customer_region <> 'South' ORDER BY 2 DESC LIMIT 1")
        if expect_ok("no_group_by/with_where_order_limit", r):
            contains("no_group_by/with_where_order_limit/group", r["generated_sql"], "GROUP BY")

        print()
        outcome = "PASSED" if FAILED == 0 else "FAILED"
        print(f"{outcome}: {PASSED} passed, {FAILED} failed")
        return 0 if FAILED == 0 else 1
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
