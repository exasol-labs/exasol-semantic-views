#!/usr/bin/env python3
"""Verify F3 hot/cold UNION fusion against Exasol."""

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


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


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
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f3_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS F3_VERIFY CASCADE")
        con.execute("CREATE SCHEMA F3_VERIFY")
        con.execute("""
            CREATE TABLE F3_VERIFY.ORDERS_COLD (
              ORDER_ID DECIMAL(18,0), ORDER_TS TIMESTAMP,
              ORDER_STATUS VARCHAR(20), AMOUNT DECIMAL(18,2)
            )
        """)
        con.execute("CREATE TABLE F3_VERIFY.ORDERS_HOT LIKE F3_VERIFY.ORDERS_COLD")
        con.execute("""
            INSERT INTO F3_VERIFY.ORDERS_COLD VALUES
              (1, TIMESTAMP '2025-11-01 00:00:00', 'CLOSED', 10),
              (2, TIMESTAMP '2025-12-01 00:00:00', 'OPEN', 20)
        """)
        con.execute("""
            INSERT INTO F3_VERIFY.ORDERS_HOT VALUES
              (3, TIMESTAMP '2026-01-01 00:00:00', 'CLOSED', 30),
              (4, TIMESTAMP '2026-02-01 00:00:00', 'OPEN', 40)
        """)

        statements = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('f3_verify', 'SEMANTIC_F3_VERIFY', 'F3 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('f3_verify', 'orders', 'F3_VERIFY', 'ORDERS_HOT', 'o', 'o.order_id', 'One order', 'Partitioned orders')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('f3_verify', 'orders', 'orders_pk', 'PRIMARY', 'Order identity', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('f3_verify', 'orders', 'orders_pk', 'ORDER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('f3_verify', 'orders', 'cold', 'RELATION', 'F3_VERIFY', 'ORDERS_COLD', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE('f3_verify', 'orders', 'cold', 'o.order_ts < TIMESTAMP ''2026-01-01 00:00:00''', NULL, TIMESTAMP '2026-01-01 00:00:00')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE('f3_verify', 'orders', 'primary', 'o.order_ts >= TIMESTAMP ''2026-01-01 00:00:00''', TIMESTAMP '2026-01-01 00:00:00', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('f3_verify', 'SALES', 'orders', 'Partitioned sales')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('f3_verify', 'SALES', 'orders', 'order_status', 'o.order_status', 'VARCHAR(20)', 'Order Status', 'Order status', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('f3_verify', 'orders', 'amount', 'o.amount', 'DECIMAL(18,2)', 'ADDITIVE', 'Amount', 'Order amount', FALSE, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING('f3_verify', 'DIMENSION', 'order_status', 'cold', 'o.order_status', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING('f3_verify', 'FACT', 'amount', 'cold', 'o.amount', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('ALTER SEMANTIC VIEW f3_verify.SALES REPLACE METRICS (METRIC total_amount AS SUM(amount) ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)', FALSE)",
        ]
        for statement in statements:
            execute(con, statement)

        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE("
            "'f3_verify', 'orders', 'cold', "
            "'o.order_ts < TIMESTAMP ''2026-02-01 00:00:00''', NULL, "
            "TIMESTAMP '2026-01-01 00:00:00')")
        mismatched = execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('f3_verify')")
        if not any(str(row[3]) == "SEMANTIC_MODEL_042" for row in mismatched):
            raise AssertionError(f"mismatched F3 predicate was not rejected: {mismatched}")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE("
            "'f3_verify', 'orders', 'cold', "
            "'o.order_ts < TIMESTAMP ''2026-01-01 00:00:00''', NULL, "
            "TIMESTAMP '2026-01-01 00:00:00')")

        issues = execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('f3_verify')")
        errors = [row for row in issues if str(row[0]).upper() == "ERROR"]
        if errors:
            raise AssertionError(f"F3 model validation failed: {errors}")

        payload = json.dumps({
            "model": "f3_verify",
            "object": "SALES",
            "metrics": ["total_amount"],
            "dimensions": ["order_status"],
            "proof_mode": "STRICT_GRAIN",
        }, separators=(",", ":"))
        compiled = execute(
            con,
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(payload)})",
        )[0]
        if compiled[0] != "OK":
            raise AssertionError(f"F3 compilation failed: {compiled}")
        generated_sql = str(compiled[4])
        plan = json.loads(str(compiled[5]))
        if generated_sql.count("UNION ALL") != 1:
            raise AssertionError(f"expected one partition UNION ALL: {generated_sql}")
        if '"F3_VERIFY"."ORDERS_COLD"' not in generated_sql:
            raise AssertionError("cold source missing from generated SQL")
        if '"F3_VERIFY"."ORDERS_HOT"' not in generated_sql:
            raise AssertionError("hot source missing from generated SQL")
        fusion = plan["logical_plan"]["physical_plan"]["fusion_plan"]
        if fusion["strategy"] != "UNION" or len(fusion["partitions"]) != 2:
            raise AssertionError(f"unexpected fusion provenance: {fusion}")

        rows = execute(con, generated_sql)
        actual = {str(status): float(amount) for status, amount in rows}
        expected = {"CLOSED": 40.0, "OPEN": 60.0}
        if actual != expected:
            raise AssertionError(f"F3 result mismatch: expected {expected}, got {actual}")
        print("ok F3 mismatch: SEMANTIC_MODEL_042")
        print("ok F3 validation: 0 errors")
        print("ok F3 plan: 2 covered representation partitions")
        print(f"ok F3 rows: {actual}")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f3_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS F3_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
