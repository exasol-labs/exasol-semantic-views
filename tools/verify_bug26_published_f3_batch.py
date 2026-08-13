#!/usr/bin/env python3
"""Verify BUG-26 F3 can be configured atomically on a published model."""

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


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def coverage_batch(con: Any, declarations: list[dict[str, Any]]) -> None:
    payload = sql_literal(json.dumps(declarations, separators=(",", ":")))
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH("
        f"'bug26_verify', 'orders', {payload})",
    )


def surface_rows(con: Any) -> list[tuple[str, float]]:
    return [
        (str(status), float(amount))
        for status, amount in execute(
            con,
            "SELECT order_status, total_amount FROM SEMANTIC_BUG26_VERIFY.SALES "
            "GROUP BY order_status ORDER BY order_status",
        )
    ]


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug26_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG26_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG26_VERIFY")
        con.execute("""
            CREATE TABLE BUG26_VERIFY.ORDERS_PRIMARY (
              ORDER_ID DECIMAL(18,0), ORDER_TS TIMESTAMP,
              ORDER_STATUS VARCHAR(20), AMOUNT DECIMAL(18,2)
            )
        """)
        con.execute("CREATE TABLE BUG26_VERIFY.ORDERS_COLD LIKE BUG26_VERIFY.ORDERS_PRIMARY")
        values = """
            (1, TIMESTAMP '2025-11-01 00:00:00', 'CLOSED', 10),
            (2, TIMESTAMP '2025-12-01 00:00:00', 'OPEN', 20),
            (3, TIMESTAMP '2026-01-01 00:00:00', 'CLOSED', 30),
            (4, TIMESTAMP '2026-02-01 00:00:00', 'OPEN', 40)
        """
        con.execute(f"INSERT INTO BUG26_VERIFY.ORDERS_PRIMARY VALUES {values}")
        con.execute(f"INSERT INTO BUG26_VERIFY.ORDERS_COLD VALUES {values}")

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug26_verify', 'SEMANTIC_BUG26_VERIFY', 'BUG-26 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug26_verify', 'orders', 'BUG26_VERIFY', 'ORDERS_PRIMARY', 'o', 'o.order_id', 'One order', 'Orders')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug26_verify', 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug26_verify', 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug26_verify', 'SALES', 'orders', 'Sales')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug26_verify', 'SALES', 'orders', 'order_status', 'o.order_status', 'VARCHAR(20)', 'Order Status', 'Order status', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('bug26_verify', 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE', 'Amount', 'Order amount', FALSE, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('bug26_verify', 'orders', 'cold', 'RELATION', 'BUG26_VERIFY', 'ORDERS_COLD', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('bug26_verify', 'DIMENSION', 'order_status', 'cold', 'o.order_status', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('bug26_verify', 'FACT', 'amount', 'cold', 'o.amount', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('ALTER SEMANTIC VIEW bug26_verify.SALES REPLACE METRICS (METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)', FALSE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug26_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug26_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        ]
        for statement in setup:
            execute(con, statement)
        expected = [("CLOSED", 40.0), ("OPEN", 60.0)]
        if surface_rows(con) != expected:
            raise AssertionError("unexpected F1 baseline")

        first_single = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE("
            "'bug26_verify', 'orders', 'cold', "
            "'o.order_ts < TIMESTAMP ''2026-01-01 00:00:00''', NULL, "
            "TIMESTAMP '2026-01-01 00:00:00')"
        )
        try:
            execute(con, first_single)
        except Exception as exc:
            if "SEMANTIC_ADMIN_059" not in str(exc):
                raise AssertionError(f"unexpected single-row rejection: {exc}") from exc
        else:
            raise AssertionError("incomplete single-row F3 declaration was accepted")
        if surface_rows(con) != expected:
            raise AssertionError("single-row rejection decertified the surface")

        coverage_batch(
            con,
            [
                {
                    "representation_name": "cold",
                    "coverage_predicate": "o.order_ts < TIMESTAMP '2026-01-01 00:00:00'",
                    "valid_from": None,
                    "valid_to": "2026-01-01 00:00:00",
                },
                {
                    "representation_name": "primary",
                    "coverage_predicate": "o.order_ts >= TIMESTAMP '2026-01-01 00:00:00'",
                    "valid_from": "2026-01-01 00:00:00",
                    "valid_to": None,
                },
            ],
        )
        if surface_rows(con) != expected:
            raise AssertionError("published F3 batch changed query results")
        covered = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS "
            "WHERE MODEL_NAME = 'bug26_verify' AND ENTITY_NAME = 'orders' "
            "AND COVERAGE_PREDICATE IS NOT NULL",
        )[0][0]
        if int(covered) != 2:
            raise AssertionError(f"expected two covered representations, got {covered}")

        try:
            coverage_batch(
                con,
                [
                    {
                        "representation_name": "cold",
                        "coverage_predicate": "o.order_ts < TIMESTAMP '2026-02-01 00:00:00'",
                        "valid_from": None,
                        "valid_to": "2026-01-01 00:00:00",
                    },
                    {
                        "representation_name": "primary",
                        "coverage_predicate": "o.order_ts >= TIMESTAMP '2026-01-01 00:00:00'",
                        "valid_from": "2026-01-01 00:00:00",
                        "valid_to": None,
                    },
                ],
            )
        except Exception as exc:
            if "SEMANTIC_ADMIN_059" not in str(exc):
                raise AssertionError(f"unexpected batch rejection: {exc}") from exc
        else:
            raise AssertionError("invalid published coverage batch was accepted")
        if surface_rows(con) != expected:
            raise AssertionError("invalid batch rollback decertified the surface")

        print("ok BUG-26 reproduction: sequential initialization remains safely rejected")
        print("ok BUG-26 batch: complete F3 coverage applied to published model")
        print("ok BUG-26 rollback: invalid complete batch restored prior F3 coverage")
        print("ok BUG-26 availability: published result remained stable")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug26_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG26_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
