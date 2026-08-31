#!/usr/bin/env python3
"""Verify QUERY_TIMEOUT is exposed as a recoverable agent precondition."""

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


def main() -> int:
    con = connect()
    try:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('fb019_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS FB019_VERIFY CASCADE")
        con.execute("CREATE SCHEMA FB019_VERIFY")
        con.execute("CREATE TABLE FB019_VERIFY.CUSTOMERS (CUSTOMER_ID DECIMAL(18,0))")
        con.execute("INSERT INTO FB019_VERIFY.CUSTOMERS VALUES 1, 2, 3")

        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('fb019_verify', "
            "'SEMANTIC_FB019_VERIFY', 'FB-019 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('fb019_verify', 'customer', "
            "'FB019_VERIFY', 'CUSTOMERS', 'c', 'c.customer_id', "
            "'One customer', 'Customers')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('fb019_verify', "
            "'customer', 'customer_pk', 'PRIMARY', 'Customer key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('fb019_verify', "
            "'customer', 'customer_pk', 'CUSTOMER_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION('fb019_verify', "
            "'customer', 'replica', 'RELATION', 'FB019_VERIFY', 'CUSTOMERS', 2, NULL)",
        ]
        for statement in setup:
            execute(con, statement)

        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('fb019_verify')")

        con.execute("ALTER SESSION SET QUERY_TIMEOUT=0")
        issues = execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('fb019_verify')"
        )
        timeout_issues = [row for row in issues if str(row[3]) == "SEMANTIC_MODEL_041"]
        if len(timeout_issues) != 1 or str(timeout_issues[0][0]) != "PRECONDITION":
            raise AssertionError(f"timeout was not classified as PRECONDITION: {issues}")

        model_rows = execute(
            con,
            "SELECT VALIDATION_STATUS, VALIDATION_ERROR_COUNT, "
            "VALIDATION_PRECONDITION_COUNT, AGENT_READINESS "
            "FROM SEMANTIC_AGENT.MODELS_FOR_AGENT "
            "WHERE MODEL_NAME = 'fb019_verify'",
        )
        if model_rows != [("PRECONDITION", 0, 1, "PRECONDITION")]:
            raise AssertionError(f"unexpected agent readiness: {model_rows}")

        agent_issues = execute(
            con,
            "SELECT SEVERITY, RULE_CODE FROM SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT "
            "WHERE MODEL_NAME = 'fb019_verify'",
        )
        if ("PRECONDITION", "SEMANTIC_MODEL_041") not in agent_issues:
            raise AssertionError(f"agent issue surface omitted precondition: {agent_issues}")

        instructions = execute(
            con,
            "SELECT INSTRUCTION_KIND, INSTRUCTION_TEXT "
            "FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT "
            "WHERE MODEL_NAME = 'fb019_verify' AND INSTRUCTION_KIND = 'PRECONDITION'",
        )
        if len(instructions) != 1 or "QUERY_TIMEOUT=60" not in str(instructions[0][1]):
            raise AssertionError(f"timeout instruction is not discoverable: {instructions}")

        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        recovered = execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('fb019_verify')"
        )
        if any(str(row[0]) in ("ERROR", "PRECONDITION") for row in recovered):
            raise AssertionError(f"bounded validation did not recover: {recovered}")
        readiness = execute(
            con,
            "SELECT AGENT_READINESS FROM SEMANTIC_AGENT.MODELS_FOR_AGENT "
            "WHERE MODEL_NAME = 'fb019_verify'",
        )
        if readiness[0][0] not in ("VALID", "WARNING"):
            raise AssertionError(f"readiness did not recover: {readiness}")

        print("ok FB-019 severity: timeout is a PRECONDITION, not a model error")
        print("ok FB-019 discovery: readiness, issue, and instruction surfaces agree")
        print("ok FB-019 recovery: bounded revalidation restores agent readiness")
        return 0
    finally:
        try:
            con.execute("ALTER SESSION SET QUERY_TIMEOUT=0")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('fb019_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS FB019_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
