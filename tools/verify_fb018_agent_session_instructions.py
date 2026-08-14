#!/usr/bin/env python3
"""Verify agent discovery makes Semantic SQL session activation executable."""

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


def main() -> int:
    con = connect()
    semantic_query = (
        "SELECT segment, tickets FROM SEMANTIC_FB018_VERIFY.SUPPORT "
        "GROUP BY segment ORDER BY segment"
    )
    try:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('fb018_verify')")
        except Exception:
            pass
        con.execute("DROP SCHEMA IF EXISTS FB018_VERIFY CASCADE")
        con.execute("CREATE SCHEMA FB018_VERIFY")
        con.execute(
            "CREATE TABLE FB018_VERIFY.TICKETS ("
            "TICKET_ID DECIMAL(18,0), SEGMENT VARCHAR(30), "
            "TICKET_VALUE DECIMAL(18,0))"
        )
        con.execute(
            "INSERT INTO FB018_VERIFY.TICKETS VALUES "
            "(1, 'business', 1), (2, 'business', 1), (3, 'consumer', 1)"
        )
        setup = [
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL('fb018_verify', "
            "'SEMANTIC_FB018_VERIFY', 'FB-018 verification', NULL)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('fb018_verify', 'ticket', "
            "'FB018_VERIFY', 'TICKETS', 't', 't.ticket_id', "
            "'One ticket', 'Tickets')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY('fb018_verify', "
            "'ticket', 'ticket_pk', 'PRIMARY', 'Ticket key', 'NATIVE')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN('fb018_verify', "
            "'ticket', 'ticket_pk', 'TICKET_ID', NULL, 1)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT('fb018_verify', "
            "'SUPPORT', 'ticket', 'Support')",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('fb018_verify', "
            "'SUPPORT', 'ticket', 'segment', 't.segment', 'VARCHAR(30)', "
            "'Segment', 'Customer segment', NULL, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('fb018_verify', 'ticket', "
            "'ticket_value', 't.ticket_value', 'DECIMAL(18,0)', 'ADDITIVE', "
            "'Ticket value', 'One per ticket', FALSE, TRUE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
            "'ALTER SEMANTIC VIEW fb018_verify.SUPPORT REPLACE METRICS "
            "(METRIC tickets AS SUM(ticket_value) ON ENTITY ticket "
            "RETURNS DECIMAL(18,0) ADDITIVE PUBLIC CERTIFIED)', FALSE)",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('fb018_verify')",
        ]
        for statement in setup:
            execute(con, statement)
        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        model_rows = execute(
            con,
            "SELECT AGENT_READINESS, QUERY_MODES, PREPROCESSOR_QUALIFIED_NAME, "
            "SESSION_SETUP_REQUIRED, SESSION_SETUP_SQL "
            "FROM SEMANTIC_AGENT.MODELS_FOR_AGENT "
            "WHERE MODEL_NAME = 'fb018_verify'",
        )
        if len(model_rows) != 1:
            raise AssertionError(f"published sales model not found: {model_rows}")
        readiness, modes, preprocessor, setup_required, setup_sql = model_rows[0]
        if str(readiness) not in ("VALID", "WARNING"):
            raise AssertionError(f"sales model is not agent-ready: {model_rows[0]}")
        if "STRUCTURED_REQUEST" not in str(modes) or "SEMANTIC_SQL" not in str(modes):
            raise AssertionError(f"query modes are incomplete: {modes}")
        if str(preprocessor) != "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR":
            raise AssertionError(f"unexpected preprocessor: {preprocessor}")
        if not bool(setup_required) or str(setup_sql) != (
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()"
        ):
            raise AssertionError(f"session setup is not executable: {model_rows[0]}")

        instructions = execute(
            con,
            "SELECT INSTRUCTION_ID, INSTRUCTION_KIND, INSTRUCTION_TEXT, PRIORITY, "
            "CREATED_BY "
            "FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT "
            "WHERE MODEL_NAME = 'fb018_verify' "
            "ORDER BY PRIORITY, INSTRUCTION_ID",
        )
        system_instructions = [
            row for row in instructions if str(row[4]).strip() == "SEMANTIC_ADMIN"
        ]
        if len(system_instructions) != 2:
            raise AssertionError(f"expected two system instructions: {instructions}")
        instruction_text = " ".join(str(row[2]) for row in system_instructions)
        for required in (
            "ENABLE_SEMANTIC_SQL",
            "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR",
            "STRUCTURED_REQUEST",
            "SEMANTIC_SQL",
            "QUERY_TIMEOUT=60",
        ):
            if required not in instruction_text:
                raise AssertionError(f"instruction text omitted {required}: {instructions}")

        try:
            execute(con, semantic_query)
        except Exception:
            pass
        else:
            raise AssertionError("semantic aggregate unexpectedly ran without session setup")
        execute(con, str(setup_sql))
        activated_result = execute(con, semantic_query)
        normalized_result = [(str(segment), int(tickets)) for segment, tickets in activated_result]
        if normalized_result != [("business", 2), ("consumer", 1)]:
            raise AssertionError(f"unexpected semantic result: {activated_result}")

        print("ok FB-018 discovery: ready model exposes executable session setup")
        print("ok FB-018 instructions: published model exposes two system instructions")
        print("ok FB-018 activation: identical semantic query succeeds after discovered setup")
        return 0
    finally:
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        except Exception:
            pass
        try:
            execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('fb018_verify')")
        except Exception:
            pass
        try:
            con.execute("DROP SCHEMA IF EXISTS FB018_VERIFY CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
