#!/usr/bin/env python3
"""Verify heterogeneous F5 representation registration on a published model."""

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


def expect_error(con: Any, sql: str, code: str) -> str:
    try:
        execute(con, sql)
    except Exception as exc:
        message = str(exc)
        if code not in message:
            raise AssertionError(f"expected {code}, got: {exc}") from exc
        return message
    else:
        raise AssertionError("invalid published representation candidate was accepted")


def surface(con: Any) -> list[tuple[str]]:
    return [
        (str(name),)
        for (name,) in execute(
            con,
            "SELECT customer_name FROM SEMANTIC_BUG31_VERIFY.CUSTOMERS "
            "ORDER BY customer_name",
        )
    ]


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug31_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG31_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG31_VERIFY")
        con.execute(
            "CREATE TABLE BUG31_VERIFY.CUSTOMERS_PRIMARY ("
            "CUSTOMER_ID DECIMAL(18,0), CUSTOMER_NAME VARCHAR(100), "
            "CUSTOMER_TIER VARCHAR(20), CUSTOMER_COUNTRY VARCHAR(2))"
        )
        con.execute(
            'CREATE TABLE BUG31_VERIFY.CUSTOMERS_EXTERNAL ('
            '"external_id" DECIMAL(10,0), CUSTOMER_NAME VARCHAR(100), '
            "CUSTOMER_TIER VARCHAR(20), CUSTOMER_COUNTRY VARCHAR(2))"
        )
        con.execute(
            'CREATE TABLE BUG31_VERIFY.CUSTOMERS_INCOMPLETE ('
            '"external_id" DECIMAL(10,0))'
        )
        con.execute(
            "INSERT INTO BUG31_VERIFY.CUSTOMERS_PRIMARY VALUES "
            "(1, 'Alice', 'GOLD', 'DK'), (2, 'Bob', 'SILVER', 'SE')"
        )
        con.execute(
            "INSERT INTO BUG31_VERIFY.CUSTOMERS_EXTERNAL VALUES "
            "(1, 'Alice', 'GOLD', 'DK'), (2, 'Bob', 'SILVER', 'SE')"
        )
        con.execute(
            'INSERT INTO BUG31_VERIFY.CUSTOMERS_INCOMPLETE ("external_id") '
            "VALUES (1), (2)"
        )

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug31_verify', "
            "'SEMANTIC_BUG31_VERIFY', 'BUG-31 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug31_verify', 'customer', "
            "'BUG31_VERIFY', 'CUSTOMERS_PRIMARY', 'c', 'c.customer_id', "
            "'One customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug31_verify', 'customer', "
            "'customer_pk', 'PRIMARY', 'Customer key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug31_verify', "
            "'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug31_verify', "
            "'CUSTOMERS', 'customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug31_verify', 'CUSTOMERS', "
            "'customer', 'customer_name', 'c.customer_name', 'VARCHAR(100)', "
            "'Customer Name', 'Customer name', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug31_verify', 'CUSTOMERS', "
            "'customer', 'customer_tier', 'c.customer_tier', 'VARCHAR(20)', "
            "'Customer Tier', 'Customer tier', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug31_verify', 'CUSTOMERS', "
            "'customer', 'customer_country', 'c.customer_country', 'VARCHAR(2)', "
            "'Customer Country', 'Customer country', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY('bug31_verify', "
            "'customer', 'customer_identity', 'GLOBAL', 'DECIMAL(18,0)', "
            "'Certified customer identity')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('bug31_verify', "
            "'customer_identity', 'primary', 'c.customer_id', 'DIRECT')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug31_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug31_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()",
        ]
        for statement in setup:
            execute(con, statement)

        expected = [("Alice",), ("Bob",)]
        if surface(con) != expected:
            raise AssertionError("unexpected published baseline")

        ordinary = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION("
            "'bug31_verify', 'customer', 'external', 'RELATION', "
            "'BUG31_VERIFY', 'CUSTOMERS_EXTERNAL', 20, 'MANUAL')"
        )
        expect_error(con, ordinary, "SEMANTIC_ADMIN_094")
        if surface(con) != expected:
            raise AssertionError("rejected ordinary registration changed the surface")

        rows = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING("
            "'bug31_verify', 'customer', 'external', 'RELATION', "
            "'BUG31_VERIFY', 'CUSTOMERS_EXTERNAL', 20, 'MANUAL', "
            "'customer_identity', 'CAST(c.\"external_id\" AS DECIMAL(18,0))', "
            "'DIRECT', NULL)",
        )
        if len(rows) != 1 or str(rows[0][7]) != "DIRECT":
            raise AssertionError(f"unexpected compound result: {rows}")
        binding_count = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS "
            "WHERE MODEL_NAME = 'bug31_verify' "
            "AND REPRESENTATION_NAME = 'external'",
        )[0][0]
        if int(binding_count) != 3:
            raise AssertionError(
                f"compound representation generated {binding_count} attribute binding(s)"
            )
        if surface(con) != expected:
            raise AssertionError("compound representation changed the surface")

        incomplete = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING("
            "'bug31_verify', 'customer', 'incomplete', 'RELATION', "
            "'BUG31_VERIFY', 'CUSTOMERS_INCOMPLETE', 30, 'MANUAL', "
            "'customer_identity', 'CAST(c.\"external_id\" AS DECIMAL(18,0))', "
            "'DIRECT', NULL)"
        )
        incomplete_error = expect_error(con, incomplete, "SEMANTIC_ADMIN_094")
        for dimension in ("customer_name", "customer_tier", "customer_country"):
            if dimension not in incomplete_error:
                raise AssertionError(
                    f"compound rejection did not name {dimension}: {incomplete_error}"
                )

        invalid = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING("
            "'bug31_verify', 'customer', 'external_bad', 'RELATION', "
            "'BUG31_VERIFY', 'CUSTOMERS_EXTERNAL', 40, 'MANUAL', "
            "'customer_identity', 'c.missing_id', 'DIRECT', NULL)"
        )
        expect_error(con, invalid, "SEMANTIC_ADMIN_094")
        residual = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS "
            "WHERE MODEL_NAME = 'bug31_verify' "
            "AND REPRESENTATION_NAME = 'external_bad'",
        )[0][0]
        if int(residual) != 0:
            raise AssertionError(f"invalid representation left {residual} catalog row(s)")
        if surface(con) != expected:
            raise AssertionError("invalid compound candidate changed the surface")

        print("ok BUG-31 control: heterogeneous ordinary registration was rejected safely")
        print("ok BUG-31 compound: representation and DIRECT identity binding were accepted")
        print("ok BUG-35 bindings: governed attribute bindings were generated atomically")
        print("ok BUG-35 diagnostics: every incompatible attribute was reported")
        print("ok BUG-31 rollback: invalid complete candidate left no catalog rows")
        print("ok BUG-31 availability: published surface remained certified")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug31_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG31_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
