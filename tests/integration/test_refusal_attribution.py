"""A refused request is logged against its model and its client.

Most refusal paths returned the error alone, dropping the request and model the
compile had already resolved, so AGENT_REQUEST_LOG and QUERY_LOG recorded
MODEL_ID NULL -- and AGENT_REQUEST_LOG lost CLIENT_NAME too. After a breaking
change (a dropped metric) REQUEST_HISTORY_FOR_AGENT, filtered by the model or
the client, showed only what had worked: the owner could not see who had
started failing.
"""

from __future__ import annotations

import uuid
from typing import Any

import verify_support as support

UNKNOWN = "zz_no_such_metric"


def history(con: Any, where: str) -> list[dict[str, Any]]:
    return support.named_rows(con.execute(
        "SELECT HANDLE_TYPE, MODEL_NAME, CLIENT_NAME, STATUS, ERROR_CODE"
        f" FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT WHERE {where}"))


def test_json_refusal_keeps_model_and_client(con: Any) -> None:
    client = f"refusal-attribution-{uuid.uuid4().hex[:8]}"
    compiled = support.compile_request(con, {
        "model": "sales", "object": "SALES", "metrics": [UNKNOWN], "client": client})
    assert compiled["status"] == "ERROR"
    con.commit()
    rows = history(con, f"CLIENT_NAME = {support.sql_string(client)}")
    assert [(r["model_name"], r["status"]) for r in rows] == [("sales", "ERROR")], rows


def test_json_refusal_for_an_unknown_model_names_none(con: Any) -> None:
    client = f"refusal-attribution-{uuid.uuid4().hex[:8]}"
    support.compile_request(con, {
        "model": "zz_no_such_model", "object": "SALES", "metrics": ["x"], "client": client})
    con.commit()
    rows = history(con, f"CLIENT_NAME = {support.sql_string(client)}")
    assert [(r["model_name"], r["error_code"]) for r in rows] == [
        (None, "SEMANTIC_REQUEST_011")], rows


def test_sql_lane_refusal_keeps_model(semantic_con: Any) -> None:
    marker = uuid.uuid4().hex[:8]
    # A unique alias makes the statement findable in the log.
    statement = f"SELECT {UNKNOWN} AS zz_{marker} FROM SEMANTIC_SALES.SALES"
    try:
        semantic_con.execute(statement)
    except Exception:  # noqa: BLE001 -- the refusal is the point
        pass
    semantic_con.commit()
    rows = history(semantic_con, "HANDLE_TYPE = 'QUERY_LOG' AND REQUEST_TEXT LIKE "
                   + support.sql_string(f"%zz_{marker}%"))
    assert [(r["model_name"], r["status"]) for r in rows] == [("sales", "ERROR")], rows
