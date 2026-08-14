#!/usr/bin/env python3
"""Verify BUG-27 compound declarations are reachable on published models."""

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


def surface(con: Any) -> list[tuple[str, float]]:
    return [
        (str(status), float(amount))
        for status, amount in execute(
            con,
            "SELECT order_status, total_amount FROM SEMANTIC_BUG27_VERIFY.SALES "
            "GROUP BY order_status ORDER BY order_status",
        )
    ]


def expect_error(con: Any, sql: str, code: str, label: str) -> None:
    try:
        execute(con, sql)
    except Exception as exc:
        if code not in str(exc):
            raise AssertionError(f"{label} returned an unexpected error: {exc}") from exc
    else:
        raise AssertionError(f"{label} was accepted")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug27_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG27_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG27_VERIFY")
        con.execute("""
            CREATE TABLE BUG27_VERIFY.ORDERS_PRIMARY (
              ORDER_ID DECIMAL(18,0), ORDER_TS TIMESTAMP,
              ORDER_STATUS VARCHAR(20), AMOUNT DECIMAL(18,2)
            )
        """)
        con.execute("CREATE TABLE BUG27_VERIFY.ORDERS_HOT LIKE BUG27_VERIFY.ORDERS_PRIMARY")
        con.execute("""
            INSERT INTO BUG27_VERIFY.ORDERS_PRIMARY VALUES
              (1, TIMESTAMP '2025-11-01 00:00:00', 'CLOSED', 10),
              (2, TIMESTAMP '2025-12-01 00:00:00', 'OPEN', 20),
              (3, TIMESTAMP '2026-01-01 00:00:00', 'CLOSED', 30),
              (4, TIMESTAMP '2026-02-01 00:00:00', 'OPEN', 40)
        """)
        con.execute("""
            INSERT INTO BUG27_VERIFY.ORDERS_HOT VALUES
              (3, TIMESTAMP '2026-01-01 00:00:00', 'CLOSED', 30),
              (4, TIMESTAMP '2026-02-01 00:00:00', 'OPEN', 40)
        """)
        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug27_verify', 'SEMANTIC_BUG27_VERIFY', 'BUG-27 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug27_verify', 'orders', 'BUG27_VERIFY', 'ORDERS_PRIMARY', 'o', 'o.order_id', 'One order', 'Orders')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug27_verify', 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug27_verify', 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug27_verify', 'SALES', 'orders', 'Sales')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug27_verify', 'SALES', 'orders', 'order_status', 'o.order_status', 'VARCHAR(20)', 'Order Status', 'Order status', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('bug27_verify', 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE', 'Amount', 'Order amount', FALSE, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('ALTER SEMANTIC VIEW bug27_verify.SALES REPLACE METRICS (METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)', FALSE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug27_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug27_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        ]
        for statement in setup:
            execute(con, statement)
        expected = [("CLOSED", 40.0), ("OPEN", 60.0)]
        if surface(con) != expected:
            raise AssertionError("unexpected published baseline")

        ordinary_representation = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION("
            "'bug27_verify', 'orders', 'hot', 'RELATION', "
            "'BUG27_VERIFY', 'ORDERS_HOT', 10, 'MANUAL')"
        )
        expect_error(con, ordinary_representation, "SEMANTIC_ADMIN_094", "ordinary hot registration")
        if surface(con) != expected:
            raise AssertionError("rejected hot registration decertified the surface")

        invalid_coverage = literal(
            json.dumps(
                [
                    {
                        "representation_name": "primary",
                        "coverage_predicate": "o.order_ts < TIMESTAMP '2026-01-01 00:00:00'",
                        "valid_from": None,
                        "valid_to": "2026-01-01 00:00:00",
                    },
                    {
                        "representation_name": "hot_bad",
                        "coverage_predicate": "o.order_ts >= TIMESTAMP '2026-02-01 00:00:00'",
                        "valid_from": "2026-01-01 00:00:00",
                        "valid_to": None,
                    },
                ],
                separators=(",", ":"),
            )
        )
        invalid_compound_representation = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE("
            "'bug27_verify', 'orders', 'hot_bad', 'RELATION', 'BUG27_VERIFY', "
            f"'ORDERS_HOT', 10, 'MANUAL', {invalid_coverage})"
        )
        expect_error(
            con,
            invalid_compound_representation,
            "SEMANTIC_ADMIN_061",
            "invalid compound representation",
        )
        residual = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS "
            "WHERE MODEL_NAME = 'bug27_verify' AND REPRESENTATION_NAME = 'hot_bad'",
        )[0][0]
        if int(residual) != 0 or surface(con) != expected:
            raise AssertionError("invalid compound representation was not fully restored")

        coverage = json.dumps(
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
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE("
            "'bug27_verify', 'orders', 'hot', 'RELATION', 'BUG27_VERIFY', "
            f"'ORDERS_HOT', 10, 'MANUAL', {literal(coverage)})",
        )
        if surface(con) != expected:
            raise AssertionError("compound F3 declaration changed published results")

        partition_dimension = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION_WITH_BINDINGS("
            "'bug27_verify', 'SALES', 'orders', 'order_month', "
            "'TO_CHAR(o.order_ts, ''YYYY-MM'')', 'VARCHAR(7)', 'Order Month', "
            f"'Order month', NULL, TRUE, {literal('[]')})",
        )
        if len(partition_dimension) != 1 or int(partition_dimension[0][5]) != 2:
            raise AssertionError(
                f"F3 compound dimension returned unexpected rows: {partition_dimension}"
            )
        partition_bindings = execute(
            con,
            "SELECT REPRESENTATION_NAME FROM SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS "
            "WHERE MODEL_NAME = 'bug27_verify' AND ATTRIBUTE_NAME = 'order_month' "
            "ORDER BY REPRESENTATION_NAME",
        )
        if partition_bindings != [("hot",), ("primary",)]:
            raise AssertionError(
                f"F3 compound dimension did not auto-seed partitions: {partition_bindings}"
            )
        if surface(con) != expected:
            raise AssertionError("F3 compound dimension changed published results")

        ordinary_key = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
            "'bug27_verify', 'orders', 'status_order_key', 'ALTERNATE', "
            "'Composite probe', 'NATIVE')"
        )
        expect_error(con, ordinary_key, "SEMANTIC_ADMIN_094", "ordinary key declaration")
        columns = literal(
            json.dumps(
                [
                    {"ordinal_position": 1, "column_name": "ORDER_STATUS"},
                    {"ordinal_position": 2, "column_name": "ORDER_ID"},
                ],
                separators=(",", ":"),
            )
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_WITH_COLUMNS("
            "'bug27_verify', 'orders', 'status_order_key', 'ALTERNATE', "
            f"'Composite probe', 'NATIVE', {columns})",
        )
        if surface(con) != expected:
            raise AssertionError("compound key declaration decertified the surface")
        key_columns = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.UNIQUE_KEY_COLUMNS "
            "WHERE MODEL_NAME = 'bug27_verify' AND KEY_NAME = 'status_order_key'",
        )[0][0]
        if int(key_columns) != 2:
            raise AssertionError(f"expected two key columns, got {key_columns}")

        invalid_columns = literal(
            json.dumps([{"column_name": "MISSING_ID"}], separators=(",", ":"))
        )
        invalid_key = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_WITH_COLUMNS("
            "'bug27_verify', 'orders', 'invalid_key', 'ALTERNATE', "
            f"'Invalid probe', 'NATIVE', {invalid_columns})"
        )
        expect_error(con, invalid_key, "SEMANTIC_ADMIN_094", "invalid compound key")
        residual = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.UNIQUE_KEYS "
            "WHERE MODEL_NAME = 'bug27_verify' AND KEY_NAME = 'invalid_key'",
        )[0][0]
        if int(residual) != 0 or surface(con) != expected:
            raise AssertionError("invalid compound key was not fully restored")

        print("ok BUG-27 F3: genuine hot partition registered with complete coverage")
        print("ok BUG-38 F3: compound attribute auto-seeded covered partitions")
        print("ok BUG-27 key: complete composite key added to published model")
        print("ok BUG-27 rollback: invalid compound declarations left no catalog residue")
        print("ok BUG-27 availability: published result remained stable")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug27_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG27_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
