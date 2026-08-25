#!/usr/bin/env python3
"""Verify the named admin API can bootstrap a model on its own.

`CALL_ADMIN_JSON` exists so callers do not have to count positional arguments.
It resolves script names from `SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS` and
nothing else, so a script missing from that view is unreachable through the named
path — and the refusal is a clean `SEMANTIC_ADMIN_100: unknown admin script`,
which reads as though the script does not exist.

The signature generator required a `RETURNS` clause, and the mutators that
"complete without returning rows" are declared `) AS`. Nine callable APIs were
therefore absent, and they were precisely the ones a new model needs first, so
`CALL_ADMIN_JSON` could not perform a single step of the documented bootstrap
while looking healthy on every script that did return a table (BUG-G02).

There was no end-to-end test of the named path at all, which is why a systematic
omission went unnoticed. This is that test: a complete model built through
`CALL_ADMIN_JSON` alone, validated, published, and checked against a number
computed from the source tables.

Note on optional parameters: `CALL_ADMIN_JSON` wants them *omitted*, where the
positional form wants an explicit `NULL`. Passing JSON `null` is not the same as
omitting the key. That is a separate finding, deliberately not worked around
here — this file uses the documented style so it keeps testing the API rather
than a workaround.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from decimal import Decimal
from typing import Any

MODEL = "g02_named_verify"
PUBLISHED_SCHEMA = "SEMANTIC_G02_NAMED_VERIFY"

# Scripts that exist in SEMANTIC_ADMIN but are not callable APIs. Mirrors
# NON_CALLABLE_SCRIPTS in tools/package_lua_scripts.py; asserted against the
# live database here so the two cannot drift apart silently.
NON_CALLABLE = {
    "AGENT_RUNTIME",
    "COMPILER_RUNTIME",
    "MATERIALIZATION_RUNTIME",
    "SEMANTIC_DEFINITION_RUNTIME",
    "SEMANTIC_GUARD",
    "SEMANTIC_PREPROCESSOR",
    "VALIDATOR_RUNTIME",
}

# The nine BUG-G02 omitted, all declared `) AS`.
SILENT_MUTATORS = [
    "CREATE_MODEL",
    "ADD_ENTITY",
    "ADD_SEMANTIC_OBJECT",
    "ADD_RELATIONSHIP",
    "ADD_RELATIONSHIP_KEY_MAPPING",
    "CREATE_SEMANTIC_OBJECT",
    "REGISTER_MATERIALIZATION",
    "SET_MATERIALIZATION_STATUS",
    "ADD_MATERIALIZATION_COLUMN",
]


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


def named(con: Any, script: str, args: dict[str, Any]) -> dict[str, Any]:
    """Call one admin script through the named API, returning its envelope."""
    statement = con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CALL_ADMIN_JSON("
        f"{literal(script)}, {literal(json.dumps(args))})")
    names = [name.lower() for name in statement.columns().keys()]
    return dict(zip(names, statement.fetchone()))


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")

        # ---- the coverage claim, checked against the live catalog ----------
        scripts = {row[0] for row in execute(
            con, "SELECT OBJECT_NAME FROM SYS.EXA_ALL_OBJECTS"
                 " WHERE ROOT_NAME = 'SEMANTIC_ADMIN' AND OBJECT_TYPE = 'SCRIPT'")}
        published = {row[0] for row in execute(
            con, "SELECT DISTINCT SCRIPT_NAME FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS")}
        unreachable = sorted(scripts - published - NON_CALLABLE)
        if unreachable:
            raise AssertionError(
                "callable scripts with no published signature, so unreachable "
                f"through CALL_ADMIN_JSON: {unreachable}")
        print(f"ok every callable script publishes a signature"
              f" ({len(published)} of {len(scripts)}; {len(NON_CALLABLE)} libraries excluded)")

        leaked = sorted(published & NON_CALLABLE)
        if leaked:
            raise AssertionError(f"runtime libraries advertised as APIs: {leaked}")
        print("ok no runtime library is advertised as a callable API")

        for script in SILENT_MUTATORS:
            if script not in published:
                raise AssertionError(
                    f"{script} returns no rows and is still unpublished — the "
                    "RETURNS-clause omission is back")
        print(f"ok all {len(SILENT_MUTATORS)} row-less mutators are reachable by name")

        # ---- a whole model, built through the named API only ---------------
        truth = {str(row[0]): Decimal(str(row[1])) for row in execute(
            con,
            "SELECT o.order_status, SUM(ol.quantity * ol.net_unit_price)"
            " FROM MART.ORDER_LINES ol"
            " JOIN MART.ORDERS o ON o.order_id = ol.order_id"
            " GROUP BY 1")}
        if not truth:
            raise AssertionError("MART example data is missing; run install --example")

        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(MODEL)})")
        except Exception:  # noqa: BLE001 - absent on the first run
            pass

        # Optional parameters are omitted, not passed as null. Every one of these
        # steps failed with SEMANTIC_ADMIN_100 before the fix.
        bootstrap: list[tuple[str, dict[str, Any]]] = [
            ("CREATE_MODEL", {
                "MODEL_NAME": MODEL, "PUBLISHED_SCHEMA": PUBLISHED_SCHEMA,
                "DESCRIPTION": "named-call bootstrap"}),
            ("ADD_ENTITY", {
                "MODEL_NAME": MODEL, "ENTITY_NAME": "order_line",
                "SOURCE_SCHEMA": "MART", "SOURCE_OBJECT": "ORDER_LINES",
                "SOURCE_ALIAS": "ol", "PRIMARY_KEY_EXPR": "ol.order_id",
                "GRAIN_DESCRIPTION": "One order line", "DESCRIPTION": "Lines"}),
            ("ADD_ENTITY", {
                "MODEL_NAME": MODEL, "ENTITY_NAME": "order",
                "SOURCE_SCHEMA": "MART", "SOURCE_OBJECT": "ORDERS",
                "SOURCE_ALIAS": "o", "PRIMARY_KEY_EXPR": "o.order_id",
                "GRAIN_DESCRIPTION": "One order", "DESCRIPTION": "Orders"}),
            ("ADD_UNIQUE_KEY_WITH_COLUMNS", {
                "MODEL_NAME": MODEL, "ENTITY_NAME": "order", "KEY_NAME": "o_pk",
                "KEY_KIND": "PRIMARY", "DESCRIPTION": "Order identity",
                "SOURCE_FORMAT": "NATIVE",
                "COLUMNS_JSON": [{"ordinal_position": 1, "column_name": "ORDER_ID"}]}),
            ("ADD_SEMANTIC_OBJECT", {
                "MODEL_NAME": MODEL, "OBJECT_NAME": "SALES",
                "ROOT_ENTITY_NAME": "order_line", "DESCRIPTION": "Line grain"}),
            ("ADD_RELATIONSHIP", {
                "MODEL_NAME": MODEL, "RELATIONSHIP_NAME": "ol_to_o",
                "FROM_ENTITY_NAME": "order_line", "TO_ENTITY_NAME": "order",
                "JOIN_CONDITION": "ol.order_id = o.order_id",
                "CARDINALITY": "MANY_TO_ONE", "JOIN_TYPE": "INNER"}),
            ("ADD_RELATIONSHIP_KEY_MAPPING", {
                "MODEL_NAME": MODEL, "RELATIONSHIP_NAME": "ol_to_o",
                "FROM_COLUMN_NAME": "ORDER_ID", "TO_COLUMN_NAME": "ORDER_ID",
                "ORDINAL_POSITION": 1}),
            ("ADD_DIMENSION", {
                "MODEL_NAME": MODEL, "OBJECT_NAME": "SALES", "ENTITY_NAME": "order",
                "DIMENSION_NAME": "order_status", "EXPRESSION": "o.order_status",
                "DATA_TYPE": "VARCHAR(32)", "DISPLAY_NAME": "Status",
                "DESCRIPTION": "Order status", "IS_CERTIFIED": True}),
            ("ADD_FACT", {
                "MODEL_NAME": MODEL, "ENTITY_NAME": "order_line",
                "FACT_NAME": "net_revenue",
                "EXPRESSION": "ol.quantity * ol.net_unit_price",
                "DATA_TYPE": "DECIMAL(18,2)", "ADDITIVE_POLICY": "ADDITIVE",
                "DISPLAY_NAME": "Revenue", "DESCRIPTION": "Line revenue",
                "IS_PRIVATE": False, "IS_CERTIFIED": True}),
            ("ADD_METRIC", {
                "MODEL_NAME": MODEL, "OBJECT_NAME": "SALES",
                "METRIC_NAME": "total_revenue", "EXPRESSION": "SUM(net_revenue)",
                "METRIC_TYPE": "ADDITIVE", "BASE_ENTITY_NAME": "order_line",
                "DATA_TYPE": "DECIMAL(18,2)", "DISPLAY_NAME": "Revenue",
                "DESCRIPTION": "Total revenue", "FORMAT_HINT": "currency",
                "IS_PRIVATE": False, "IS_CERTIFIED": True}),
            ("VALIDATE_MODEL", {"MODEL_NAME": MODEL}),
            ("PUBLISH_MODEL", {"MODEL_NAME": MODEL}),
        ]
        row_less = 0
        for script, args in bootstrap:
            envelope = named(con, script, args)
            if envelope.get("status") != "OK":
                raise AssertionError(f"{script} did not report OK: {envelope}")
            if envelope.get("executed_statement") is None:
                raise AssertionError(f"{script} returned no executed statement")
            if int(envelope.get("row_count") or 0) == 0:
                row_less += 1
        print(f"ok the documented bootstrap runs end to end through the named API"
              f" ({len(bootstrap)} calls)")
        # The scripts that return nothing must come back OK with ROW_COUNT 0, not
        # as an error: that difference is what made them invisible in the first
        # place, so it is worth asserting rather than assuming.
        if row_less == 0:
            raise AssertionError(
                "no call returned zero rows; the fixture no longer covers the "
                "row-less mutators that BUG-G02 was about")
        print(f"ok {row_less} row-less calls returned STATUS OK with ROW_COUNT 0")

        # ---- and the model it built actually answers ------------------------
        request = {"model": MODEL, "object": "SALES",
                   "metrics": ["total_revenue"], "dimensions": ["order_status"]}
        statement = con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON("
            f"{literal(json.dumps(request))})")
        names = [name.lower() for name in statement.columns().keys()]
        result = dict(zip(names, statement.fetchone()))
        if result["status"] != "OK":
            raise AssertionError(
                f"model built by name does not compile: {result.get('error_code')}"
                f" {result.get('error_message')}")
        actual = {str(row[0]): Decimal(str(row[1]))
                  for row in execute(con, result["generated_sql"])}
        if actual != truth:
            raise AssertionError(f"numbers differ: got {actual}, truth {truth}")
        print(f"ok the model it built returns the truth: {actual}")

        # An unknown name must still be refused, and say where to look.
        try:
            named(con, "NO_SUCH_ADMIN_SCRIPT", {})
            raise AssertionError("an unknown script name was accepted")
        except AssertionError:
            raise
        except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
            message = str(exc)
            for fragment in ("SEMANTIC_ADMIN_100", "ADMIN_SCRIPT_PARAMETERS"):
                if fragment not in message:
                    raise AssertionError(
                        f"unknown-script refusal lacks {fragment!r}: {message}") from None
        print("ok an unknown script name is still refused and names the catalog")

        # ---- an omitted parameter must never surface as a Lua address ------
        # `CALL_ADMIN_JSON` renders an omitted key as SQL NULL, which reaches a
        # Lua script as *userdata*, not nil -- and userdata is truthy, so the
        # common `tostring(value or "")` normalisation turns it into
        # "userdata: 0x...". That both defeats the script's own
        # required-parameter check and reports an address to the caller. Three
        # scripts were doing it (REMOVE_RELATIONSHIP, REMOVE_UNIQUE_KEY,
        # REMOVE_UNIQUE_KEY_WITH_COLUMNS) and each answered a missing key with
        # "not found: userdata: 0x..." instead of SEMANTIC_ADMIN_001.
        #
        # Probed against a model that does not exist, so no call can mutate
        # anything: only scripts whose first parameter is MODEL_NAME and which
        # take at least one more are model-scoped, and every one of them must
        # refuse this call.
        probes = [row[0] for row in execute(
            con, "SELECT SCRIPT_NAME FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS"
                 " WHERE ORDINAL_POSITION = 1 AND PARAMETER_NAME = 'MODEL_NAME'"
                 " AND PARAMETER_COUNT > 1 ORDER BY SCRIPT_NAME")]
        if len(probes) < 40:
            raise AssertionError(
                f"only {len(probes)} model-scoped scripts found; the probe has "
                "stopped covering the admin surface")
        leaks = []
        for script in probes:
            try:
                named(con, script, {"MODEL_NAME": "no_such_model_for_probe"})
            except Exception as exc:  # noqa: BLE001 - the refusal is the point
                if "userdata" in str(exc):
                    leaks.append(f"{script}: {str(exc).split('caught in')[0][-110:]}")
        if leaks:
            raise AssertionError(
                "an omitted parameter is rendered as a Lua address:\n  "
                + "\n  ".join(leaks))
        print(f"ok no omitted parameter leaks a Lua address ({len(probes)} scripts probed)")

        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(MODEL)})")
        print("named admin API verified")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
