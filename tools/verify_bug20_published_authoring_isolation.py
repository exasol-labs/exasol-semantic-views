#!/usr/bin/env python3
"""Verify BUG-20 invalid coverage authoring cannot decertify a published surface."""

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
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def execute(con: Any, sql: str) -> list[tuple[Any, ...]]:
    statement = con.execute(sql)
    if statement.num_columns == 0:
        return []
    return [tuple(row) for row in statement.fetchall()]


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug20_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG20_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG20_VERIFY")
        con.execute("""
            CREATE TABLE BUG20_VERIFY.ORDERS_COLD (
              ORDER_ID DECIMAL(18,0), ORDER_TS TIMESTAMP,
              ORDER_STATUS VARCHAR(20), AMOUNT DECIMAL(18,2)
            )
        """)
        con.execute("CREATE TABLE BUG20_VERIFY.ORDERS_HOT LIKE BUG20_VERIFY.ORDERS_COLD")
        con.execute("""
            INSERT INTO BUG20_VERIFY.ORDERS_COLD VALUES
              (1, TIMESTAMP '2025-11-01 00:00:00', 'CLOSED', 10),
              (2, TIMESTAMP '2025-12-01 00:00:00', 'OPEN', 20)
        """)
        con.execute("""
            INSERT INTO BUG20_VERIFY.ORDERS_HOT VALUES
              (3, TIMESTAMP '2026-01-01 00:00:00', 'CLOSED', 30),
              (4, TIMESTAMP '2026-02-01 00:00:00', 'OPEN', 40)
        """)

        statements = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug20_verify', 'SEMANTIC_BUG20_VERIFY', 'BUG-20 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug20_verify', 'orders', 'BUG20_VERIFY', 'ORDERS_HOT', 'o', 'o.order_id', 'One order', 'Partitioned orders')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug20_verify', 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug20_verify', 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('bug20_verify', 'orders', 'cold', 'RELATION', 'BUG20_VERIFY', 'ORDERS_COLD', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE('bug20_verify', 'orders', 'cold', 'o.order_ts < TIMESTAMP ''2026-01-01 00:00:00''', NULL, TIMESTAMP '2026-01-01 00:00:00')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE('bug20_verify', 'orders', 'primary', 'o.order_ts >= TIMESTAMP ''2026-01-01 00:00:00''', TIMESTAMP '2026-01-01 00:00:00', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug20_verify', 'SALES', 'orders', 'Partitioned sales')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug20_verify', 'SALES', 'orders', 'order_status', 'o.order_status', 'VARCHAR(20)', 'Order Status', 'Order status', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('bug20_verify', 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE', 'Amount', 'Order amount', FALSE, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING('bug20_verify', 'DIMENSION', 'order_status', 'cold', 'o.order_status', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING('bug20_verify', 'FACT', 'amount', 'cold', 'o.amount', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('ALTER SEMANTIC VIEW bug20_verify.SALES REPLACE METRICS (METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)', FALSE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug20_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug20_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        ]
        for statement in statements:
            execute(con, statement)

        query = (
            "SELECT order_status, total_amount FROM SEMANTIC_BUG20_VERIFY.SALES "
            "GROUP BY order_status ORDER BY order_status"
        )
        before = [(str(status), float(amount))
                  for status, amount in execute(con, query)]
        expected = [("CLOSED", 40.0), ("OPEN", 60.0)]
        if before != expected:
            raise AssertionError(f"unexpected published result before authoring: {before}")

        invalid = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE("
            "'bug20_verify', 'orders', 'cold', "
            "'o.order_ts < TIMESTAMP ''2026-02-01 00:00:00''', NULL, "
            "TIMESTAMP '2026-01-01 00:00:00')"
        )
        try:
            execute(con, invalid)
        except Exception as exc:
            if "SEMANTIC_ADMIN_059" not in str(exc):
                raise AssertionError(f"unexpected coverage rejection: {exc}") from exc
        else:
            raise AssertionError("invalid published coverage change was accepted")

        after = [(str(status), float(amount))
                 for status, amount in execute(con, query)]
        if after != expected:
            raise AssertionError(f"published surface changed after rejection: {after}")
        restored = execute(
            con,
            "SELECT COVERAGE_PREDICATE FROM SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS "
            "WHERE MODEL_NAME = 'bug20_verify' AND ENTITY_NAME = 'orders' "
            "AND REPRESENTATION_NAME = 'cold'",
        )[0][0]
        if "2026-01-01" not in str(restored) or "2026-02-01" in str(restored):
            raise AssertionError(f"coverage was not restored: {restored}")

        print("ok BUG-20 baseline: published surface returns partitioned totals")
        print("ok BUG-20 authoring: invalid coverage rejected and restored")
        print("ok BUG-20 availability: published surface remains queryable")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug20_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG20_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
