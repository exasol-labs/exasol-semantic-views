#!/usr/bin/env python3
"""Verify BUG-28 compound teardown and successful recertification paths."""

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


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def expect_error(con: Any, sql: str, code: str) -> str:
    try:
        execute(con, sql)
    except Exception as exc:
        message = str(exc)
        if code not in message:
            raise AssertionError(f"expected {code}, got: {message}") from exc
        return message
    raise AssertionError(f"statement unexpectedly succeeded: {sql}")


def assert_surface(con: Any) -> None:
    rows = [
        (str(status), float(amount))
        for status, amount in execute(
            con,
            "SELECT order_status, total_amount FROM SEMANTIC_BUG28_VERIFY.SALES "
            "GROUP BY order_status ORDER BY order_status",
        )
    ]
    expected = [("CLOSED", 40.0), ("OPEN", 60.0)]
    if rows != expected:
        raise AssertionError(f"published result changed or became unavailable: {rows}")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug28_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG28_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG28_VERIFY")
        con.execute("""
            CREATE TABLE BUG28_VERIFY.ORDERS_PRIMARY (
              ORDER_ID DECIMAL(18,0), ORDER_TS TIMESTAMP,
              ORDER_STATUS VARCHAR(20), AMOUNT DECIMAL(18,2)
            )
        """)
        con.execute("CREATE TABLE BUG28_VERIFY.ORDERS_HOT LIKE BUG28_VERIFY.ORDERS_PRIMARY")
        con.execute("""
            INSERT INTO BUG28_VERIFY.ORDERS_PRIMARY VALUES
              (1, TIMESTAMP '2025-11-01 00:00:00', 'CLOSED', 10),
              (2, TIMESTAMP '2025-12-01 00:00:00', 'OPEN', 20),
              (3, TIMESTAMP '2026-01-01 00:00:00', 'CLOSED', 30),
              (4, TIMESTAMP '2026-02-01 00:00:00', 'OPEN', 40)
        """)
        con.execute("""
            INSERT INTO BUG28_VERIFY.ORDERS_HOT VALUES
              (3, TIMESTAMP '2026-01-01 00:00:00', 'CLOSED', 30),
              (4, TIMESTAMP '2026-02-01 00:00:00', 'OPEN', 40)
        """)
        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug28_verify', 'SEMANTIC_BUG28_VERIFY', 'BUG-28 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug28_verify', 'orders', 'BUG28_VERIFY', 'ORDERS_PRIMARY', 'o', 'o.order_id', 'One order', 'Orders')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug28_verify', 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug28_verify', 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug28_verify', 'SALES', 'orders', 'Sales')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug28_verify', 'SALES', 'orders', 'order_status', 'o.order_status', 'VARCHAR(20)', 'Order Status', 'Order status', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('bug28_verify', 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE', 'Amount', 'Order amount', FALSE, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('ALTER SEMANTIC VIEW bug28_verify.SALES REPLACE METRICS (METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)', FALSE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug28_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug28_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        ]
        for statement in setup:
            execute(con, statement)
        assert_surface(con)

        malformed = expect_error(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH("
            "'bug28_verify', 'orders', '[]')",
            "SEMANTIC_ADMIN_060",
        )
        if "table:" in malformed:
            raise AssertionError(f"coverage diagnostic leaked a Lua address: {malformed}")

        coverage = literal(
            json.dumps(
                [
                    {
                        "representation_name": "primary",
                        "coverage_predicate": "o.order_ts < TIMESTAMP '2026-01-01 00:00:00'",
                        "valid_from": None,
                        "valid_to": "2026-01-01 00:00:00",
                    },
                    {
                        "representation_name": "hot",
                        "coverage_predicate": "o.order_ts >= TIMESTAMP '2026-01-01 00:00:00'",
                        "valid_from": "2026-01-01 00:00:00",
                        "valid_to": None,
                    },
                ],
                separators=(",", ":"),
            )
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE("
            "'bug28_verify', 'orders', 'hot', 'RELATION', 'BUG28_VERIFY', "
            f"'ORDERS_HOT', 10, 'MANUAL', {coverage})",
        )
        assert_surface(con)

        expect_error(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_WITH_COLUMNS("
            "'bug28_verify', 'orders', 'orders_pk')",
            "SEMANTIC_ADMIN_094",
        )
        assert_surface(con)

        columns = literal(json.dumps([{"column_name": "ORDER_ID"}]))
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_WITH_COLUMNS("
            "'bug28_verify', 'orders', 'temporary_key', 'ALTERNATE', "
            f"'Removal probe', 'NATIVE', {columns})",
        )
        expect_error(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_COLUMN("
            "'bug28_verify', 'orders', 'temporary_key', 1)",
            "SEMANTIC_ADMIN_094",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_WITH_COLUMNS("
            "'bug28_verify', 'orders', 'temporary_key')",
        )
        remaining = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.UNIQUE_KEYS "
            "WHERE MODEL_NAME = 'bug28_verify' AND KEY_NAME = 'temporary_key'",
        )[0][0]
        if int(remaining) != 0:
            raise AssertionError("complete key removal left catalog rows")
        assert_surface(con)

        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION("
            "'bug28_verify', 'orders', 'hot')",
        )
        coverage_count = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS "
            "WHERE MODEL_NAME = 'bug28_verify' AND COVERAGE_PREDICATE IS NOT NULL",
        )[0][0]
        if int(coverage_count) != 0:
            raise AssertionError("F3 teardown left survivor coverage")
        assert_surface(con)

        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY("
            "'bug28_verify', 'orders', 'order_identity', 'GLOBAL', "
            "'DECIMAL(18,0)', 'Order identity')",
        )
        assert_surface(con)
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING("
            "'bug28_verify', 'order_identity', 'primary', "
            "'o.order_id', 'DIRECT')",
        )
        assert_surface(con)
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING("
            "'bug28_verify', 'order_identity', 'primary')",
        )
        assert_surface(con)
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY("
            "'bug28_verify', 'orders', 'order_identity')",
        )
        assert_surface(con)

        print("ok BUG-28 key: complete key and columns removed atomically")
        print("ok BUG-28 F3: final alternate removal cleared survivor coverage")
        print("ok BUG-28 identity: identity and binding lifecycle remained certified")
        print("ok BUG-28 diagnostic: empty coverage JSON has stable text")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug28_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG28_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
