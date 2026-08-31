#!/usr/bin/env python3
"""What every host-side verifier needs, in one place.

Fifty-nine `verify_*.py` scripts each defined their own `connect()`; twenty-nine
of them character-for-character. Twenty-six defined their own `sql_string()`.
Exactly one imported `tools/semantic_client.py`, which exists, is tested, and
reads script results *by column name* — the thing `docs/known-issues.md` says to
do, after a documented column layout drifted and positional readers silently
returned `NULL`.

So the fix is not another helper nobody imports. It is one module that makes the
correct thing shorter than the copy, plus a ratchet in `tests/test_conventions.py`
pinning how many verifiers still roll their own. The pin may shrink and may not
grow; convert a verifier when you next touch it.

Three things are worth taking from here even in a script that keeps its own
connection:

  named_row / named_rows  read an EXECUTE SCRIPT result by column name. The
                          ninth column is AGENT_REQUEST_ID for COMPILE_SQL and
                          QUERY_LOG_ID for COMPILE_SQL_DEBUG, so a positional
                          read is wrong in a way that looks fine.
  call_admin              call an admin script by *keyword*. Fifteen of the 82
                          parameterised scripts take eight or more positionals,
                          and Exasol reports a miscount as `expected 9 script
                          parameters but got 8` — no script name, no parameter
                          name.
  sql_string              EXECUTE SCRIPT does not support bind parameters, so
                          every caller escapes by hand or gets it wrong.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any


def connect(**overrides: Any) -> Any:
    """Connect to the deployment the tools all default to.

    Exasol Personal uses a self-signed certificate, so verification is off by
    default for local use; set EXASOL_TLS_VERIFY=1 to turn it back on.
    """
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)

    verify = os.environ.get("EXASOL_TLS_VERIFY", "").lower() in {"1", "true", "yes"}
    settings: dict[str, Any] = {
        "dsn": f"{os.environ.get('EXASOL_HOST', 'localhost')}"
               f":{os.environ.get('EXASOL_PORT', '8563')}",
        "user": os.environ.get("EXASOL_USER", "sys"),
        "password": os.environ.get("EXASOL_PASSWORD", "exasol"),
        "encryption": True,
    }
    if not verify:
        settings["websocket_sslopt"] = {"cert_reqs": ssl.CERT_NONE}
    settings.update(overrides)
    return pyexasol.connect(**settings)


def sql_string(value: Any) -> str:
    """A single-quoted SQL literal. EXECUTE SCRIPT has no bind parameters."""
    return "'" + str(value).replace("'", "''") + "'"


def sql_argument(value: Any) -> str:
    """One positional script argument, with None rendered as SQL NULL.

    The positional scripts want an explicit NULL for an absent optional, where
    the named API wants the key omitted — see CLAUDE.md. This is the positional
    side of that split.
    """
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return str(value)
    return sql_string(value)


def named_rows(statement: Any) -> list[dict[str, Any]]:
    """Every row of a result set, keyed by the result set's own column names.

    `EXECUTE SCRIPT` result sets are named — the `RETURNS TABLE` declaration
    carries the names over the wire — so nothing has to know which index a
    column sits at. Positional reads are what turned an incorrect documented
    column layout into consumers silently reading NULL.
    """
    names = [name.lower() for name in statement.columns().keys()]
    return [dict(zip(names, row)) for row in statement.fetchall()]


def named_row(statement: Any) -> dict[str, Any] | None:
    """The first row by column name, or None when the script returned nothing.

    Some mutation scripts (`ADD_ENTITY`, `ADD_SEMANTIC_OBJECT`,
    `ADD_RELATIONSHIP`) complete without returning rows.
    """
    rows = named_rows(statement)
    return rows[0] if rows else None


def run_script(con: Any, script: str, *arguments: Any) -> Any:
    """EXECUTE SCRIPT with positional arguments, returning the statement."""
    rendered = ", ".join(sql_argument(value) for value in arguments)
    return con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{script}({rendered})")


def call_admin(con: Any, script: str, **arguments: Any) -> dict[str, Any] | None:
    """Call an admin script by keyword through CALL_ADMIN_JSON.

    Immune to arity drift, which the positional form is not: Exasol checks the
    count in the SQL layer and its refusal names neither the script nor the
    parameter. Omit a key for an absent optional; the named API rejects an
    explicit JSON null (SEMANTIC_ADMIN_064).
    """
    payload = json.dumps(arguments, separators=(",", ":"))
    return named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CALL_ADMIN_JSON("
        f"{sql_string(script)}, {sql_string(payload)})"))


def compile_request(con: Any, request: dict[str, Any]) -> dict[str, Any]:
    """COMPILE_REQUEST_JSON, read by column name."""
    payload = json.dumps(request, separators=(",", ":"))
    return named_row(con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON("
        f"{sql_string(payload)})")) or {}


def compile_sql(con: Any, semantic_sql: str) -> dict[str, Any]:
    """COMPILE_SQL, read by column name."""
    return named_row(con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL({sql_string(semantic_sql)})")) or {}


def validate_model(con: Any, model_name: str) -> list[dict[str, Any]]:
    """VALIDATE_MODEL's issues, by column name rather than by ordinal.

    Five call sites in the Lua runtime independently restate this result's
    five-column shape; host-side callers do not have to.
    """
    return named_rows(con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({sql_string(model_name)})"))


def blocking_issues(issues: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """The issues that stop a publish: ERROR and PRECONDITION, not WARNING."""
    return [issue for issue in issues
            if str(issue.get("severity", "")).upper() in {"ERROR", "PRECONDITION"}]
