#!/usr/bin/env python3
"""Verify JSON Tables object markers as structured relationship mappings."""

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


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def main() -> int:
    con = connect()
    try:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('json_ref_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS JSON_REF_VERIFY CASCADE")
        con.execute("CREATE SCHEMA JSON_REF_VERIFY")
        con.execute(
            'CREATE TABLE JSON_REF_VERIFY.CUSTOMERS ('
            '"_id" DECIMAL(18,0), "profile|object" DECIMAL(18,0), '
            '"amount" DECIMAL(18,2))'
        )
        con.execute(
            'CREATE TABLE JSON_REF_VERIFY.CUSTOMERS_profile ('
            '"_id" DECIMAL(18,0), "tier" VARCHAR(20))'
        )
        con.execute(
            'INSERT INTO JSON_REF_VERIFY.CUSTOMERS VALUES '
            "(1, 101, 10), (2, 102, 20), (3, NULL, 5)"
        )
        con.execute(
            'INSERT INTO JSON_REF_VERIFY.CUSTOMERS_profile VALUES '
            "(101, 'GOLD'), (102, 'SILVER')"
        )

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('json_ref_verify', "
            "'SEMANTIC_JSON_REF_VERIFY', 'JSON Tables relationship verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('json_ref_verify', 'customer', "
            "'JSON_REF_VERIFY', 'CUSTOMERS', 'c', 'c.\"_id\"', "
            "'One customer document', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('json_ref_verify', 'profile', "
            "'JSON_REF_VERIFY', 'CUSTOMERS_PROFILE', 'p', 'p.\"_id\"', "
            "'One nested profile object', 'Profiles')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('json_ref_verify', "
            "'customer', 'customer_pk', 'PRIMARY', 'JSON document key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('json_ref_verify', "
            "'customer', 'customer_pk', '_id', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('json_ref_verify', "
            "'profile', 'profile_pk', 'PRIMARY', 'Nested object key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('json_ref_verify', "
            "'profile', 'profile_pk', '_id', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('json_ref_verify', "
            "'CUSTOMERS', 'customer', 'Customer documents')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP('json_ref_verify', "
            "'customer_profile', 'customer', 'profile', "
            "'c.\"profile|object\" = p.\"_id\"', 'MANY_TO_ONE', 'LEFT', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
            "'json_ref_verify', 'customer_profile', 'profile|object', NULL, "
            "'_id', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('json_ref_verify', 'CUSTOMERS', "
            "'profile', 'customer_tier', 'p.\"tier\"', 'VARCHAR(20)', "
            "'Customer Tier', 'Tier from nested profile', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('json_ref_verify', 'customer', "
            "'amount', 'c.\"amount\"', 'DECIMAL(18,2)', 'ADDITIVE', "
            "'Amount', 'Customer amount', FALSE, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
            "'ALTER SEMANTIC VIEW json_ref_verify.CUSTOMERS REPLACE METRICS ("
            "METRIC total_amount AS SUM(amount) ON ENTITY customer "
            "RETURNS DECIMAL(18,2) ADDITIVE PUBLIC CERTIFIED)', FALSE)",
        ]
        for statement in setup:
            execute(con, statement)

        validation = execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('json_ref_verify')"
        )
        errors = [row for row in validation if str(row[0]) == "ERROR"]
        if errors:
            raise AssertionError(f"model validation failed: {errors}")

        request = json.dumps(
            {
                "model": "json_ref_verify",
                "object": "CUSTOMERS",
                "metrics": ["total_amount"],
                "dimensions": ["customer_tier"],
                "proof_mode": "STRICT_GRAIN",
            },
            separators=(",", ":"),
        )
        compiled = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON("
            + sql_string(request)
            + ")",
        )[0]
        if str(compiled[0]) != "OK":
            raise AssertionError(f"strict compile failed: {compiled}")
        plan = json.loads(str(compiled[5]))["logical_plan"]
        proofs = plan.get("relationship_proofs", [])
        if not proofs or any(proof.get("status") != "PROVEN" for proof in proofs):
            raise AssertionError(f"relationship was not grain-proven: {proofs}")

        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('json_ref_verify')")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        rows = execute(
            con,
            "SELECT customer_tier, total_amount "
            "FROM SEMANTIC_JSON_REF_VERIFY.CUSTOMERS "
            "GROUP BY customer_tier ORDER BY customer_tier",
        )
        actual = [(None if tier is None else str(tier), float(amount)) for tier, amount in rows]
        expected = [("GOLD", 10.0), ("SILVER", 20.0), (None, 5.0)]
        if actual != expected:
            raise AssertionError(f"unexpected nested relationship result: {actual}")

        print("ok JSON mapping: profile|object was accepted as a physical column")
        print("ok JSON proof: nested object relationship was grain-proven")
        print("ok JSON query: nested profile dimension executed without an aliasing view")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('json_ref_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS JSON_REF_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
