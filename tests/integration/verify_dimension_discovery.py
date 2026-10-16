#!/usr/bin/env python3
"""Verify BUG-D-003 fix: dimension-only discovery requests.

Asserts that COMPILE_REQUEST_JSON accepts a metrics-less request when at
least one dimension is supplied, that the resulting SQL deduplicates
dimension values via GROUP BY, that filters compose, that HAVING is rejected,
that materialization is skipped (no aggregates means no aggregate
materialization), and that empty-everything still errors.
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
        print("pyexasol is required.", file=sys.stderr)
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


def compile_request(con, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    rows = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    ).fetchall()
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "generated_sql": row[4],
        "plan_json": row[5],
    }


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_contains(name: str, haystack: str, needle: str) -> None:
    if needle not in (haystack or ""):
        raise AssertionError(f"{name}: {needle!r} not found in {haystack!r}")
    print(f"ok {name}: found {needle!r}")


def assert_not_contains(name: str, haystack: str, needle: str) -> None:
    if needle in (haystack or ""):
        raise AssertionError(f"{name}: unexpectedly found {needle!r} in {haystack!r}")
    print(f"ok {name}: {needle!r} absent")


def main() -> None:
    con = connect()

    # 1. dimension-only request compiles OK.
    r = compile_request(con, {
        "model": "sales", "object": "SALES",
        "dimensions": ["customer_region"],
        "client": "verify_dimension_discovery",
    })
    assert_equal("dimension-only status", r["status"], "OK")
    assert_contains("dimension-only SQL has GROUP BY", r["generated_sql"], "GROUP BY")
    assert_not_contains("dimension-only SQL has no SUM/COUNT/AVG aggregates",
                        r["generated_sql"].upper(), "SUM(")
    assert_not_contains("dimension-only SQL has no COUNT()", r["generated_sql"].upper(), "COUNT(")

    # Execute the SQL and verify rows are deduplicated.
    rows = con.execute(r["generated_sql"]).fetchall()
    unique_regions = {row[0] for row in rows}
    assert_equal("dimension-only rows are deduplicated", len(rows), len(unique_regions))

    # Materialization should NOT have been selected for a dimension-only request
    # (sales has a sales_revenue_by_region aggregate that covers customer_region).
    plan = json.loads(r["plan_json"])
    selected = plan.get("selected_materialization")
    assert_equal("dimension-only skips materialization",
                 selected if isinstance(selected, str) else (selected or {}).get("materialization_name"), None)

    # 2. dimension-only with multiple dimensions and a filter.
    r = compile_request(con, {
        "model": "sales", "object": "SALES",
        "dimensions": ["customer_region", "order_month"],
        "filters": [{"field": "order_status", "op": "=", "value": "COMPLETE"}],
        "client": "verify_dimension_discovery",
    })
    assert_equal("multi-dim + filter status", r["status"], "OK")
    assert_contains("multi-dim + filter has WHERE", r["generated_sql"], "WHERE")
    assert_contains("multi-dim + filter has GROUP BY", r["generated_sql"], "GROUP BY")
    rows = con.execute(r["generated_sql"]).fetchall()
    assert_equal("multi-dim + filter rows are deduplicated",
                 len(rows), len({(row[0], row[1]) for row in rows}))

    # 3. HAVING in a dimension-only request is rejected with the new code.
    r = compile_request(con, {
        "model": "sales", "object": "SALES",
        "dimensions": ["customer_region"],
        "having": [{"field": "total_revenue", "op": ">", "value": 0}],
        "client": "verify_dimension_discovery",
    })
    assert_equal("HAVING without metric status", r["status"], "ERROR")
    assert_equal("HAVING without metric error code", r["error_code"], "SEMANTIC_REQUEST_026")

    # 4. empty metrics AND empty dimensions still errors.
    r = compile_request(con, {
        "model": "sales", "object": "SALES",
        "client": "verify_dimension_discovery",
    })
    assert_equal("empty request status", r["status"], "ERROR")
    assert_equal("empty request error code", r["error_code"], "SEMANTIC_REQUEST_023")
    assert_contains("empty request error message mentions both",
                    r["error_message"], "metric or dimension")

    # 5. dimensions-only still works alongside metrics in the regular path
    # (sanity check we didn't break the common case).
    r = compile_request(con, {
        "model": "sales", "object": "SALES",
        "metrics": ["total_revenue"], "dimensions": ["customer_region"],
        "client": "verify_dimension_discovery",
    })
    assert_equal("metric+dimension status", r["status"], "OK")
    assert_contains("metric+dimension SQL has SUM", r["generated_sql"].upper(), "SUM(")

    con.close()


if __name__ == "__main__":
    main()
