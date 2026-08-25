#!/usr/bin/env python3
"""Verify the missing-identity-binding diagnostic leads with the cause.

`docs/data-fusion.md` presents F5 as what unlocks F4 across mismatched keys, so
combining them on one entity is the documented use case — and there is no
compound call that registers a representation with both authority and identity.
Following the documented path therefore lands on
`ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY` plus a separate `ADD_IDENTITY_BINDING`,
and forgetting the second one leaves the entity invalid.

That much is ergonomics. The reportable defect was what validation then said: the
representation is unusable, so every key, expression and attribute check fails
against it, and those rules run *before* the identity rules. The actionable
`SEMANTIC_MODEL_047` sat second or later, and because every admin DDL wrapper
reports `validation_errors[1]`, a refused authoring call pointed at a dimension
that was never wrong (BUG-G04).

Asserted here:

  1. `SEMANTIC_MODEL_047` is the *first* error, so the DDL wrappers quote it;
  2. a refused authoring call really does name it, not a consequence;
  3. the consequences name the specific remedy (`ADD_IDENTITY_BINDING`) instead
     of the generic "complete the declaration" list, because when the entity has
     an identity the missing piece is knowable;
  4. adding the binding clears all of it;
  5. the two calling conventions for `MAPPING_JSON` differ as documented —
     positional wants `NULL`, the named API wants the key *omitted*.

(5) is not a fix, it is the contract pinned as a test: the difference is easy to
"tidy up" into a behaviour change by accident.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any

MODEL = "g04_diag_verify"
SCHEMA = "G04_DIAG_VERIFY"
DECLARATIONS_FORM = "SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS"


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


def try_execute(con: Any, sql: str) -> tuple[bool, str]:
    try:
        execute(con, sql)
        return True, ""
    except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
        return False, str(exc)


def errors(con: Any) -> list[tuple[Any, ...]]:
    return [row for row in
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({literal(MODEL)})")
            if str(row[0]).upper() == "ERROR"]


def build(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    con.execute(f"""
        CREATE TABLE {SCHEMA}.CUSTOMERS_MDM (
          CUSTOMER_ID DECIMAL(18,0), CUSTOMER_NAME VARCHAR(100)
        )
    """)
    # The CRM source deliberately carries neither CUSTOMER_ID nor CUSTOMER_NAME:
    # that is why it needs a mapped identity, and it is what makes every
    # unrelated check fail against it while the binding is missing.
    con.execute(f"""
        CREATE TABLE {SCHEMA}.CUSTOMERS_CRM (
          ACCOUNT_ID VARCHAR(20), DISPLAY_NAME VARCHAR(100)
        )
    """)
    # The published-model case needs the dimension to resolve on the alternate,
    # so it uses a CRM source that carries CUSTOMER_NAME. The identity still
    # differs -- it keys on ACCOUNT_ID -- which is what the mapping is for.
    con.execute(f"""
        CREATE TABLE {SCHEMA}.CUSTOMERS_CRM_FULL (
          ACCOUNT_ID VARCHAR(20), CUSTOMER_NAME VARCHAR(100)
        )
    """)
    con.execute(f"""
        CREATE TABLE {SCHEMA}.CUSTOMER_XREF (
          ACCOUNT_ID VARCHAR(20), CUSTOMER_ID DECIMAL(18,0)
        )
    """)
    con.execute(f"INSERT INTO {SCHEMA}.CUSTOMERS_MDM VALUES (1,'Alice'),(2,'Bob')")
    con.execute(f"INSERT INTO {SCHEMA}.CUSTOMERS_CRM VALUES ('A-1','Alice'),('A-2','Bob')")
    con.execute(f"INSERT INTO {SCHEMA}.CUSTOMERS_CRM_FULL VALUES ('A-1','Alice'),('A-2','Bob')")
    con.execute(f"INSERT INTO {SCHEMA}.CUSTOMER_XREF VALUES ('A-1',1),('A-2',2)")

    try:
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(MODEL)})")
    except Exception:  # noqa: BLE001 - absent on the first run
        pass
    for statement in (
        f"CREATE_MODEL({literal(MODEL)}, {literal('SEMANTIC_' + MODEL.upper())},"
        f" 'BUG-G04 verification', NULL)",
        f"ADD_ENTITY({literal(MODEL)}, 'customer', {literal(SCHEMA)},"
        f" 'CUSTOMERS_MDM', 'c', 'c.customer_id', 'One customer', 'Customer 360')",
        f"ADD_UNIQUE_KEY({literal(MODEL)}, 'customer', 'customer_pk', 'PRIMARY',"
        f" 'MDM key', 'NATIVE')",
        f"ADD_UNIQUE_KEY_COLUMN({literal(MODEL)}, 'customer', 'customer_pk',"
        f" 'CUSTOMER_ID', NULL, 1)",
        f"ADD_SEMANTIC_OBJECT({literal(MODEL)}, 'CUSTOMER_360', 'customer',"
        f" 'Customer 360')",
        f"ADD_DIMENSION({literal(MODEL)}, 'CUSTOMER_360', 'customer',"
        f" 'customer_name', 'c.customer_name', 'VARCHAR(100)', 'Name',"
        f" 'Resolved name', NULL, TRUE)",
        f"ADD_SEMANTIC_IDENTITY({literal(MODEL)}, 'customer', 'customer_identity',"
        f" 'GLOBAL', 'DECIMAL(18,0)', 'Certified identity')",
        f"ADD_IDENTITY_BINDING({literal(MODEL)}, 'customer_identity', 'primary',"
        f" 'c.customer_id', 'DIRECT')",
    ):
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        build(con)
        if errors(con):
            raise AssertionError(f"fixture is not valid to begin with: {errors(con)}")
        print("ok entity with an F5 identity validates before the F4 step")

        # No compound form takes both, so the documented use case needs two calls.
        forms = {row[0] for row in execute(
            con, "SELECT DISTINCT SCRIPT_NAME FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS"
                 " WHERE SCRIPT_NAME LIKE 'ADD_ENTITY_REPRESENTATION%'")}
        if DECLARATIONS_FORM.split(".", 1)[1] not in forms:
            raise AssertionError(
                "the collapsed representation form is gone; authority x coverage x"
                " identity is eight combinations and the one-dimensional forms"
                " cover four of them")
        print(f"ok one collapsed form covers the declaration space"
              f" ({len(forms)} representation forms in total)")

        execute(con, "EXECUTE SCRIPT SEMANTIC_ADMIN."
                     f"ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY({literal(MODEL)},"
                     f" 'customer', 'crm', 'RELATION', {literal(SCHEMA)},"
                     f" 'CUSTOMERS_CRM', 20, 'MANUAL', 'AUTHORITATIVE')")

        reported = errors(con)
        if not reported:
            raise AssertionError("a representation with no identity binding validated clean")
        if str(reported[0][3]) != "SEMANTIC_MODEL_047":
            raise AssertionError(
                "validation leads with a consequence, not the cause: "
                + ", ".join(f"{row[3]}" for row in reported))
        if "crm" not in str(reported[0][4]):
            raise AssertionError(f"the leading error does not name crm: {reported[0]}")
        print(f"ok SEMANTIC_MODEL_047 leads the report ({len(reported)} errors total)")

        # The wrappers quote validation_errors[1], so this is what a refused
        # authoring call actually shows.
        accepted, message = try_execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
                 f"{literal(MODEL)}, 'CUSTOMER_360', 'customer', 'probe_dim',"
                 " 'c.customer_name', 'VARCHAR(100)', 'Probe', 'Probe', NULL, TRUE)")
        if accepted:
            raise AssertionError("authoring succeeded on an invalid model")
        if "SEMANTIC_MODEL_047" not in message:
            raise AssertionError(
                f"a refused call still quotes a consequence: {message[:400]}")
        print("ok a refused authoring call quotes the cause, not a consequence")

        # And the consequences point at the one call that fixes it.
        knock_ons = [row for row in reported if str(row[3]) != "SEMANTIC_MODEL_047"]
        if not knock_ons:
            raise AssertionError("fixture no longer produces the knock-on errors")
        for row in knock_ons:
            text = str(row[4])
            if "ADD_IDENTITY_BINDING" not in text:
                raise AssertionError(
                    f"{row[3]} does not name the specific remedy: {text[:300]}")
            if "SET_REPRESENTATION_COVERAGE_BATCH" in text:
                raise AssertionError(
                    f"{row[3]} still offers the generic three options: {text[:300]}")
        print(f"ok all {len(knock_ons)} consequences name ADD_IDENTITY_BINDING")

        # The repair the report describes.
        for statement in (
            f"ADD_IDENTITY_BINDING({literal(MODEL)}, 'customer_identity', 'crm',"
            f" 'c.account_id', 'MAPPED')",
            f"ADD_IDENTITY_MAPPING_RELATION({literal(MODEL)}, 'customer_identity',"
            f" 'crm', {literal(SCHEMA)}, 'CUSTOMER_XREF', 'ACCOUNT_ID',"
            f" 'CUSTOMER_ID', 'CERTIFIED')",
            f"ADD_ATTRIBUTE_BINDING({literal(MODEL)}, 'DIMENSION', 'customer_name',"
            f" 'crm', 'c.display_name', 'PREFER', 1)",
        ):
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
        remaining = errors(con)
        if remaining:
            raise AssertionError(f"repair left errors behind: {remaining}")
        print("ok binding the identity clears every one of them")

        # ---- the two calling conventions for an absent MAPPING_JSON ---------
        positional_ok, positional_message = try_execute(
            con, "EXECUTE SCRIPT SEMANTIC_ADMIN."
                 f"ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING({literal(MODEL)},"
                 f" 'customer', 'mirror', 'RELATION', {literal(SCHEMA)},"
                 f" 'CUSTOMERS_MDM', 30, 'MANUAL', 'customer_identity',"
                 " 'c.customer_id', 'DIRECT', NULL)")
        if not positional_ok:
            raise AssertionError(
                f"positional NULL for MAPPING_JSON was refused: {positional_message[:300]}")
        print("ok positional form takes MAPPING_JSON as NULL")

        def named(name: str, priority: int, include_null: bool) -> tuple[bool, str]:
            args = {
                "MODEL_NAME": MODEL, "ENTITY_NAME": "customer",
                "REPRESENTATION_NAME": name, "SOURCE_KIND": "RELATION",
                "SOURCE_SCHEMA": SCHEMA, "SOURCE_OBJECT": "CUSTOMERS_MDM",
                "PRIORITY": priority, "FRESHNESS_POLICY": "MANUAL",
                "IDENTITY_NAME": "customer_identity",
                "SOURCE_EXPRESSION": "c.customer_id", "BINDING_KIND": "DIRECT",
            }
            if include_null:
                args["MAPPING_JSON"] = None
            return try_execute(
                con, "EXECUTE SCRIPT SEMANTIC_ADMIN.CALL_ADMIN_JSON("
                     f"'ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING',"
                     f" {literal(json.dumps(args))})")

        null_ok, null_message = named("mirror_null", 31, include_null=True)
        if null_ok:
            raise AssertionError(
                "an explicit JSON null for MAPPING_JSON was accepted; the two "
                "conventions have converged and the documentation is now wrong")
        if "SEMANTIC_ADMIN_064" not in null_message:
            raise AssertionError(
                f"explicit null refused for an unexpected reason: {null_message[:300]}")
        print("ok named form refuses an explicit JSON null (SEMANTIC_ADMIN_064)")

        omitted_ok, omitted_message = named("mirror_omitted", 32, include_null=False)
        if not omitted_ok:
            raise AssertionError(
                f"omitting MAPPING_JSON was refused: {omitted_message[:300]}")
        print("ok named form accepts MAPPING_JSON omitted, and renders it as NULL")

        # ---- the collapsed form does it in one call ------------------------
        # BUG-G04's combination. The two-call sequence above is still supported;
        # this is the one that never passes through an invalid model.
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(MODEL)})")
        build(con)
        declarations = json.dumps({
            "authority": "AUTHORITATIVE",
            "identity": {
                "identity_name": "customer_identity",
                "source_expression": "c.account_id",
                "binding_kind": "MAPPED",
                "mapping": {
                    "source_schema": SCHEMA, "source_object": "CUSTOMER_XREF",
                    "source_local_column": "ACCOUNT_ID",
                    "semantic_key_column": "CUSTOMER_ID",
                    "certification_status": "CERTIFIED",
                },
            },
        })
        rows = execute(
            con, f"EXECUTE SCRIPT {DECLARATIONS_FORM}({literal(MODEL)},"
                 f" 'customer', 'crm', 'RELATION', {literal(SCHEMA)},"
                 f" 'CUSTOMERS_CRM', 20, 'MANUAL', {literal(declarations)})")
        if not rows:
            raise AssertionError("the collapsed form returned no row")
        declared = str(rows[0][4] or "")
        for aspect in ("identity", "authority"):
            if aspect not in declared:
                raise AssertionError(f"{aspect} was not declared: {rows[0]}")
        if str(rows[0][5]) != "AUTHORITATIVE":
            raise AssertionError(f"authority not applied: {rows[0]}")
        print(f"ok one call declares both: DECLARED={declared!r}")

        # It must not pass through the invalid state the two-call path does.
        remaining = errors(con)
        identity_errors = [row for row in remaining
                           if str(row[3]) == "SEMANTIC_MODEL_047"]
        if identity_errors:
            raise AssertionError(
                f"the collapsed form left the identity unbound: {identity_errors}")
        print("ok no missing-binding error at any point in the single call")

        # The combination that has no valid outcome is refused, not attempted.
        accepted, detail = try_execute(
            con, f"EXECUTE SCRIPT {DECLARATIONS_FORM}({literal(MODEL)},"
                 f" 'customer', 'both', 'RELATION', {literal(SCHEMA)},"
                 f" 'CUSTOMERS_CRM', 30, 'MANUAL',"
                 f" {literal(json.dumps({'coverage': [{}], 'identity': {}}))})")
        if accepted:
            raise AssertionError("coverage + identity was accepted")
        if "SEMANTIC_ADMIN_215" not in detail:
            raise AssertionError(f"unexpected refusal: {detail[:200]}")
        print("ok coverage + identity is refused, citing why it cannot be valid")

        # A closed contract: a misspelled key must not be ignored.
        accepted, detail = try_execute(
            con, f"EXECUTE SCRIPT {DECLARATIONS_FORM}({literal(MODEL)},"
                 f" 'customer', 'typo', 'RELATION', {literal(SCHEMA)},"
                 f" 'CUSTOMERS_CRM', 31, 'MANUAL',"
                 f" {literal(json.dumps({'authorityy': 'PREFER'}))})")
        if accepted:
            raise AssertionError("a misspelled declaration key was ignored")
        if "SEMANTIC_ADMIN_214" not in detail:
            raise AssertionError(f"unexpected refusal: {detail[:200]}")
        print("ok a misspelled declaration key is refused by name")

        # ---- and it works on a *published* model ---------------------------
        # Compound declarations exist largely for this case: on a published model
        # each separate call is validated on its own, so a multi-step declaration
        # has to land atomically or not at all (BUG-27). The collapsed form is
        # subject to the same requirement.
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(MODEL)})")
        build(con)
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL({literal(MODEL)})")
        published = execute(
            con, "SELECT STATUS FROM SEMANTIC_CATALOG.MODELS"
                 f" WHERE MODEL_NAME = {literal(MODEL)}")
        if not published or str(published[0][0]).upper() != "PUBLISHED":
            raise AssertionError(f"fixture did not publish: {published}")
        accepted, detail = try_execute(
            con, f"EXECUTE SCRIPT {DECLARATIONS_FORM}({literal(MODEL)},"
                 f" 'customer', 'crm', 'RELATION', {literal(SCHEMA)},"
                 f" 'CUSTOMERS_CRM_FULL', 20, 'MANUAL', {literal(declarations)})")
        if not accepted:
            raise AssertionError(
                f"the collapsed form is unusable on a published model: {detail[:300]}")
        if errors(con):
            raise AssertionError(
                f"published model left invalid by the collapsed form: {errors(con)}")
        print("ok the collapsed form lands atomically on a published model")

        # And the one-dimensional forms still work, so nothing broke for existing
        # callers. On a draft model: a plain representation on a *published* model
        # with an identity is correctly rejected, which is BUG-G04's whole point.
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(MODEL)})")
        build(con)
        for form, tail in (
            ("ADD_ENTITY_REPRESENTATION", "40, 'MANUAL'"),
            ("ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY", "41, 'MANUAL', 'SUPPLEMENTAL'"),
        ):
            name = "legacy_" + form[-6:].lower()
            accepted, detail = try_execute(
                con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{form}({literal(MODEL)},"
                     f" 'customer', {literal(name)}, 'RELATION', {literal(SCHEMA)},"
                     f" 'CUSTOMERS_CRM', {tail})")
            if not accepted:
                raise AssertionError(f"{form} regressed: {detail[:200]}")
        print("ok the one-dimensional forms still work for existing callers")

        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(MODEL)})")
        con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        print("missing-identity-binding diagnostic verified")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
