#!/usr/bin/env python3
"""Verify F5 certified cross-representation identity mapping against Exasol."""

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


def expect_failure(con: Any, sql: str, error_code: str) -> None:
    try:
        execute(con, sql)
    except Exception as exc:
        if error_code not in str(exc):
            raise AssertionError(f"expected {error_code}, got: {exc}") from exc
        return
    raise AssertionError(f"expected {error_code}, statement succeeded")


def validate(con: Any) -> list[tuple[Any, ...]]:
    return execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('f5_verify')")


def compile_names(con: Any) -> tuple[list[str], dict[str, Any], str]:
    payload = json.dumps(
        {
            "model": "f5_verify",
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
        raise AssertionError(f"F5 compilation failed: {compiled}")
    generated_sql = str(compiled[4])
    rows = execute(con, generated_sql)
    return sorted(str(row[0]) for row in rows), json.loads(str(compiled[5])), generated_sql


def lower_case_mapping_case(con: Any) -> tuple[list[str], str]:
    """The same F5 identity graph with the mapping relation declared lower case.

    Everything else is identical to the model below; only the spelling of
    IDENTITY_MAPPING_RELATIONS.SOURCE_LOCAL_COLUMN and SEMANTIC_KEY_COLUMN
    differs. Both used to be quoted verbatim, so `account_id` probed as
    `"account_id"` against a physical `ACCOUNT_ID` and validation refused the
    model with SEMANTIC_MODEL_049 — while the neighbouring
    ADD_UNIQUE_KEY_WITH_COLUMNS accepted either case, so the two APIs disagreed
    with no way to predict it (BUG-G03).

    Reuses the F5_VERIFY schema, so it must run after the physical tables exist.
    """
    try:
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f5_verify_lower')")
    except Exception:  # noqa: BLE001 - absent on the first run
        pass
    for statement in (
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('f5_verify_lower', "
        "'SEMANTIC_F5_VERIFY_LOWER', 'F5 lower-case mapping verification', NULL)",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('f5_verify_lower', 'customer', "
        "'F5_VERIFY', 'CUSTOMERS_MDM', 'c', 'c.customer_id', 'One customer', 'Customer 360')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('f5_verify_lower', 'customer', "
        "'customer_pk', 'PRIMARY', 'MDM customer key', 'NATIVE')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('f5_verify_lower', 'customer', "
        "'customer_pk', 'CUSTOMER_ID', NULL, 1)",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('f5_verify_lower', "
        "'CUSTOMER_360', 'customer', 'Customer 360')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('f5_verify_lower', 'CUSTOMER_360', "
        "'customer', 'customer_name', 'c.customer_name', 'VARCHAR(100)', 'Customer Name', "
        "'Resolved customer name', NULL, TRUE)",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('f5_verify_lower', "
        "'customer', 'crm', 'RELATION', 'F5_VERIFY', 'ACCOUNTS_CRM', 20, 'MANUAL')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('f5_verify_lower', 'DIMENSION', "
        "'customer_name', 'crm', 'c.display_name', 'PREFER', 1)",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY('f5_verify_lower', 'customer', "
        "'customer_identity', 'GLOBAL', 'DECIMAL(18,0)', 'Certified customer identity')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('f5_verify_lower', "
        "'customer_identity', 'primary', 'c.customer_id', 'DIRECT')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('f5_verify_lower', "
        "'customer_identity', 'crm', 'c.account_id', 'MAPPED')",
        # the whole point: declared lower case, physical columns are upper case
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_MAPPING_RELATION('f5_verify_lower', "
        "'customer_identity', 'crm', 'F5_VERIFY', 'CUSTOMER_XREF', 'account_id', "
        "'customer_id', 'CERTIFIED')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY('f5_verify_lower', "
        "'customer', 'primary', 'PREFER')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY('f5_verify_lower', "
        "'customer', 'crm', 'SUPPLEMENTAL')",
        "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY('f5_verify_lower', "
        "'DIMENSION', 'customer_name', 'COALESCE')",
    ):
        execute(con, statement)

    issues = execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('f5_verify_lower')")
    errors = [row for row in issues if str(row[0]).upper() == "ERROR"]
    if errors:
        raise AssertionError(
            f"lower-case mapping model failed validation: {errors}")

    payload = json.dumps(
        {
            "model": "f5_verify_lower",
            "object": "CUSTOMER_360",
            "dimensions": ["customer_name"],
            "proof_mode": "STRICT_GRAIN",
        },
        separators=(",", ":"),
    )
    compiled = execute(
        con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(payload)})")[0]
    if str(compiled[0]) != "OK":
        raise AssertionError(
            f"lower-case mapping compile failed: {compiled[1]} {compiled[2]}")
    generated_sql = str(compiled[4])
    rows = execute(con, generated_sql)
    return sorted(str(row[0]) for row in rows), generated_sql


def has_rule(issues: list[tuple[Any, ...]], rule: str) -> bool:
    return any(str(row[3]) == rule for row in issues)


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('f5_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS F5_VERIFY CASCADE")
        con.execute("CREATE SCHEMA F5_VERIFY")
        con.execute("""
            CREATE TABLE F5_VERIFY.CUSTOMERS_MDM (
              CUSTOMER_ID DECIMAL(18,0), CUSTOMER_NAME VARCHAR(100)
            )
        """)
        con.execute("""
            CREATE TABLE F5_VERIFY.ACCOUNTS_CRM (
              ACCOUNT_ID VARCHAR(20), DISPLAY_NAME VARCHAR(100)
            )
        """)
        con.execute("""
            CREATE TABLE F5_VERIFY.CUSTOMER_XREF (
              ACCOUNT_ID VARCHAR(20), CUSTOMER_ID DECIMAL(18,0)
            )
        """)
        con.execute("""
            INSERT INTO F5_VERIFY.CUSTOMERS_MDM VALUES
              (1, 'Alice'), (2, NULL), (3, 'Carol')
        """)
        con.execute("""
            INSERT INTO F5_VERIFY.ACCOUNTS_CRM VALUES
              ('A-1', 'Alice'), ('A-2', 'Bob'), ('A-3', 'Carol')
        """)
        con.execute("""
            INSERT INTO F5_VERIFY.CUSTOMER_XREF VALUES
              ('A-1', 1), ('A-2', 2), ('A-3', 3)
        """)

        statements = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('f5_verify', 'SEMANTIC_F5_VERIFY', 'F5 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('f5_verify', 'customer', 'F5_VERIFY', 'CUSTOMERS_MDM', 'c', 'c.customer_id', 'One customer', 'Customer 360')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('f5_verify', 'customer', 'customer_pk', 'PRIMARY', 'MDM customer key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('f5_verify', 'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('f5_verify', 'CUSTOMER_360', 'customer', 'Customer 360')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('f5_verify', 'CUSTOMER_360', 'customer', 'customer_name', 'c.customer_name', 'VARCHAR(100)', 'Customer Name', 'Resolved customer name', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('f5_verify', 'customer', 'crm', 'RELATION', 'F5_VERIFY', 'ACCOUNTS_CRM', 20, 'MANUAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING('f5_verify', 'DIMENSION', 'customer_name', 'crm', 'c.display_name', 'PREFER', 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY('f5_verify', 'customer', 'customer_identity', 'GLOBAL', 'DECIMAL(18,0)', 'Certified customer identity')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('f5_verify', 'customer_identity', 'primary', 'c.customer_id', 'DIRECT')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING('f5_verify', 'customer_identity', 'crm', 'c.account_id', 'MAPPED')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_MAPPING_RELATION('f5_verify', 'customer_identity', 'crm', 'F5_VERIFY', 'CUSTOMER_XREF', 'ACCOUNT_ID', 'CUSTOMER_ID', 'CERTIFIED')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY('f5_verify', 'customer', 'primary', 'PREFER')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY('f5_verify', 'customer', 'crm', 'SUPPLEMENTAL')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY('f5_verify', 'DIMENSION', 'customer_name', 'COALESCE')",
        ]
        for statement in statements:
            execute(con, statement)

        issues = validate(con)
        errors = [row for row in issues if str(row[0]).upper() == "ERROR"]
        if errors:
            raise AssertionError(f"valid F5 identity graph failed: {errors}")

        names, plan, generated_sql = compile_names(con)
        if names != ["Alice", "Bob", "Carol"]:
            raise AssertionError(f"F5 result mismatch: {names}")
        if '"F5_VERIFY"."CUSTOMER_XREF"' not in generated_sql:
            raise AssertionError(f"certified identity mapping missing from SQL: {generated_sql}")
        binding_plan = plan["selected_representations"][0]["selected_bindings"][0]
        contributors = binding_plan["fusion_contributors"]
        mapped = next(item for item in contributors if item["representation_name"] == "crm")
        if mapped.get("semantic_identity_name") != "customer_identity":
            raise AssertionError(f"identity provenance missing: {mapped}")
        if not mapped.get("identity_mapping_id"):
            raise AssertionError(f"mapping provenance missing: {mapped}")

        con.execute("DELETE FROM F5_VERIFY.CUSTOMER_XREF WHERE ACCOUNT_ID = 'A-3'")
        incomplete = validate(con)
        if not has_rule(incomplete, "SEMANTIC_MODEL_049"):
            raise AssertionError(f"incomplete mapping was accepted: {incomplete}")
        con.execute("INSERT INTO F5_VERIFY.CUSTOMER_XREF VALUES ('A-3', 3)")

        con.execute("UPDATE F5_VERIFY.CUSTOMER_XREF SET CUSTOMER_ID = 1 WHERE ACCOUNT_ID = 'A-2'")
        non_bijective = validate(con)
        if not has_rule(non_bijective, "SEMANTIC_MODEL_049"):
            raise AssertionError(f"non-bijective mapping was accepted: {non_bijective}")

        con.execute("UPDATE F5_VERIFY.CUSTOMER_XREF SET CUSTOMER_ID = 2 WHERE ACCOUNT_ID = 'A-2'")
        expect_failure(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING("
            "'f5_verify', 'customer_identity', 'crm')",
            "SEMANTIC_ADMIN_054",
        )
        expect_failure(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY("
            "'f5_verify', 'customer', 'customer_identity')",
            "SEMANTIC_ADMIN_056",
        )
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_MAPPING_RELATION("
            "'f5_verify', 'customer_identity', 'crm')")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING("
            "'f5_verify', 'customer_identity', 'crm')")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING("
            "'f5_verify', 'customer_identity', 'primary')")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY("
            "'f5_verify', 'customer', 'customer_identity')")
        remaining = execute(con, """
            SELECT COUNT(*)
            FROM SEMANTIC_CATALOG.SEMANTIC_IDENTITIES
            WHERE MODEL_NAME = 'f5_verify'
        """)[0][0]
        if int(remaining) != 0:
            raise AssertionError(f"semantic identity removal left {remaining} row(s)")

        # BUG-G03: the mapping relation's declared columns were the one pair of
        # declared names that never reached the shared resolver, so a lower-case
        # declaration -- the case a modeller naturally types, and the case
        # ADD_UNIQUE_KEY_WITH_COLUMNS already accepted -- failed validation.
        lower_names, lower_sql = lower_case_mapping_case(con)
        if lower_names != ["Alice", "Bob", "Carol"]:
            raise AssertionError(f"F5 lower-case mapping result mismatch: {lower_names}")
        map_lines = [line for line in lower_sql.splitlines() if "f5_map" in line]
        if not map_lines:
            raise AssertionError(f"no identity mapping join rendered: {lower_sql}")
        joined = " ".join(map_lines)
        if '"account_id"' in joined or '"customer_id"' in joined:
            raise AssertionError(
                f"mapping join quoted the declared spelling verbatim: {joined}")
        if '"ACCOUNT_ID"' not in joined:
            raise AssertionError(
                f"mapping join did not resolve the local key column: {joined}")

        print("ok F5 identity: direct and mapped source-local keys")
        print("ok F5 validation: total, one-to-one canonical mapping")
        print("ok F5 failures: incomplete and non-bijective mappings rejected")
        print("ok F5 lifecycle: dependency guards and ordered removal")
        print(f"ok F5 rows: {names}")
        print(f"ok F5 lower-case mapping columns resolve: {lower_names}")
        return 0
    finally:
        for model in ("f5_verify", "f5_verify_lower"):
            try:
                execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(model)})")
            except Exception:  # noqa: BLE001 - best-effort teardown
                pass
        try:
            con.execute("DROP SCHEMA IF EXISTS F5_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
