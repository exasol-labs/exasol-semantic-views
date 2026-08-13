#!/usr/bin/env python3
"""Verify F4 authority and row-level reconciliation against Exasol."""

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


def compile_names(con: Any) -> tuple[list[str], dict[str, Any], str]:
    payload = json.dumps(
        {
            "model": "f4_verify",
            "object": "CUSTOMER_360",
            "dimensions": ["customer_name"],
            "proof_mode": "STRICT_GRAIN",
        },
        separators=(",", ":"),
    )
    compiled = execute(
        con,
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(payload)})",
    )[0]
    if compiled[0] != "OK":
        raise AssertionError(f"F4 compilation failed: {compiled}")
    generated_sql = str(compiled[4])
    rows = execute(con, generated_sql)
    return sorted(str(row[0]) for row in rows), json.loads(str(compiled[5])), generated_sql


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f4_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS F4_VERIFY CASCADE")
        con.execute("CREATE SCHEMA F4_VERIFY")
        con.execute("""
            CREATE TABLE F4_VERIFY.CUSTOMERS_MDM (
              CUSTOMER_ID DECIMAL(18,0), CUSTOMER_NAME VARCHAR(100)
            )
        """)
        con.execute("""
            CREATE TABLE F4_VERIFY.CUSTOMERS_CRM (
              CUSTOMER_ID DECIMAL(18,0), CUSTOMER_NAME VARCHAR(100),
              DISPLAY_NAME VARCHAR(100)
            )
        """)
        con.execute("""
            INSERT INTO F4_VERIFY.CUSTOMERS_MDM VALUES
              (1, 'Alice'), (2, NULL), (3, 'Carol')
        """)
        con.execute("""
            INSERT INTO F4_VERIFY.CUSTOMERS_CRM VALUES
              (1, 'Alice', 'Alice'), (2, 'Bob', 'Bob'), (3, 'Carol', 'Carol')
        """)

        statements = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('f4_verify', 'SEMANTIC_F4_VERIFY', 'F4 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('f4_verify', 'customer', 'F4_VERIFY', 'CUSTOMERS_MDM', 'c', 'c.customer_id', 'One customer', 'Customer 360')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('f4_verify', 'customer', 'customer_pk', 'PRIMARY', 'Customer identity', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('f4_verify', 'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('f4_verify', 'CUSTOMER_360', 'customer', 'Customer 360')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('f4_verify', 'CUSTOMER_360', 'customer', 'customer_name', 'c.customer_name', 'VARCHAR(100)', 'Customer Name', 'Resolved customer name', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('f4_verify', 'customer', 'crm', 'RELATION', 'F4_VERIFY', 'CUSTOMERS_CRM', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('f4_verify', 'DIMENSION', 'customer_name', 'crm', 'c.display_name', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY('f4_verify', 'customer', 'primary', 'PREFER')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY('f4_verify', 'customer', 'crm', 'SUPPLEMENTAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY('f4_verify', 'DIMENSION', 'customer_name', 'COALESCE')",
        ]
        for statement in statements:
            execute(con, statement)

        issues = execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('f4_verify')")
        errors = [row for row in issues if str(row[0]).upper() == "ERROR"]
        if errors:
            raise AssertionError(f"valid F4 COALESCE model failed: {errors}")
        names, plan, generated_sql = compile_names(con)
        if names != ["Alice", "Bob", "Carol"]:
            raise AssertionError(f"F4 COALESCE result mismatch: {names}")
        if "COALESCE(" not in generated_sql or '"F4_VERIFY"."CUSTOMERS_CRM"' not in generated_sql:
            raise AssertionError(f"F4 keyed fallback missing from SQL: {generated_sql}")

        con.execute("UPDATE F4_VERIFY.CUSTOMERS_CRM SET DISPLAY_NAME = 'Caroline' WHERE CUSTOMER_ID = 3")
        conflicts = execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('f4_verify')")
        if not any(str(row[3]) == "SEMANTIC_MODEL_045" for row in conflicts):
            raise AssertionError(f"COALESCE conflict was not rejected: {conflicts}")

        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY(" 
            "'f4_verify', 'customer', 'primary', 'AUTHORITATIVE')")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY("
            "'f4_verify', 'DIMENSION', 'customer_name', 'RECONCILE')")
        reconciled = execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('f4_verify')")
        if any(str(row[0]).upper() == "ERROR" for row in reconciled):
            raise AssertionError(f"F4 RECONCILE model failed: {reconciled}")
        if not any(str(row[3]) == "SEMANTIC_MODEL_046" for row in reconciled):
            raise AssertionError(f"RECONCILE conflict warning missing: {reconciled}")
        names, plan, _ = compile_names(con)
        if names != ["Alice", "Bob", "Carol"]:
            raise AssertionError(f"F4 authority result mismatch: {names}")
        binding_plan = plan["selected_representations"][0]["selected_bindings"][0]
        if binding_plan["fusion_strategy"] != "RECONCILE":
            raise AssertionError(f"unexpected F4 plan: {binding_plan}")
        contributors = binding_plan["fusion_contributors"]
        if contributors[0]["authority_role"] != "AUTHORITATIVE":
            raise AssertionError(f"authority is not first in provenance: {contributors}")

        print("ok F4 COALESCE: null fallback with agreeing overlap")
        print("ok F4 conflict: SEMANTIC_MODEL_045")
        print("ok F4 RECONCILE: SEMANTIC_MODEL_046 with authoritative result")
        print(f"ok F4 rows: {names}")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f4_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS F4_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
