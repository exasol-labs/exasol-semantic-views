#!/usr/bin/env python3
"""Demonstrate and assert fan-out protection on the shipped sales model.

The demo model is deliberately multi-grain: `net_revenue`/`net_cost`/`quantity`
sit at order-line grain in the SALES object, while `freight_amount` is charged
once per order and is exposed through the ORDER_HEADER object.

That shape makes the product's central safety property observable:

  1. order-grain metrics group correctly by dimensions reachable without
     fan-out (`ship_mode` on the order itself, `customer_segment` through the
     MANY_TO_ONE order_to_customer edge);
  2. the same metric cannot be placed alongside `product_category`, because the
     only path from `order` to `product` runs backwards through
     order_line_to_order. Validation refuses it at authoring time with
     SEMANTIC_MODEL_030 / ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED and rolls the
     catalog back;
  3. the number that refusal prevents is materially wrong -- this script joins
     the tables by hand to show the inflation.

Run after `python3 tools/install.py --example`. Read it top to bottom as a
walkthrough; it is also a regression test, so every claim is asserted.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from decimal import Decimal
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
    row = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    ).fetchall()[0]
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


def grouped(con, sql: str) -> dict[str, Decimal]:
    return {str(row[0]): Decimal(str(row[1])) for row in con.execute(sql).fetchall()}


def section(title: str) -> None:
    print()
    print(f"--- {title} " + "-" * max(0, 66 - len(title)))


def main() -> None:
    con = connect()

    # ------------------------------------------------------------------
    section("1. order-grain metric, dimensions reachable without fan-out")
    # ------------------------------------------------------------------
    # ship_mode lives on the order itself; customer_segment is reached through
    # order_to_customer (MANY_TO_ONE, outward from the root). Both are safe, so
    # the compiler joins them and the answers match hand-written SQL.
    for dimension, reference in (
        (
            "ship_mode",
            "SELECT o.ship_mode, SUM(o.freight_amount) "
            "FROM MART.ORDERS o GROUP BY o.ship_mode",
        ),
        (
            "customer_segment",
            "SELECT c.segment, SUM(o.freight_amount) "
            "FROM MART.ORDERS o JOIN MART.CUSTOMERS c ON o.customer_id = c.customer_id "
            "GROUP BY c.segment",
        ),
    ):
        result = compile_request(con, {
            "model": "sales", "object": "ORDER_HEADER",
            "metrics": ["total_freight"], "dimensions": [dimension],
            "client": "verify_fanout_guardrails",
        })
        assert_equal(f"total_freight by {dimension} compiles", result["status"], "OK")
        print(f"   {result['generated_sql']}")
        assert_equal(
            f"total_freight by {dimension} matches reference SQL",
            grouped(con, result["generated_sql"]),
            grouped(con, reference),
        )

    # ------------------------------------------------------------------
    section("2. the fan-out combination cannot even be requested")
    # ------------------------------------------------------------------
    # product_category is not a column of ORDER_HEADER, so the object boundary
    # refuses the request before any planning happens.
    result = compile_request(con, {
        "model": "sales", "object": "ORDER_HEADER",
        "metrics": ["total_freight"], "dimensions": ["product_category"],
        "client": "verify_fanout_guardrails",
    })
    assert_equal("total_freight by product_category refused", result["status"], "ERROR")
    print(f"   {result['error_code']}: {result['error_message']}")

    # ------------------------------------------------------------------
    section("3. and it cannot be authored into SALES either")
    # ------------------------------------------------------------------
    # SALES exposes product_category, so an order-grain metric there would be
    # groupable along a fan-out path. Validation refuses the metric at
    # definition time -- not at query time -- and restores the catalog.
    before = con.execute(
        "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME = 'sales'"
    ).fetchall()[0][0]
    try:
        con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC("
            "'sales','SALES','freight_in_sales','SUM(freight_amount)',NULL,'ADDITIVE',"
            "'order','DECIMAL(18,2)','Freight (misplaced)',"
            "'Order-grain metric deliberately added to a line-grain object',"
            "'currency',FALSE,TRUE)"
        )
        raise AssertionError("ADD_METRIC was accepted; fan-out guardrail did not fire")
    except AssertionError:
        raise
    except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
        message = str(exc)
    # pyexasol wraps the refusal in a multi-line report; print the message line.
    refusal = next(
        (line.split("=>", 1)[1].strip() for line in message.splitlines()
         if line.strip().startswith("message")),
        message.strip(),
    )
    print(f"   {refusal}")
    assert_contains("refusal names the rule", message, "SEMANTIC_MODEL_030")
    assert_contains("refusal names the reason", message,
                    "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")
    assert_contains("refusal names the offending path", message, "order_line_to_order")
    assert_contains("refusal names the dimension", message, "product_category")
    # The remedy named must be one that exists: no relationship declaration can
    # make a fanning traversal safe, so the message points at object membership.
    assert_contains("refusal names a remedy that exists", message,
                    "No relationship declaration makes a fanning traversal safe")

    after = con.execute(
        "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME = 'sales'"
    ).fetchall()[0][0]
    assert_equal("catalog rolled back to its previous metric count", after, before)
    assert_equal(
        "rejected metric is absent",
        con.execute(
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS "
            "WHERE MODEL_NAME = 'sales' AND METRIC_NAME = 'freight_in_sales'"
        ).fetchall()[0][0],
        0,
    )

    # The compatibility matrix records the same verdict for the metric that is
    # correctly placed, so agents can see the boundary without hitting it.
    invalid = con.execute(
        "SELECT METRIC_NAME, DIMENSION_NAME, REASON_CODE, RELATIONSHIP_PATH "
        "FROM SEMANTIC_CATALOG.METRIC_DIMENSION_MATRIX "
        "WHERE MODEL_NAME = 'sales' AND NOT IS_VALID ORDER BY 1, 2"
    ).fetchall()
    assert_equal(
        "matrix publishes the one impossible pair",
        [(r[0], r[1], r[2]) for r in invalid],
        [("total_freight", "product_category", "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")],
    )
    print(f"   path: {invalid[0][3]}")

    # ------------------------------------------------------------------
    section("4. what the guardrail is worth")
    # ------------------------------------------------------------------
    # Join order headers to lines by hand -- the query a SQL author would write
    # for "freight by product category" -- and compare against the truth.
    fanned = grouped(con, """
        SELECT p.category, SUM(o.freight_amount)
        FROM MART.ORDERS o
        JOIN MART.ORDER_LINES ol ON ol.order_id = o.order_id
        JOIN MART.PRODUCTS p ON p.product_id = ol.product_id
        GROUP BY p.category
    """)
    total_freight = Decimal(
        str(con.execute("SELECT SUM(freight_amount) FROM MART.ORDERS").fetchall()[0][0])
    )
    inflated = sum(fanned.values())
    for category, amount in sorted(fanned.items()):
        print(f"   hand-written join: {category:<12} {amount}")
    print(f"   hand-written join total: {inflated}  (actual freight charged: {total_freight})")
    if inflated <= total_freight:
        raise AssertionError(
            f"expected the hand-written join to inflate freight, got {inflated} "
            f"against {total_freight}"
        )
    print(f"ok fan-out would have overstated freight by {inflated - total_freight}")

    con.close()
    print()
    print("fan-out guardrails verified.")


if __name__ == "__main__":
    main()
