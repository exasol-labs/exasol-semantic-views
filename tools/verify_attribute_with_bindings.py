#!/usr/bin/env python3
"""Verify atomic dimension/fact creation across heterogeneous representations."""

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
        dsn=(
            f"{os.environ.get('EXASOL_HOST', 'localhost')}:"
            f"{os.environ.get('EXASOL_PORT', '8563')}"
        ),
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


def bindings(expression: str) -> str:
    return literal(
        json.dumps(
            [
                {
                    "representation_name": "crm",
                    "source_expression": expression,
                    "binding_role": "FALLBACK",
                    "binding_priority": 1,
                }
            ],
            separators=(",", ":"),
        )
    )


def assert_result(
    rows: list[tuple[Any, ...]], attribute_type: str, attribute_name: str
) -> None:
    if len(rows) != 1 or len(rows[0]) != 6:
        raise AssertionError(f"unexpected compound result shape: {rows}")
    row = rows[0]
    if str(row[3]) != attribute_type or str(row[4]) != attribute_name:
        raise AssertionError(f"unexpected compound result identity: {row}")
    if int(row[5]) != 2:
        raise AssertionError(f"expected two bindings, got: {row}")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug37_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS BUG37_VERIFY CASCADE")
        con.execute("CREATE SCHEMA BUG37_VERIFY")
        con.execute(
            "CREATE TABLE BUG37_VERIFY.CUSTOMERS_PRIMARY ("
            "CUSTOMER_ID DECIMAL(18,0), CUSTOMER_NAME VARCHAR(100), "
            "CITY VARCHAR(100), AMOUNT DECIMAL(18,2))"
        )
        con.execute(
            "CREATE TABLE BUG37_VERIFY.CUSTOMERS_CRM ("
            "CUSTOMER_ID DECIMAL(18,0), CUSTOMER_NAME VARCHAR(100), "
            "ALT_AMOUNT DECIMAL(18,2))"
        )
        con.execute(
            "INSERT INTO BUG37_VERIFY.CUSTOMERS_PRIMARY VALUES "
            "(1, 'Alice', 'Copenhagen', 10), (2, 'Bob', 'Malmo', 20)"
        )
        con.execute(
            "INSERT INTO BUG37_VERIFY.CUSTOMERS_CRM VALUES "
            "(1, 'Alice', 11), (2, 'Bob', 22)"
        )

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('bug37_verify', "
            "'SEMANTIC_BUG37_VERIFY', 'BUG-37 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('bug37_verify', 'customer', "
            "'BUG37_VERIFY', 'CUSTOMERS_PRIMARY', 'c', 'c.customer_id', "
            "'One customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('bug37_verify', "
            "'customer', 'customer_pk', 'PRIMARY', 'Customer key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('bug37_verify', "
            "'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('bug37_verify', "
            "'CUSTOMERS', 'customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('bug37_verify', "
            "'CUSTOMERS', 'customer', 'customer_name', 'c.customer_name', "
            "'VARCHAR(100)', 'Customer Name', 'Customer name', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION("
            "'bug37_verify', 'customer', 'crm', 'RELATION', 'BUG37_VERIFY', "
            "'CUSTOMERS_CRM', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug37_verify')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('bug37_verify')",
        ]
        for statement in setup:
            execute(con, statement)

        dimension_rows = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION_WITH_BINDINGS("
            "'bug37_verify', 'CUSTOMERS', 'customer', 'customer_city', "
            "'c.city', 'VARCHAR(100)', 'Customer City', 'Warehouse city', "
            f"NULL, TRUE, {bindings('NULL')})",
        )
        assert_result(dimension_rows, "DIMENSION", "customer_city")

        fact_rows = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT_WITH_BINDINGS("
            "'bug37_verify', 'customer', 'customer_amount', 'c.amount', "
            "'DECIMAL(18,2)', 'ADDITIVE', 'Customer Amount', 'Amount', "
            f"FALSE, TRUE, {bindings('c.alt_amount')})",
        )
        assert_result(fact_rows, "FACT", "customer_amount")

        catalog_rows = execute(
            con,
            "SELECT ATTRIBUTE_NAME, COUNT(*) "
            "FROM SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS "
            "WHERE MODEL_NAME = 'bug37_verify' "
            "AND ATTRIBUTE_NAME IN ('customer_city', 'customer_amount') "
            "GROUP BY ATTRIBUTE_NAME ORDER BY ATTRIBUTE_NAME",
        )
        if catalog_rows != [("customer_amount", 2), ("customer_city", 2)]:
            raise AssertionError(f"unexpected attribute bindings: {catalog_rows}")

        validation = execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('bug37_verify')"
        )
        errors = [row for row in validation if str(row[0]) == "ERROR"]
        if errors:
            raise AssertionError(f"compound attributes invalidated model: {errors}")

        invalid = (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION_WITH_BINDINGS("
            "'bug37_verify', 'CUSTOMERS', 'customer', 'invalid_city', "
            "'c.city', 'VARCHAR(100)', 'Invalid City', 'Invalid binding', "
            f"NULL, TRUE, {bindings('c.missing_city')})"
        )
        try:
            execute(con, invalid)
        except Exception as exc:
            if "SEMANTIC_ADMIN_091" not in str(exc):
                raise AssertionError(f"unexpected rejection: {exc}") from exc
        else:
            raise AssertionError("invalid compound dimension was accepted")
        residual = execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.DIMENSIONS "
            "WHERE MODEL_NAME = 'bug37_verify' AND DIMENSION_NAME = 'invalid_city'",
        )[0][0]
        if int(residual) != 0:
            raise AssertionError("invalid compound dimension left catalog residue")

        print("ok BUG-37 wrappers: dimension and fact calls returned success rows")
        print("ok BUG-37 bindings: heterogeneous expressions were committed atomically")
        print("ok BUG-37 rollback: invalid candidate left no catalog residue")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('bug37_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS BUG37_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
