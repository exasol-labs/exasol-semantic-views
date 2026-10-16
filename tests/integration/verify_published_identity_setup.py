#!/usr/bin/env python3
"""Verify complete F5 identity setup is reachable on a published model."""

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


def surface(con: Any) -> list[tuple[str]]:
    return [
        (str(name),)
        for (name,) in execute(
            con,
            "SELECT customer_name FROM SEMANTIC_BUG30_VERIFY.CUSTOMERS "
            "ORDER BY customer_name",
        )
    ]


def expect_error(con: Any, sql: str, code: str) -> None:
    try:
        execute(con, sql)
    except Exception as exc:
        if code not in str(exc):
            raise AssertionError(f"expected {code}, got: {exc}") from exc
    else:
        raise AssertionError("incomplete published identity declaration was accepted")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug30_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG30_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG30_VERIFY")
        con.execute(
            "CREATE TABLE BUG30_VERIFY.CUSTOMERS_PRIMARY ("
            "CUSTOMER_ID DECIMAL(18,0), CUSTOMER_NAME VARCHAR(100))"
        )
        con.execute(
            "CREATE TABLE BUG30_VERIFY.CUSTOMERS_ALTERNATE LIKE "
            "BUG30_VERIFY.CUSTOMERS_PRIMARY"
        )
        for table in ("CUSTOMERS_PRIMARY", "CUSTOMERS_ALTERNATE"):
            con.execute(
                f"INSERT INTO BUG30_VERIFY.{table} VALUES (1, 'Alice'), (2, 'Bob')"
            )

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug30_verify', "
            "'SEMANTIC_BUG30_VERIFY', 'BUG-30 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug30_verify', 'customer', "
            "'BUG30_VERIFY', 'CUSTOMERS_PRIMARY', 'c', 'c.customer_id', "
            "'One customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug30_verify', 'customer', "
            "'customer_pk', 'PRIMARY', 'Customer key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug30_verify', "
            "'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug30_verify', "
            "'CUSTOMERS', 'customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug30_verify', 'CUSTOMERS', "
            "'customer', 'customer_name', 'c.customer_name', 'VARCHAR(100)', "
            "'Customer Name', 'Customer name', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('bug30_verify', "
            "'customer', 'alternate', 'RELATION', 'BUG30_VERIFY', "
            "'CUSTOMERS_ALTERNATE', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('bug30_verify', "
            "'DIMENSION', 'customer_name', 'alternate', 'c.customer_name', "
            "'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug30_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug30_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        ]
        for statement in setup:
            execute(con, statement)

        expected = [("Alice",), ("Bob",)]
        if surface(con) != expected:
            raise AssertionError("unexpected published baseline")

        ordinary = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY("
            "'bug30_verify', 'customer', 'customer_identity', 'GLOBAL', "
            "'DECIMAL(18,0)', 'Certified customer identity')"
        )
        expect_error(con, ordinary, "SEMANTIC_ADMIN_094")
        if surface(con) != expected:
            raise AssertionError("rejected incomplete identity decertified the surface")

        bindings = literal(
            json.dumps(
                [
                    {
                        "representation_name": "primary",
                        "source_expression": "c.customer_id",
                        "binding_kind": "DIRECT",
                    },
                    {
                        "representation_name": "alternate",
                        "source_expression": "c.customer_id",
                        "binding_kind": "DIRECT",
                    },
                ],
                separators=(",", ":"),
            )
        )
        rows = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY_WITH_BINDINGS("
            "'bug30_verify', 'customer', 'customer_identity', 'GLOBAL', "
            f"'DECIMAL(18,0)', 'Certified customer identity', {bindings})",
        )
        if len(rows) != 2:
            raise AssertionError(f"expected two identity bindings, got: {rows}")
        if surface(con) != expected:
            raise AssertionError("complete identity declaration decertified the surface")

        invalid_bindings = literal(
            json.dumps(
                [
                    {
                        "representation_name": "primary",
                        "source_expression": "c.customer_id",
                        "binding_kind": "DIRECT",
                    },
                    {
                        "representation_name": "alternate",
                        "source_expression": "c.missing_id",
                        "binding_kind": "DIRECT",
                    },
                ],
                separators=(",", ":"),
            )
        )
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING("
            "'bug30_verify', 'customer_identity', 'alternate')")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING("
            "'bug30_verify', 'customer_identity', 'primary')")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY("
            "'bug30_verify', 'customer', 'customer_identity')")
        expect_error(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY_WITH_BINDINGS("
            "'bug30_verify', 'customer', 'bad_identity', 'GLOBAL', "
            f"'DECIMAL(18,0)', 'Invalid identity', {invalid_bindings})",
            "SEMANTIC_ADMIN_094",
        )
        residual = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.SEMANTIC_IDENTITIES "
            "WHERE MODEL_NAME = 'bug30_verify'",
        )[0][0]
        if int(residual) != 0:
            raise AssertionError(f"invalid identity left {residual} catalog row(s)")
        if surface(con) != expected:
            raise AssertionError("invalid complete declaration changed the surface")

        print("ok BUG-30 control: incomplete published identity was rejected safely")
        print("ok BUG-30 compound: complete two-representation identity was accepted")
        print("ok BUG-30 rollback: invalid complete identity left no catalog rows")
        print("ok BUG-30 availability: published surface remained certified")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug30_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG30_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
