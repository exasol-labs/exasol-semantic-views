#!/usr/bin/env python3
"""Verify BUG-25 structural authoring cannot decertify a published surface."""

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


def expect_rejected(con: Any, sql: str, label: str) -> None:
    try:
        execute(con, sql)
    except Exception as exc:
        if "SEMANTIC_ADMIN_094" not in str(exc):
            raise AssertionError(f"{label} returned an unexpected error: {exc}") from exc
    else:
        raise AssertionError(f"{label} was accepted")


def assert_surface(con: Any) -> None:
    rows = [
        (str(status), float(amount))
        for status, amount in execute(
            con,
            "SELECT order_status, total_amount FROM SEMANTIC_BUG25_VERIFY.SALES "
            "GROUP BY order_status ORDER BY order_status",
        )
    ]
    expected = [("CLOSED", 10.0), ("OPEN", 20.0)]
    if rows != expected:
        raise AssertionError(f"published surface is unavailable or changed: {rows}")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug25_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG25_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG25_VERIFY")
        con.execute("""
            CREATE TABLE BUG25_VERIFY.ORDERS (
              ORDER_ID DECIMAL(18,0), ORDER_STATUS VARCHAR(20),
              AMOUNT DECIMAL(18,2)
            )
        """)
        con.execute("""
            CREATE TABLE BUG25_VERIFY.ORDERS_ALT (
              ORDER_ID DECIMAL(18,0), ORDER_STATUS VARCHAR(20),
              AMOUNT_ALT DECIMAL(18,2)
            )
        """)
        con.execute("""
            CREATE TABLE BUG25_VERIFY.ORDERS_INVALID (
              EXTERNAL_ID DECIMAL(18,0), ORDER_STATUS VARCHAR(20),
              AMOUNT DECIMAL(18,2)
            )
        """)
        for table in ("ORDERS", "ORDERS_ALT"):
            con.execute(
                f"INSERT INTO BUG25_VERIFY.{table} VALUES "
                "(1, 'CLOSED', 10), (2, 'OPEN', 20)"
            )

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug25_verify', 'SEMANTIC_BUG25_VERIFY', 'BUG-25 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug25_verify', 'orders', 'BUG25_VERIFY', 'ORDERS', 'o', 'o.order_id', 'One order', 'Orders')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug25_verify', 'orders', 'temporary_key', 'UNIQUE', 'Removal verification', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug25_verify', 'orders', 'temporary_key', 'ORDER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_COLUMN('bug25_verify', 'orders', 'temporary_key', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY('bug25_verify', 'orders', 'temporary_key')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug25_verify', 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug25_verify', 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug25_verify', 'SALES', 'orders', 'Sales')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug25_verify', 'SALES', 'orders', 'order_status', 'o.order_status', 'VARCHAR(20)', 'Order Status', 'Order status', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('bug25_verify', 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE', 'Amount', 'Order amount', FALSE, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('bug25_verify', 'orders', 'alternate', 'RELATION', 'BUG25_VERIFY', 'ORDERS_ALT', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('bug25_verify', 'DIMENSION', 'order_status', 'alternate', 'o.order_status', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('bug25_verify', 'FACT', 'amount', 'alternate', 'o.amount_alt', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('ALTER SEMANTIC VIEW bug25_verify.SALES REPLACE METRICS (METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)', FALSE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug25_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug25_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        ]
        for statement in setup:
            execute(con, statement)
        assert_surface(con)

        attempts = [
            (
                "invalid representation",
                "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('bug25_verify', 'orders', 'invalid', 'RELATION', 'BUG25_VERIFY', 'ORDERS_INVALID', 30, 'MANUAL')",
            ),
            (
                "invalid unique-key column",
                "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug25_verify', 'orders', 'orders_pk', 'MISSING_ID', NULL, 2)",
            ),
            (
                "required attribute-binding removal",
                "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ATTRIBUTE_BINDING('bug25_verify', 'FACT', 'amount', 'alternate')",
            ),
        ]
        for label, statement in attempts:
            expect_rejected(con, statement, label)
            assert_surface(con)

        print("ok BUG-25 inverse API: unique-key column and key can be removed")
        print("ok BUG-25 authoring: all three invalid mutations were restored")
        print("ok BUG-25 availability: published surface remained queryable")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug25_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG25_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
