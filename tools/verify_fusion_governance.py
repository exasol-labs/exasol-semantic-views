#!/usr/bin/env python3
"""Verify that fusion mutators cannot take a published model offline.

`skills/exasol-semantic-modeler/SKILL.md` promises that every published mutator
revalidates before returning, and that an invalid candidate is rejected and
restored rather than persisted. `ADD_ENTITY_REPRESENTATION` honoured that;
`SET_ATTRIBUTE_FUSION_POLICY` and `SET_REPRESENTATION_AUTHORITY` did not — one
accepted call left a live published model failing validation, so every consumer
got `SEMANTIC_QUERY_010` until someone worked out which change to undo
(BUG-F04), and the same gap let `RECONCILE` land on a fact whose bindings could
not support it (BUG-F05).

This asserts, on a published model:

  1. a fusion policy whose contract cannot be met is refused
     (`SEMANTIC_ADMIN_094`), nothing is persisted, and the model still serves;
  2. the same for an authority change;
  3. the same for a fact policy — while a *satisfiable* fact `RECONCILE` is
     still accepted and still exact, because the compiler supports it in a
     single-branch plan and only refuses it in a multi-fact plan
     (`SEMANTIC_REQUEST_074`);
  4. the valid versions of all three changes are accepted.

And on a draft (BUG-F06): registering an alternate representation that is not
yet usable blocks unrelated authoring, so both `VALIDATE_MODEL` and the admin
refusal now name the blocking representation and
`REMOVE_ENTITY_REPRESENTATION` — the recovery that always worked and that no
message mentioned.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from decimal import Decimal
from typing import Any

MODEL = "governance_verify"
DRAFT_MODEL = "governance_verify_draft"
SCHEMA = "GOVERNANCE_VERIFY"


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


def literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def compile_request(con: Any, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    row = execute(
        con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({literal(payload)})"
    )[0]
    return {"status": row[0], "error_code": row[1], "error_message": row[2],
            "generated_sql": row[4]}


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_contains(name: str, haystack: str, needle: str) -> None:
    if needle not in (haystack or ""):
        raise AssertionError(f"{name}: {needle!r} not found in {haystack!r}")
    print(f"ok {name}: found {needle!r}")


def expect_refusal(con: Any, name: str, sql: str, *fragments: str) -> None:
    try:
        execute(con, sql)
    except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
        message = str(exc)
        for fragment in fragments:
            if fragment not in message:
                raise AssertionError(f"{name}: expected {fragment!r} in: {message}") from exc
        print(f"ok {name}: refused")
        return
    raise AssertionError(f"{name}: the mutation was accepted")


def policies(con: Any, model: str) -> list[tuple[Any, ...]]:
    return execute(
        con,
        "SELECT ATTRIBUTE_TYPE, ATTRIBUTE_NAME, FUSION_STRATEGY "
        f"FROM SEMANTIC_CATALOG.ATTRIBUTE_FUSION_POLICIES WHERE MODEL_NAME = {literal(model)} "
        "ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_NAME",
    )


def authorities(con: Any, model: str) -> list[tuple[Any, ...]]:
    return execute(
        con,
        "SELECT REPRESENTATION_NAME, AUTHORITY_ROLE "
        "FROM SEMANTIC_CATALOG.REPRESENTATION_AUTHORITIES "
        f"WHERE MODEL_NAME = {literal(model)} ORDER BY REPRESENTATION_NAME",
    )


def build_tables(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    con.execute(
        f"CREATE TABLE {SCHEMA}.CUSTOMERS_MDM (CUSTOMER_ID DECIMAL(18,0), "
        "CUSTOMER_NAME VARCHAR(100), SPEND DECIMAL(18,2))"
    )
    con.execute(
        f"CREATE TABLE {SCHEMA}.CUSTOMERS_CRM (CUSTOMER_ID DECIMAL(18,0), "
        "CUSTOMER_NAME VARCHAR(100), DISPLAY_NAME VARCHAR(100), "
        "SPEND DECIMAL(18,2))"
    )
    # MDM is missing a name and a spend value the CRM has.
    con.execute(
        f"INSERT INTO {SCHEMA}.CUSTOMERS_MDM VALUES "
        "(1, 'Alice', 10.00), (2, NULL, NULL), (3, 'Carol', 30.00)"
    )
    con.execute(
        f"INSERT INTO {SCHEMA}.CUSTOMERS_CRM VALUES "
        "(1, 'Alice', 'Alice', 10.00), (2, 'Bob', 'Bob', 20.00), "
        "(3, 'Carol', 'Carol', 30.00)"
    )
    # A CRM projection missing CUSTOMER_NAME: registering it as an alternate
    # leaves a draft invalid, which is BUG-F06's shape.
    con.execute(
        f"CREATE OR REPLACE VIEW {SCHEMA}.CUSTOMERS_PARTIAL AS "
        f"SELECT CUSTOMER_ID FROM {SCHEMA}.CUSTOMERS_MDM"
    )


def build_model(con: Any, model: str) -> None:
    for statement in (
        f"CREATE_MODEL('{model}', 'SEMANTIC_{model.upper()}', 'Fusion governance', NULL)",
        f"ADD_ENTITY('{model}', 'customer', '{SCHEMA}', 'CUSTOMERS_MDM', 'c', "
        "'c.customer_id', 'One customer', 'Customer 360')",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS('{model}', 'customer', 'customer_pk', 'PRIMARY', "
        "'Customer identity', 'NATIVE', "
        '\'[{"ordinal_position":1,"column_name":"customer_id"}]\')',
        f"ADD_SEMANTIC_OBJECT('{model}', 'CUSTOMER_360', 'customer', 'Customer 360')",
        f"ADD_DIMENSION('{model}', 'CUSTOMER_360', 'customer', 'customer_name', "
        "'c.customer_name', 'VARCHAR(100)', 'Customer Name', 'Resolved name', NULL, TRUE)",
        f"ADD_FACT('{model}', 'customer', 'spend', 'c.spend', 'DECIMAL(18,2)', "
        "'ADDITIVE', 'Spend', 'Customer spend', FALSE, TRUE)",
    ):
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION("
        + literal(f"""ALTER SEMANTIC VIEW {model}.CUSTOMER_360 REPLACE METRICS (
  METRIC total_spend AS SUM(spend) ON ENTITY customer RETURNS DECIMAL(18,2)
    FORMAT 'currency' DISPLAY 'Total Spend' COMMENT 'Spend' ADDITIVE PUBLIC CERTIFIED
)""")
        + ", FALSE)",
    )


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        for model in (MODEL, DRAFT_MODEL):
            try:
                execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{model}')")
            except Exception:
                pass
        build_tables(con)
        build_model(con, MODEL)
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")

        request = {"model": MODEL, "object": "CUSTOMER_360",
                   "metrics": ["total_spend"], "dimensions": ["customer_name"],
                   "client": "verify_fusion_governance"}
        assert_equal("published model serves", compile_request(con, request)["status"], "OK")

        # 1. A fusion policy whose contract cannot be met, on a published model.
        expect_refusal(
            con,
            "unsatisfiable COALESCE refused",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY("
            f"'{MODEL}', 'DIMENSION', 'customer_name', 'COALESCE')",
            "SEMANTIC_ADMIN_094",
            "SEMANTIC_MODEL_070",
        )
        assert_equal("no policy was persisted", policies(con, MODEL), [])
        assert_equal("published model still serves",
                     compile_request(con, request)["status"], "OK")

        # 3a. The same for a fact policy (BUG-F05).
        expect_refusal(
            con,
            "unsatisfiable fact RECONCILE refused",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY("
            f"'{MODEL}', 'FACT', 'spend', 'RECONCILE')",
            "SEMANTIC_ADMIN_094",
        )
        assert_equal("no fact policy was persisted", policies(con, MODEL), [])

        # 4. Now make the fusion legitimate, and check the valid path is accepted.
        for statement in (
            # SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY: register
            # the alternate and declare its authority as one candidate, on a
            # published model, so neither lands without the other.
            f"ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY('{MODEL}', 'customer', 'crm', "
            f"'RELATION', '{SCHEMA}', 'CUSTOMERS_CRM', 20, 'MANUAL', 'AUTHORITATIVE')",
            f"ADD_ATTRIBUTE_BINDING('{MODEL}', 'DIMENSION', 'customer_name', 'crm', "
            "'c.display_name', 'PREFER', 1)",
            f"ADD_ATTRIBUTE_BINDING('{MODEL}', 'FACT', 'spend', 'crm', "
            "'c.spend', 'PREFER', 1)",
            f"SET_REPRESENTATION_AUTHORITY('{MODEL}', 'customer', 'primary', 'SUPPLEMENTAL')",
            f"SET_ATTRIBUTE_FUSION_POLICY('{MODEL}', 'DIMENSION', 'customer_name', 'RECONCILE')",
            f"SET_ATTRIBUTE_FUSION_POLICY('{MODEL}', 'FACT', 'spend', 'RECONCILE')",
        ):
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
        assert_equal(
            "valid fusion declarations accepted",
            policies(con, MODEL),
            [("DIMENSION", "customer_name", "RECONCILE"), ("FACT", "spend", "RECONCILE")],
        )

        # Fusion is now discoverable: an agent reading the surface can tell a
        # single-source column from a reconciled one, and see the declarations.
        assert_equal(
            "fields report their fusion",
            execute(
                con,
                "SELECT FIELD_NAME, SOURCE_COUNT, FUSION_STRATEGY "
                "FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT "
                f"WHERE MODEL_NAME = {literal(MODEL)} ORDER BY FIELD_NAME",
            ),
            # The metric inherits its base entity's source count; the reconciled
            # dimension names the strategy that decides its value.
            [("customer_name", 2, "RECONCILE"), ("total_spend", 2, "NONE")],
        )
        assert_equal(
            "the object reports its fusion",
            execute(
                con,
                "SELECT SOURCE_COUNT, FUSION_STRATEGY FROM SEMANTIC_AGENT.OBJECTS_FOR_AGENT "
                f"WHERE MODEL_NAME = {literal(MODEL)}",
            ),
            [(2, "RECONCILE")],
        )
        assert_equal(
            "the declarations are projected",
            execute(
                con,
                "SELECT FUSION_ASPECT, COUNT(*) FROM SEMANTIC_AGENT.FUSION_FOR_AGENT "
                f"WHERE MODEL_NAME = {literal(MODEL)} GROUP BY FUSION_ASPECT "
                "ORDER BY FUSION_ASPECT",
            ),
            [("ATTRIBUTE_POLICY", 2), ("AUTHORITY", 2), ("REPRESENTATION", 2)],
        )
        assert_equal(
            "authority is projected per representation",
            execute(
                con,
                "SELECT REPRESENTATION_NAME, STRATEGY FROM SEMANTIC_AGENT.FUSION_FOR_AGENT "
                f"WHERE MODEL_NAME = {literal(MODEL)} AND FUSION_ASPECT = 'AUTHORITY' "
                "ORDER BY REPRESENTATION_NAME",
            ),
            [("crm", "AUTHORITATIVE"), ("primary", "SUPPLEMENTAL")],
        )

        # 3b. Fact reconciliation is a supported single-branch shape, so the
        # admin script must not forbid it outright: it is exact here, and only a
        # multi-fact plan refuses it (SEMANTIC_REQUEST_074).
        fused = compile_request(con, {
            "model": MODEL, "object": "CUSTOMER_360", "metrics": ["total_spend"],
            "client": "verify_fusion_governance",
        })
        assert_equal("fact reconciliation compiles", fused["status"], "OK")
        assert_equal("fact reconciliation is exact",
                     Decimal(str(execute(con, fused["generated_sql"])[0][0])),
                     Decimal("60"))

        # 2. An authority change that breaks the RECONCILE contract. The rule
        # that catches it is the entity-level one -- at most one active
        # representation may be AUTHORITATIVE -- not SEMANTIC_MODEL_071, which
        # counts authorities among the representations that bind one attribute.
        before = authorities(con, MODEL)
        expect_refusal(
            con,
            "authority change that breaks RECONCILE refused",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY("
            f"'{MODEL}', 'customer', 'primary', 'AUTHORITATIVE')",
            "SEMANTIC_ADMIN_094",
            "SEMANTIC_MODEL_044",
        )
        assert_equal("authority was restored", authorities(con, MODEL), before)
        assert_equal("published model still serves",
                     compile_request(con, request)["status"], "OK")

        # BUG-F06, on a draft: an alternate that is not yet usable blocks
        # unrelated authoring, and now says how to get out.
        build_model(con, DRAFT_MODEL)
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION("
            f"'{DRAFT_MODEL}', 'customer', 'partial', 'RELATION', '{SCHEMA}', "
            "'CUSTOMERS_PARTIAL', 20, 'MANUAL')",
        )
        issues = execute(
            con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{DRAFT_MODEL}')")
        errors = [row for row in issues if str(row[0]).upper() == "ERROR"]
        if not errors:
            raise AssertionError("the incomplete alternate did not invalidate the draft")
        message = str(errors[0][4])
        assert_contains("validation names the blocking representation", message,
                        "Representation partial is registered but not yet usable")
        assert_contains("validation names the recovery", message,
                        "REMOVE_ENTITY_REPRESENTATION")
        assert_contains("validation names completing it instead", message,
                        "ADD_ATTRIBUTE_BINDING")

        expect_refusal(
            con,
            "later authoring inherits the remedy",
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
            f"'{DRAFT_MODEL}', 'CUSTOMER_360', 'customer', 'probe_dim', "
            "'c.customer_id', 'DECIMAL(18,0)', 'Probe', 'Probe', NULL, TRUE)",
            "SEMANTIC_ADMIN_091",
            "REMOVE_ENTITY_REPRESENTATION",
        )

        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION("
            f"'{DRAFT_MODEL}', 'customer', 'partial')",
        )
        repaired = execute(
            con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{DRAFT_MODEL}')")
        assert_equal("the named recovery works",
                     [row for row in repaired if str(row[0]).upper() == "ERROR"], [])

        print()
        print("fusion governance verified.")
        return 0
    finally:
        for model in (MODEL, DRAFT_MODEL):
            try:
                execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{model}')")
            except Exception:
                pass
        try:
            con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
