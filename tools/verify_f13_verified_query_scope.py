#!/usr/bin/env python3
"""Verify ADD_VERIFIED_QUERY scopes its own request to its model and object.

`ADD_VERIFIED_QUERY` takes the model as parameter 1 and the object as parameter
2, then compiles `REQUEST_JSON` to prove the query works before storing it.
Those parameters were not injected into the request, so the natural call --
model and object given once, as parameters -- failed with
`SEMANTIC_AGENT_020: ... SEMANTIC_REQUEST_002 model is required`, naming neither
this script nor the fix (finding F13).

Injection is not enough on its own: a request that already names a *different*
model would compile against one model and be filed under another, so the
disagreement is refused instead. Asserted here:

  1. model and object omitted -> accepted, and the stored REQUEST_JSON carries
     them, so a verified query replays standalone rather than only inside the
     call that created it;
  2. model and object supplied and in agreement -> still accepted, with no
     duplicate key in the stored form;
  3. a disagreeing model -> refused with SEMANTIC_AGENT_021;
  4. a disagreeing object -> refused the same way;
  5. the string "model" appearing as a nested *value* is not mistaken for the
     request's own model key -- the scan is depth- and string-aware, not a
     substring match;
  6. a request that is not a JSON object is still refused by the existing guard.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any

MODEL = "sales"
OBJECT = "SALES"
PREFIX = "f13_verify"


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


def add_verified_query(name: str, request: Any) -> str:
    body = request if isinstance(request, str) else json.dumps(request)
    return (
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY({literal(MODEL)},"
        f" {literal(OBJECT)}, {literal(name)}, 'verification query',"
        f" {literal(body)}, 'a few rows', FALSE)"
    )


def stored_request(con: Any, name: str) -> str:
    rows = execute(
        con,
        "SELECT REQUEST_JSON FROM SYS_SEMANTIC.VERIFIED_QUERIES"
        f" WHERE QUERY_NAME = {literal(name)} ORDER BY VERIFIED_QUERY_ID DESC LIMIT 1")
    if not rows:
        raise AssertionError(f"{name}: nothing stored")
    return str(rows[0][0])


def expect_refusal(con: Any, label: str, sql: str, code: str) -> None:
    try:
        execute(con, sql)
    except Exception as exc:  # noqa: BLE001 - the message is the assertion
        message = str(exc)
        if code not in message:
            raise AssertionError(f"{label}: expected {code}, got: {message}") from None
        print(f"ok {label}: refused with {code}")
        return
    raise AssertionError(f"{label}: expected {code}, but the call was accepted")


def cleanup(con: Any) -> None:
    execute(con, "DELETE FROM SYS_SEMANTIC.VERIFIED_QUERIES"
                 f" WHERE QUERY_NAME LIKE {literal(PREFIX + '%')}")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        cleanup(con)
        base = {"metrics": ["total_revenue"], "dimensions": ["order_status"]}

        # 1. the natural call: scope given once, as parameters.
        name = f"{PREFIX} omitted"
        execute(con, add_verified_query(name, base))
        stored = stored_request(con, name)
        parsed = json.loads(stored)
        if parsed.get("model") != MODEL or parsed.get("object") != OBJECT:
            raise AssertionError(f"scope not injected into stored request: {stored}")
        print("ok omitted model/object accepted and injected into the stored request")

        # The stored form must compile on its own, which is the point of storing
        # the scoped text rather than what the caller typed.
        statement = con.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(stored)})")
        names = [column.lower() for column in statement.columns().keys()]
        replay = dict(zip(names, statement.fetchone()))
        if replay["status"] != "OK":
            raise AssertionError(
                f"stored request does not replay: {replay.get('error_code')}"
                f" {replay.get('error_message')}")
        print("ok stored request replays standalone")

        # 2. supplied and in agreement.
        name = f"{PREFIX} agreeing"
        execute(con, add_verified_query(
            name, dict(base, model=MODEL, object=OBJECT)))
        stored = stored_request(con, name)
        if stored.count('"model"') != 1 or stored.count('"object"') != 1:
            raise AssertionError(f"duplicated scope key in stored request: {stored}")
        print("ok agreeing model/object accepted without duplicating the key")

        # Case-insensitive agreement is still agreement: model names are matched
        # case-insensitively everywhere else in the admin surface.
        name = f"{PREFIX} agreeing case"
        execute(con, add_verified_query(
            name, dict(base, model=MODEL.upper(), object=OBJECT.lower())))
        print("ok agreement is case-insensitive")

        # 3/4. disagreement is refused rather than silently resolved.
        expect_refusal(con, "disagreeing model",
                       add_verified_query(f"{PREFIX} bad model",
                                          dict(base, model="not_" + MODEL)),
                       "SEMANTIC_AGENT_021")
        expect_refusal(con, "disagreeing object",
                       add_verified_query(f"{PREFIX} bad object",
                                          dict(base, object="NOT_" + OBJECT)),
                       "SEMANTIC_AGENT_021")

        # 5. "model" as a nested value, not a top-level key.
        name = f"{PREFIX} nested"
        nested = {"metrics": ["total_revenue"],
                  "filters": [{"field": "order_status", "op": "=",
                               "value": "model"}]}
        execute(con, add_verified_query(name, nested))
        parsed = json.loads(stored_request(con, name))
        if parsed.get("model") != MODEL:
            raise AssertionError(
                "a nested \"model\" value suppressed injection: "
                + json.dumps(parsed))
        print("ok a nested \"model\" value is not mistaken for the request's own")

        # 6. the pre-existing shape guard still applies.
        expect_refusal(con, "non-object request",
                       add_verified_query(f"{PREFIX} not an object",
                                          '["total_revenue"]'),
                       "SEMANTIC_AGENT_040")

        cleanup(con)
        print("F13 verified-query scoping verified")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
