#!/usr/bin/env python3
"""Verify F5.1 relationship-aware DIRECT identity routing against Exasol."""

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
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f51_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS F51_VERIFY CASCADE")
        con.execute("CREATE SCHEMA F51_VERIFY")
        con.execute("""
            CREATE TABLE F51_VERIFY.ORDERS (
              ORDER_ID DECIMAL(18,0), CUSTOMER_ID DECIMAL(18,0)
            )
        """)
        con.execute("""
            CREATE TABLE F51_VERIFY.CUSTOMERS_MDM (
              CUSTOMER_ID DECIMAL(18,0), REGION VARCHAR(50)
            )
        """)
        con.execute('''
            CREATE TABLE F51_VERIFY.CUSTOMERS_MONGO (
              "customer_id" DECIMAL(10,0), "region" VARCHAR(50)
            )
        ''')
        con.execute(
            "INSERT INTO F51_VERIFY.ORDERS VALUES (101, 1), (102, 2), (103, 2)"
        )
        con.execute(
            "INSERT INTO F51_VERIFY.CUSTOMERS_MDM VALUES "
            "(1, 'MDM-North'), (2, 'MDM-West')"
        )
        con.execute('''
            INSERT INTO F51_VERIFY.CUSTOMERS_MONGO VALUES
              (1, 'North'), (2, 'West')
        ''')

        statements = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('f51_verify', 'SEMANTIC_F51_VERIFY', 'F5.1 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('f51_verify', 'orders', 'F51_VERIFY', 'ORDERS', 'o', 'o.order_id', 'One order', 'Orders')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('f51_verify', 'customer', 'F51_VERIFY', 'CUSTOMERS_MDM', 'c', 'c.customer_id', 'One customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('f51_verify', 'customer', 'customer_pk', 'PRIMARY', 'Customer identity', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('f51_verify', 'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('f51_verify', 'SALES', 'orders', 'Sales')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP('f51_verify', 'orders_customer', 'orders', 'customer', 'o.CUSTOMER_ID = c.CUSTOMER_ID', 'MANY_TO_ONE', 'LEFT', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING('f51_verify', 'orders_customer', 'CUSTOMER_ID', NULL, 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('f51_verify', 'SALES', 'customer', 'customer_region', 'c.region', 'VARCHAR(50)', 'Customer Region', 'Customer region', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('f51_verify', 'customer', 'mongo', 'RELATION', 'F51_VERIFY', 'CUSTOMERS_MONGO', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ATTRIBUTE_BINDING('f51_verify', 'DIMENSION', 'customer_region', 'primary')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('f51_verify', 'DIMENSION', 'customer_region', 'primary', 'c.region', 'FALLBACK', 20)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('f51_verify', 'DIMENSION', 'customer_region', 'mongo', 'c.\"region\"', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY('f51_verify', 'customer', 'customer_identity', 'GLOBAL', 'DECIMAL(18,0)', 'Customer identity')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('f51_verify', 'customer_identity', 'primary', 'c.CUSTOMER_ID', 'DIRECT')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('f51_verify', 'customer_identity', 'mongo', 'CAST(c.\"customer_id\" AS DECIMAL(18,0))', 'DIRECT')",
        ]
        for statement in statements:
            execute(con, statement)

        issues = execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('f51_verify')"
        )
        errors = [row for row in issues if str(row[0]).upper() == "ERROR"]
        if errors:
            raise AssertionError(f"valid F5.1 model failed: {errors}")

        payload = json.dumps(
            {
                "model": "f51_verify",
                "object": "SALES",
                "dimensions": ["customer_region"],
                "proof_mode": "STRICT_GRAIN",
            },
            separators=(",", ":"),
        )
        compiled = execute(
            con,
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(payload)})",
        )[0]
        if compiled[0] != "OK":
            raise AssertionError(f"F5.1 compilation failed: {compiled}")
        generated_sql = str(compiled[4])
        expected_join = 'o.CUSTOMER_ID = CAST(c."customer_id" AS DECIMAL(18,0))'
        if expected_join not in generated_sql:
            raise AssertionError(
                f"relationship endpoint was not rewritten: {generated_sql}"
            )
        if '"F51_VERIFY"."CUSTOMERS_MONGO" c' not in generated_sql:
            raise AssertionError(
                f"alternate representation was not selected: {generated_sql}"
            )
        rows = sorted(str(row[0]) for row in execute(con, generated_sql))
        if rows != ["North", "West"]:
            raise AssertionError(f"rewritten relationship result mismatch: {rows}")

        plan = json.loads(str(compiled[5]))
        remaps = plan.get("relationship_identity_remaps", [])
        if len(remaps) != 1:
            raise AssertionError(f"expected one relationship remap: {remaps}")
        remap = remaps[0]
        expected = {
            "relationship_name": "orders_customer",
            "side": "to",
            "representation_name": "mongo",
            "semantic_identity_name": "customer_identity",
        }
        for field, value in expected.items():
            if remap.get(field) != value:
                raise AssertionError(f"incorrect {field} provenance: {remap}")
        if not remap.get("identity_binding_id") or not remap.get("unique_key_id"):
            raise AssertionError(f"incomplete F5.1 provenance: {remap}")

        print("ok F5.1 selection: relationship-compatible alternate")
        print("ok F5.1 SQL: DIRECT identity endpoint rewrite executed")
        print("ok F5.1 provenance: relationship, side, key, identity, binding")
        print(f"ok F5.1 rows: {rows}")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f51_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS F51_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
