#!/usr/bin/env python3
"""Verify BUG-24 prospective promotion checks and trapped-state recovery."""

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


def expect_failure(con: Any, sql: str, fragment: str) -> None:
    try:
        execute(con, sql)
    except Exception as exc:
        if fragment not in str(exc):
            raise AssertionError(f"expected {fragment}, got: {exc}") from exc
        return
    raise AssertionError(f"expected failure containing {fragment}")


def roles(con: Any) -> list[tuple[Any, ...]]:
    return execute(
        con,
        "SELECT er.REPRESENTATION_NAME, er.REPRESENTATION_ROLE "
        "FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er "
        "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = er.MODEL_ID "
        "JOIN SYS_SEMANTIC.ENTITIES e ON e.ENTITY_ID = er.ENTITY_ID "
        "WHERE m.MODEL_NAME = 'bug24_verify' "
        "AND e.ENTITY_NAME = 'customer' "
        "ORDER BY er.REPRESENTATION_NAME",
    )


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug24_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG24_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG24_VERIFY")
        con.execute("""
            CREATE TABLE BUG24_VERIFY.ORDERS (
              ORDER_ID DECIMAL(18,0), CUSTOMER_ID DECIMAL(18,0)
            )
        """)
        con.execute("""
            CREATE TABLE BUG24_VERIFY.CUSTOMERS_PRIMARY (
              CUSTOMER_ID DECIMAL(18,0)
            )
        """)
        con.execute('''
            CREATE TABLE BUG24_VERIFY.CUSTOMERS_ALT (
              "customer_id" DECIMAL(10,0)
            )
        ''')
        con.execute("""
            CREATE TABLE BUG24_VERIFY.CUSTOMERS_EXPR (
              CUSTOMER_ID DECIMAL(18,0)
            )
        """)
        con.execute("INSERT INTO BUG24_VERIFY.ORDERS VALUES (10, 1), (20, 2)")
        con.execute("INSERT INTO BUG24_VERIFY.CUSTOMERS_PRIMARY VALUES (1), (2)")
        con.execute('INSERT INTO BUG24_VERIFY.CUSTOMERS_ALT VALUES (1), (2)')
        con.execute("INSERT INTO BUG24_VERIFY.CUSTOMERS_EXPR VALUES (1), (2)")

        statements = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug24_verify', 'SEMANTIC_BUG24_VERIFY', 'BUG-24 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug24_verify', 'orders', 'BUG24_VERIFY', 'ORDERS', 'o', 'o.ORDER_ID', 'One order', 'Orders')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug24_verify', 'customer', 'BUG24_VERIFY', 'CUSTOMERS_PRIMARY', 'c', 'c.CUSTOMER_ID', 'One customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug24_verify', 'customer', 'customer_pk', 'PRIMARY', 'Customer key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug24_verify', 'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug24_verify', 'SALES', 'orders', 'Sales')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP('bug24_verify', 'orders_customer', 'orders', 'customer', 'o.CUSTOMER_ID = c.CUSTOMER_ID', 'MANY_TO_ONE', 'LEFT', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING('bug24_verify', 'orders_customer', 'CUSTOMER_ID', NULL, 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('bug24_verify', 'customer', 'alternate', 'RELATION', 'BUG24_VERIFY', 'CUSTOMERS_ALT', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('bug24_verify', 'customer', 'expression_bound', 'RELATION', 'BUG24_VERIFY', 'CUSTOMERS_EXPR', 30, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('bug24_verify', 'customer', 'direct_alternate', 'RELATION', 'BUG24_VERIFY', 'CUSTOMERS_EXPR', 40, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY('bug24_verify', 'customer', 'customer_identity', 'GLOBAL', 'DECIMAL(18,0)', 'Customer identity')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('bug24_verify', 'customer_identity', 'primary', 'c.CUSTOMER_ID', 'DIRECT')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('bug24_verify', 'customer_identity', 'alternate', 'CAST(c.\"customer_id\" AS DECIMAL(18,0))', 'DIRECT')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('bug24_verify', 'customer_identity', 'expression_bound', 'CAST(c.CUSTOMER_ID AS DECIMAL(18,0))', 'DIRECT')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('bug24_verify', 'customer_identity', 'direct_alternate', 'c.CUSTOMER_ID', 'DIRECT')",
        ]
        for statement in statements:
            execute(con, statement)

        issues = execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug24_verify')"
        )
        errors = [row for row in issues if str(row[0]).upper() == "ERROR"]
        if errors:
            raise AssertionError(f"BUG-24 fixture is not initially valid: {errors}")

        promote_alt = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION("
            "'bug24_verify', 'customer', 'alternate')"
        )
        expect_failure(con, promote_alt, "SEMANTIC_ADMIN_058")
        expected_roles = [("alternate", "ALTERNATE"),
                          ("direct_alternate", "ALTERNATE"),
                          ("expression_bound", "ALTERNATE"),
                          ("primary", "PRIMARY")]
        if roles(con) != expected_roles:
            raise AssertionError(f"rejected promotion changed roles: {roles(con)}")
        mirror = execute(
            con,
            "SELECT e.SOURCE_OBJECT FROM SYS_SEMANTIC.ENTITIES e "
            "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = e.MODEL_ID "
            "WHERE m.MODEL_NAME = 'bug24_verify' AND e.ENTITY_NAME = 'customer'",
        )[0][0]
        if mirror != "CUSTOMERS_PRIMARY":
            raise AssertionError(f"rejected promotion changed entity mirror: {mirror}")

        expect_failure(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION("
            "'bug24_verify', 'customer', 'expression_bound')",
            "bare DIRECT identity binding",
        )
        if roles(con) != expected_roles:
            raise AssertionError(
                f"expression-bound rejection changed roles: {roles(con)}"
            )

        con.execute("""
            UPDATE SYS_SEMANTIC.VALIDATION_RUNS
            SET STATUS = 'STALE'
            WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS
                              WHERE MODEL_NAME = 'bug24_verify')
              AND ERROR_COUNT = 0
              AND STATUS IN ('OK', 'WARNING')
        """)
        expect_failure(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION("
            "'bug24_verify', 'customer', 'direct_alternate')",
            "SEMANTIC_ADMIN_048",
        )
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug24_verify')")

        # Recreate the state left by the pre-fix implementation and prove that
        # a clean validation run marked STALE remains usable recovery evidence.
        con.execute("""
            UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
            SET REPRESENTATION_ROLE = CASE
              WHEN REPRESENTATION_NAME = 'alternate' THEN 'PRIMARY' ELSE 'ALTERNATE' END
            WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS
                              WHERE MODEL_NAME = 'bug24_verify')
              AND ENTITY_ID = (SELECT e.ENTITY_ID FROM SYS_SEMANTIC.ENTITIES e
                               JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = e.MODEL_ID
                               WHERE m.MODEL_NAME = 'bug24_verify'
                                 AND e.ENTITY_NAME = 'customer')
        """)
        con.execute("""
            UPDATE SYS_SEMANTIC.ENTITIES
            SET SOURCE_OBJECT = 'CUSTOMERS_ALT'
            WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS
                              WHERE MODEL_NAME = 'bug24_verify')
              AND ENTITY_NAME = 'customer'
        """)
        con.execute("""
            UPDATE SYS_SEMANTIC.VALIDATION_RUNS
            SET STATUS = 'STALE'
            WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS
                              WHERE MODEL_NAME = 'bug24_verify')
              AND ERROR_COUNT = 0
              AND STATUS IN ('OK', 'WARNING')
        """)
        broken = execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug24_verify')"
        )
        if not any(str(row[0]).upper() == "ERROR" for row in broken):
            raise AssertionError("simulated trapped state unexpectedly validated")

        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION("
            "'bug24_verify', 'customer', 'primary')",
        )
        recovered = execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug24_verify')"
        )
        recovery_errors = [row for row in recovered if str(row[0]).upper() == "ERROR"]
        if recovery_errors:
            raise AssertionError(f"canonical recovery failed: {recovery_errors}")

        print("ok BUG-24 gate: invalid prospective primary rejected before mutation")
        print("ok BUG-24 diagnostics: SEMANTIC_ADMIN_058 names canonical key remedy")
        print("ok BUG-24 stale evidence: unrelated STALE run remains insufficient")
        print("ok BUG-24 recovery: STALE clean run permits canonical rollback")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug24_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG24_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
