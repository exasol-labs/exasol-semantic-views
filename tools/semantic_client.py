"""Thin Python helpers for the Exasol Semantic Layer API.

EXECUTE SCRIPT does not support pyexasol bind parameters, so callers must
manually escape JSON strings. These helpers handle that escaping and expose a
clean, dict-in / dict-out interface for the most common operations.

Usage:
    import pyexasol
    from tools.semantic_client import compile_request, execute_semantic_sql

    conn = pyexasol.connect(dsn='localhost:8563', user='sys', password='exasol',
                            websocket_sslopt={'cert_reqs': 0})

    result = compile_request(conn, {
        'model': 'sales',
        'object': 'SALES',
        'metrics': ['total_revenue'],
        'dimensions': ['customer_region'],
        'client': 'my_app',
    })
    if result['status'] == 'OK':
        rows = conn.execute(result['generated_sql']).fetchall()
"""

from __future__ import annotations

import json
from typing import Any


def _sql_string(value: str) -> str:
    """Wrap a Python string as a single-quoted SQL literal with internal quotes escaped."""
    return "'" + value.replace("'", "''") + "'"


def compile_request(conn: Any, request: dict) -> dict:
    """Call COMPILE_REQUEST_JSON and return a dict with named keys.

    Returns a dict with keys:
      status, error_code, error_message, original_sql, generated_sql,
      plan_json, clarification_json, validation_run_id, agent_request_id
    """
    sql = f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({_sql_string(json.dumps(request))})"
    row = conn.execute(sql).fetchone()
    if row is None:
        return {"status": "ERROR", "error_code": "CLIENT_ERROR", "error_message": "No result row returned."}
    return {
        "status":            row[0],
        "error_code":        row[1],
        "error_message":     row[2],
        "original_sql":      row[3],
        "generated_sql":     row[4],
        "plan_json":         row[5],
        "clarification_json": row[6],
        "validation_run_id": row[7],
        "agent_request_id":  row[8],
    }


def compile_sql(conn: Any, semantic_sql: str) -> dict:
    """Call COMPILE_SQL and return a dict with named keys.

    Returns a dict with keys:
      status, error_code, error_message, original_sql, generated_sql,
      plan_json, clarification_json, validation_run_id, agent_request_id
    """
    sql = f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL({_sql_string(semantic_sql)})"
    row = conn.execute(sql).fetchone()
    if row is None:
        return {"status": "ERROR", "error_code": "CLIENT_ERROR", "error_message": "No result row returned."}
    return {
        "status":            row[0],
        "error_code":        row[1],
        "error_message":     row[2],
        "original_sql":      row[3],
        "generated_sql":     row[4],
        "plan_json":         row[5],
        "clarification_json": row[6],
        "validation_run_id": row[7],
        "agent_request_id":  row[8],
    }


def execute_semantic_sql(conn: Any, semantic_sql: str) -> list[dict]:
    """Enable the semantic SQL preprocessor, execute a semantic query, and return rows.

    The preprocessor is session-scoped. If the session already has it enabled,
    enabling it again is a no-op. The caller is responsible for the connection
    lifecycle.

    Returns a list of dicts (column name → value) using the column names from
    the query result set.
    """
    conn.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    stmt = conn.execute(semantic_sql)
    cols = [col[0] for col in stmt.description()]
    return [dict(zip(cols, row)) for row in stmt.fetchall()]


def compile_and_run(conn: Any, request: dict) -> list[dict]:
    """Compile a structured request and execute the generated SQL in one call.

    Returns a list of dicts (column name → value). Raises RuntimeError on
    compile failure.
    """
    result = compile_request(conn, request)
    if result["status"] != "OK":
        raise RuntimeError(
            f"Compile failed [{result['error_code']}]: {result['error_message']}"
        )
    generated = result["generated_sql"]
    stmt = conn.execute(generated)
    cols = [col[0] for col in stmt.description()]
    return [dict(zip(cols, row)) for row in stmt.fetchall()]
