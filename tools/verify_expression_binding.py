#!/usr/bin/env python3
"""Verify that a dimension or fact expression that cannot execute fails validation.

The static checks see only qualified `alias.column` references, so a bare word
-- a literal missing its quotes, a reserved word such as OPEN -- used to pass
VALIDATE_MODEL, publish, compile to STATUS = OK, and fail only when the
generated SQL ran (BUG-23). SEMANTIC_MODEL_072 binds each expression against
its source relation, so ADD_DIMENSION and the semantic DDL refuse it, and
VALIDATE_MODEL reports one already in the catalog.
"""

from __future__ import annotations

from typing import Any
import importlib.util
from pathlib import Path

# Connection defaults, SQL escaping and named result reads live in
# tools/verify_support.py so verifiers do not each carry their own. See the
# ratchet in tests/test_conventions.py.
_SUPPORT = importlib.util.spec_from_file_location(
    "verify_support", Path(__file__).with_name("verify_support.py"))
support = importlib.util.module_from_spec(_SUPPORT)
_SUPPORT.loader.exec_module(support)

MODEL = "expr_bind_verify"
SCHEMA = "EXPR_BIND_VERIFY"
BAD = "CASE WHEN tk.RESOLVED THEN resolved ELSE open END"
GOOD = "CASE WHEN tk.RESOLVED THEN 'resolved' ELSE 'open' END"


def cleanup(con: Any) -> None:
    try:
        support.run_script(con, "DROP_MODEL", MODEL)
    except Exception:
        pass
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")


def apply_definition(con: Any, statement: str) -> None:
    result = support.named_row(support.run_script(
        con, "APPLY_SEMANTIC_DEFINITION", statement, False)) or {}
    if result.get("status") != "OK":
        raise AssertionError(f"definition refused: {result}")


def dimension_expression(con: Any) -> Any:
    row = con.execute(
        "SELECT EXPRESSION FROM SEMANTIC_CATALOG.DIMENSIONS "
        f"WHERE MODEL_NAME = {support.sql_string(MODEL)} "
        "AND DIMENSION_NAME = 'resolved_flag'").fetchone()
    return None if row is None else row[0]


def main() -> int:
    con = support.connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        cleanup(con)
        con.execute(f"CREATE SCHEMA {SCHEMA}")
        con.execute(f"""
            CREATE TABLE {SCHEMA}.TICKETS (
              TICKET_ID DECIMAL(18,0), PRIORITY VARCHAR(10), RESOLVED BOOLEAN
            )
        """)
        con.execute(f"""
            INSERT INTO {SCHEMA}.TICKETS VALUES
              (1, 'HIGH', TRUE), (2, 'LOW', FALSE), (3, 'LOW', TRUE)
        """)
        support.run_script(con, "CREATE_MODEL", MODEL, f"SEMANTIC_{SCHEMA}",
                           "Expression binding verification", None)
        support.run_script(con, "ADD_ENTITY", MODEL, "ticket", SCHEMA, "TICKETS",
                           "tk", "tk.ticket_id", "One ticket", "Support tickets")
        support.run_script(con, "ADD_UNIQUE_KEY", MODEL, "ticket", "ticket_pk",
                           "PRIMARY", "Ticket identity", "NATIVE")
        support.run_script(con, "ADD_UNIQUE_KEY_COLUMN", MODEL, "ticket",
                           "ticket_pk", "TICKET_ID", None, 1)
        support.run_script(con, "ADD_SEMANTIC_OBJECT", MODEL, "SUPPORT", "ticket",
                           "Support tickets")
        support.run_script(con, "ADD_DIMENSION", MODEL, "SUPPORT", "ticket",
                           "priority", "tk.priority", "VARCHAR(10)", "Priority",
                           "Ticket priority", None, True)
        support.run_script(con, "ADD_FACT", MODEL, "ticket", "ticket_ref",
                           "tk.ticket_id", "DECIMAL(18,0)", "ADDITIVE", "Ticket",
                           "Ticket identifier", False, True)
        apply_definition(con, f"ALTER SEMANTIC VIEW {MODEL}.SUPPORT REPLACE METRICS ("
                         "METRIC ticket_count AS COUNT(ticket_ref) ON ENTITY ticket "
                         "RETURNS DECIMAL(18,0) ADDITIVE PUBLIC CERTIFIED)")

        # The report's expression: `resolved` binds to the column, `open` is a
        # reserved word, so the expression can never execute.
        try:
            support.run_script(con, "ADD_DIMENSION", MODEL, "SUPPORT", "ticket",
                               "resolved_flag", BAD, "VARCHAR(10)", "Resolution state",
                               "Resolution state", None, True)
        except Exception as exc:
            message = str(exc)
            for fragment in ("SEMANTIC_ADMIN_091", "SEMANTIC_MODEL_072", "OPEN",
                             f'"{SCHEMA}"."TICKETS" tk', "Quote string literals"):
                if fragment not in message:
                    raise AssertionError(f"refusal lacks {fragment!r}: {message}") from exc
        else:
            raise AssertionError("ADD_DIMENSION accepted an expression that cannot execute")
        if dimension_expression(con) is not None:
            raise AssertionError("refused dimension was not rolled back")
        print("ok ADD_DIMENSION: refused with SEMANTIC_MODEL_072 and rolled back")

        result = support.named_row(support.run_script(
            con, "APPLY_SEMANTIC_DEFINITION",
            f"ALTER SEMANTIC VIEW {MODEL}.SUPPORT ADD OR REPLACE DIMENSION "
            f"resolved_flag ON ENTITY ticket AS {BAD} RETURNS VARCHAR(10)", False)) or {}
        if result.get("status") != "ERROR" or "SEMANTIC_MODEL_072" not in str(result):
            raise AssertionError(f"semantic DDL accepted the expression: {result}")
        if dimension_expression(con) is not None:
            raise AssertionError("refused DDL dimension was not rolled back")
        print("ok semantic DDL: refused with SEMANTIC_MODEL_072 and rolled back")

        apply_definition(con, f"ALTER SEMANTIC VIEW {MODEL}.SUPPORT ADD OR REPLACE DIMENSION "
                         f"resolved_flag ON ENTITY ticket AS {GOOD} RETURNS VARCHAR(10)")
        if support.blocking_issues(support.validate_model(con, MODEL)):
            raise AssertionError("corrected model does not validate")
        support.run_script(con, "PUBLISH_MODEL", MODEL)
        result = support.compile_sql(
            con, f"SELECT resolved_flag, ticket_count FROM SEMANTIC_{SCHEMA}.SUPPORT")
        if result.get("status") != "OK":
            raise AssertionError(f"corrected model does not compile: {result}")
        rows = sorted((str(flag), int(count)) for flag, count in
                      con.execute(result["generated_sql"]).fetchall())
        if rows != [("open", 1), ("resolved", 2)]:
            raise AssertionError(f"unexpected result: {rows}")
        print("ok corrected expression: validates, publishes, compiles and executes")

        # A catalog written before the check existed still carries the
        # expression; VALIDATE_MODEL must report it rather than certify it.
        for table, column in (("DIMENSIONS", "EXPRESSION"),
                              ("ATTRIBUTE_BINDINGS", "SOURCE_EXPRESSION")):
            con.execute(f"UPDATE SYS_SEMANTIC.{table} SET {column} = {support.sql_string(BAD)} "
                        f"WHERE {column} = {support.sql_string(GOOD)}")
        issues = support.validate_model(con, MODEL)
        refused = [issue for issue in issues if issue.get("rule_code") == "SEMANTIC_MODEL_072"]
        if [(issue.get("object_name"), str(issue.get("severity")).upper())
                for issue in refused] != [("resolved_flag", "ERROR")]:
            raise AssertionError(f"expected one SEMANTIC_MODEL_072 error: {issues}")
        print("ok VALIDATE_MODEL: an existing expression that cannot execute is an error")
        return 0
    finally:
        try:
            cleanup(con)
        finally:
            con.close()


if __name__ == "__main__":
    raise SystemExit(main())
