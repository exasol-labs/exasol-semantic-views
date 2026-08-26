#!/usr/bin/env python3
"""Verify the tier-2 fusion layer round-trips through one document.

Tier 1 -- what one source says about itself -- has had a document format for a
while: Apache Ossie/OSI, one file per source. Tier 2, how those sources compose,
had none, and on a *published* model it was not even incrementally authorable:
each of `ADD_ENTITY_REPRESENTATION`, `ADD_IDENTITY_BINDING`,
`ADD_IDENTITY_MAPPING_RELATION` and `SET_REPRESENTATION_AUTHORITY` is refused on
its own, because each alone leaves the model invalid. The eight compound
`_WITH_*` forms exist to get around that, and they enumerate by hand a space that
is a product; BUG-G04 was a report that one combination had no door.

Asserted here:

  1. The four-step sequence that is impossible step-by-step lands as one
     document, on a published model, with a dry run first.
  2. Dry run commits nothing.
  3. Applying an exported document is a no-op -- `applied=0` -- which is what
     makes the file safe to keep in source control and re-run.
  4. Round-trip: export, apply to an equivalent model, export again, and the two
     documents are identical.
  5. A failure part-way through rolls the whole document back.
  6. The document is a closed contract: an unknown key, a model mismatch, and an
     identity binding with no identity are each refused by name.

`QUERY_TIMEOUT` is set because multi-representation key probes require it
(`SEMANTIC_MODEL_041`); that precondition is the caller's, and it is the first
thing an unset session hits.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any

SCHEMA = "FUSION_DECL_VERIFY"
MODEL = "fusion_decl_verify"
MIRROR = "fusion_decl_mirror"
NARROW = "fusion_decl_narrow"


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
    return "'" + str(value).replace("'", "''") + "'"


def execute(con: Any, sql: str) -> list[tuple[Any, ...]]:
    statement = con.execute(sql)
    if statement.num_columns == 0:
        return []
    return [tuple(row) for row in statement.fetchall()]


def scalar(con: Any, sql: str) -> Any:
    rows = execute(con, sql)
    return rows[0][0] if rows else None


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}")


def apply_document(con: Any, model: str, document: dict, dry_run: bool) -> dict:
    rows = execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION("
        f"{literal(model)}, {literal(json.dumps(document))},"
        f" {'TRUE' if dry_run else 'FALSE'})")
    if len(rows) != 1:
        raise AssertionError(f"expected one apply row, got {rows}")
    return {"status": str(rows[0][0]), "error_code": rows[0][1],
            "message": str(rows[0][2]), "operations": rows[0][3],
            "applied": rows[0][4]}


def export_document(con: Any, model: str) -> dict:
    """The whole model's fusion layer as one comparable object."""
    rows = execute(
        con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_FUSION_DECLARATION({literal(model)}, NULL)")
    entities: dict[str, Any] = {}
    for scope_kind, scope_name, _count, payload in rows:
        document = json.loads(str(payload))
        for name, entity in (document.get("entities") or {}).items():
            entities[name] = entity
    return entities


def representation_count(con: Any, model: str) -> int:
    return int(scalar(
        con,
        "SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = r.MODEL_ID"
        f" WHERE m.MODEL_NAME = {literal(model)} AND r.STATUS = 'ACTIVE'") or 0)


def build_sources(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    con.execute(f"CREATE TABLE {SCHEMA}.C_MDM (CUSTOMER_ID DECIMAL(18,0), NAME VARCHAR(50))")
    con.execute(f"CREATE TABLE {SCHEMA}.C_CRM (ACCOUNT_ID VARCHAR(20), NAME VARCHAR(50))")
    con.execute(f"CREATE TABLE {SCHEMA}.XREF (ACCOUNT_ID VARCHAR(20), CUSTOMER_ID DECIMAL(18,0))")
    con.execute(f"INSERT INTO {SCHEMA}.C_MDM VALUES (1,'Alice'),(2,'Bob')")
    con.execute(f"INSERT INTO {SCHEMA}.C_CRM VALUES ('A-1','Alice'),('A-2','Bob')")
    con.execute(f"INSERT INTO {SCHEMA}.XREF VALUES ('A-1',1),('A-2',2)")


def build_model(con: Any, model: str, published: bool) -> None:
    try:
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(model)})")
    except Exception:  # noqa: BLE001 - absent on the first run
        pass
    schema = "SEMANTIC_" + model.upper()
    key_json = '[{"column_name":"CUSTOMER_ID","ordinal_position":1}]'
    for statement in (
        f"CREATE_MODEL({literal(model)}, {literal(schema)}, 'fusion document probe', NULL)",
        f"ADD_ENTITY({literal(model)}, 'customer', {literal(SCHEMA)}, 'C_MDM', 'c',"
        f" 'c.customer_id', 'One customer', 'Customer')",
        f"ADD_UNIQUE_KEY_WITH_COLUMNS({literal(model)}, 'customer', 'pk', 'PRIMARY',"
        f" 'MDM key', 'NATIVE', {literal(key_json)})",
        f"ADD_SEMANTIC_OBJECT({literal(model)}, 'C360', 'customer', 'Customer 360')",
        f"ADD_DIMENSION({literal(model)}, 'C360', 'customer', 'cname', 'c.name',"
        f" 'VARCHAR(50)', 'Name', 'Resolved name', NULL, TRUE)",
        f"ADD_SEMANTIC_IDENTITY({literal(model)}, 'customer', 'cid', 'GLOBAL',"
        f" 'DECIMAL(18,0)', 'Certified identity')",
        f"ADD_IDENTITY_BINDING({literal(model)}, 'cid', 'primary', 'c.customer_id', 'DIRECT')",
    ):
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{statement}")
    if published:
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL({literal(model)})")


def fused_document() -> dict:
    return {"entities": {"customer": {
        "identity": {"name": "cid", "kind": "GLOBAL", "data_type": "DECIMAL(18,0)"},
        "representations": [{
            "name": "crm", "source_kind": "RELATION", "source_schema": SCHEMA,
            "source_object": "C_CRM", "priority": 20, "authority": "AUTHORITATIVE",
            "identity_binding": {
                "source_expression": "c.account_id", "binding_kind": "MAPPED",
                "mapping": {"source_schema": SCHEMA, "source_object": "XREF",
                            "source_local_column": "ACCOUNT_ID",
                            "semantic_key_column": "CUSTOMER_ID",
                            "certification_status": "CERTIFIED"}}}],
        # TRIM(), not a bare c.name: the compound representation form seeds a
        # binding using the dimension's own expression, so a document declaring
        # the same expression is correctly a no-op. The F4 case that matters is
        # the alternate computing the attribute *differently*, and this keeps the
        # values identical so the numbers stay comparable.
        "attribute_bindings": [{
            "attribute_type": "DIMENSION", "attribute_name": "cname",
            "representation": "crm", "source_expression": "TRIM(c.name)",
            "binding_role": "PREFER", "binding_priority": 1}]}}}


def main() -> int:
    con = connect()
    try:
        # Multi-representation key probes need it, and it is the first thing an
        # unset session hits (SEMANTIC_MODEL_041).
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        build_sources(con)
        build_model(con, MODEL, published=True)
        assert_equal("published fixture starts with one representation",
                     representation_count(con, MODEL), 1)

        # The fixture already declares an F5 identity bound to the primary, and
        # that *is* fusion metadata -- so the document is non-empty before any
        # alternate arrives. A model with genuinely nothing fused exports no
        # entities at all, which is what the sales demo does.
        baseline = export_document(con, MODEL)
        assert_equal("the identity alone already exports as a document",
                     sorted(baseline.keys()), ["customer"])
        assert_equal("with one representation and no authority",
                     [len(baseline["customer"]["representations"]),
                      baseline["customer"]["representations"][0].get("authority")],
                     [1, None])
        assert_equal("an unfused model exports nothing",
                     export_document(con, "sales"), {})

        # ---- the sequence that cannot be done step by step ------------------
        step_by_step = (
            f"ADD_ENTITY_REPRESENTATION({literal(MODEL)}, 'customer', 'probe',"
            f" 'RELATION', {literal(SCHEMA)}, 'C_CRM', 30, 'MANUAL')")
        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{step_by_step}")
            raise AssertionError(
                "a bare representation was accepted on a published model with an "
                "identity; the premise of the document surface is gone")
        except AssertionError:
            raise
        except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
            if "SEMANTIC_ADMIN_094" not in str(exc):
                raise AssertionError(f"unexpected refusal: {str(exc)[:300]}") from None
        print("ok step-by-step fusion is still refused on a published model")

        document = fused_document()
        dry = apply_document(con, MODEL, document, True)
        assert_equal("dry run status", dry["status"], "DRY_RUN")
        assert_equal("dry run committed nothing", representation_count(con, MODEL), 1)
        assert_equal("dry run left the document unchanged",
                     export_document(con, MODEL), baseline)

        applied = apply_document(con, MODEL, document, False)
        assert_equal("one document applies to a published model", applied["status"], "OK")
        assert_equal("both representations are active", representation_count(con, MODEL), 2)
        if int(applied["applied"]) < 2:
            raise AssertionError(
                f"expected the representation *and* the binding, got {applied}")
        print(f"ok the document did in one call what four calls cannot"
              f" ({applied['applied']} operations)")
        assert_equal(
            "the declared alternate expression is what landed",
            scalar(con,
                   "SELECT b.SOURCE_EXPRESSION FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS b"
                   " JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r"
                   "   ON r.REPRESENTATION_ID = b.REPRESENTATION_ID"
                   " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = b.MODEL_ID"
                   f" WHERE m.MODEL_NAME = {literal(MODEL)}"
                   " AND r.REPRESENTATION_NAME = 'crm' AND b.STATUS = 'ACTIVE'"),
            "TRIM(c.name)")

        # ---- re-applying is a no-op ----------------------------------------
        again = apply_document(con, MODEL, document, False)
        assert_equal("re-applying succeeds", again["status"], "OK")
        assert_equal("re-applying changes nothing", int(again["applied"]), 0)
        if "nothing to do" not in again["message"]:
            raise AssertionError(f"a no-op apply should say so: {again['message']}")
        print("ok an already-applied document reports nothing to do")

        # ---- round-trip -----------------------------------------------------
        exported = export_document(con, MODEL)
        if "customer" not in exported:
            raise AssertionError(f"the fused entity did not export: {exported}")
        for aspect in ("identity", "representations"):
            if aspect not in exported["customer"]:
                raise AssertionError(f"{aspect} missing from the export: {exported}")
        assert_equal("the export carries both representations",
                     len(exported["customer"]["representations"]), 2)
        mapped = [r for r in exported["customer"]["representations"]
                  if (r.get("identity_binding") or {}).get("binding_kind") == "MAPPED"]
        assert_equal("the certified mapping relation survives the export",
                     (mapped[0]["identity_binding"]["mapping"]["certification_status"]
                      if mapped else None), "CERTIFIED")

        build_model(con, MIRROR, published=True)
        mirror_applied = apply_document(
            con, MIRROR, {"entities": exported}, False)
        assert_equal("the exported document applies to an equivalent model",
                     mirror_applied["status"], "OK")
        assert_equal("round-trip: the two models export the same document",
                     export_document(con, MIRROR), exported)
        print("ok export -> apply -> export is identical")

        # ---- a failure part-way through rolls everything back ---------------
        broken = fused_document()
        broken["entities"]["customer"]["representations"].append({
            "name": "broken", "source_kind": "RELATION", "source_schema": SCHEMA,
            "source_object": "NO_SUCH_TABLE_XYZ", "priority": 40})
        before = export_document(con, MODEL)
        rolled = apply_document(con, MODEL, broken, False)
        if rolled["status"] != "ERROR":
            raise AssertionError(f"a missing source table was accepted: {rolled}")
        assert_equal("the failed document left the fusion layer untouched",
                     export_document(con, MODEL), before)
        assert_equal("the failed document added no representation",
                     representation_count(con, MODEL), 2)
        print("ok a document that fails part-way is rolled back whole")

        # ---- the canonical F4 shape: a source narrower than the primary -----
        #
        # A CRM extract carries LOYALTY_TIER and not REGION, so the entity's
        # existing dimension cannot resolve on it. Before representation-scoped
        # attribute_bindings this was unreachable on a published model by any
        # route: the plain form fails SEMANTIC_MODEL_017, the collapsed form
        # fails SEMANTIC_MODEL_040 on the binding it seeds from the primary's
        # expression, and entity-level document bindings arrive after the
        # representation has already been validated and rolled back.
        con.execute(f"CREATE TABLE {SCHEMA}.C_NARROW"
                    " (CUSTOMER_ID DECIMAL(18,0), LOYALTY_TIER VARCHAR(20))")
        con.execute(f"INSERT INTO {SCHEMA}.C_NARROW VALUES (1,'GOLD'),(2,'SILVER')")
        build_model(con, NARROW, published=True)
        # The entity has an F5 identity, so the new source must bind to it too --
        # which makes this the full shape: identity, authority and the bindings
        # that make a narrower source resolvable, all in one candidate.
        narrow = {"entities": {"customer": {
            "identity": {"name": "cid", "kind": "GLOBAL",
                         "data_type": "DECIMAL(18,0)"},
            "representations": [{
                "name": "narrow", "source_kind": "RELATION", "source_schema": SCHEMA,
                "source_object": "C_NARROW", "priority": 40,
                "authority": "SUPPLEMENTAL",
                "identity_binding": {"source_expression": "c.customer_id",
                                     "binding_kind": "DIRECT"},
                "attribute_bindings": [{
                    "attribute_type": "DIMENSION", "attribute_name": "cname",
                    "source_expression": "CAST(NULL AS VARCHAR(50))",
                    "binding_role": "FALLBACK", "binding_priority": 2}]}]}}}

        # Without the bindings it must still be refused -- otherwise this test
        # would pass for the wrong reason.
        without = json.loads(json.dumps(narrow))
        del without["entities"]["customer"]["representations"][0]["attribute_bindings"]
        refused = apply_document(con, NARROW, without, True)
        if refused["status"] != "ERROR":
            raise AssertionError(
                "a narrower source was accepted with no binding declared; the "
                f"fixture no longer exercises the gap: {refused}")
        print("ok a narrower source is still refused when it declares no binding")

        with_bindings = apply_document(con, NARROW, narrow, False)
        if with_bindings["status"] != "OK":
            raise AssertionError(
                f"narrower source refused: {with_bindings['message'][:400]}")
        assert_equal("the null-cast fallback is what landed",
                     scalar(con,
                            "SELECT b.SOURCE_EXPRESSION FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS b"
                            " JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS r"
                            "   ON r.REPRESENTATION_ID = b.REPRESENTATION_ID"
                            " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = b.MODEL_ID"
                            f" WHERE m.MODEL_NAME = {literal(NARROW)}"
                            " AND r.REPRESENTATION_NAME = 'narrow'"
                            " AND b.STATUS = 'ACTIVE'"),
                     "CAST(NULL AS VARCHAR(50))")
        # And it survives a round-trip, so the document remains the record.
        exported_narrow = export_document(con, NARROW)
        narrow_rep = [r for r in exported_narrow["customer"]["representations"]
                      if r.get("name") == "narrow"]
        assert_equal("the narrower source exports", len(narrow_rep), 1)

        # An attribute the entity does not have leaves nothing behind.
        bogus = json.loads(json.dumps(narrow))
        bogus["entities"]["customer"]["representations"][0]["name"] = "narrow2"
        bogus["entities"]["customer"]["representations"][0][
            "attribute_bindings"][0]["attribute_name"] = "no_such_attribute"
        before_bogus = representation_count(con, NARROW)
        rejected_bogus = apply_document(con, NARROW, bogus, False)
        if rejected_bogus["status"] != "ERROR" or \
                "SEMANTIC_ADMIN_217" not in rejected_bogus["message"]:
            raise AssertionError(
                f"an unknown attribute name was accepted: {rejected_bogus}")
        assert_equal("the refused binding registered no representation",
                     representation_count(con, NARROW), before_bogus)
        print("ok an unknown attribute in a representation binding is refused clean")

        # ---- closed contract ------------------------------------------------
        typo = fused_document()
        typo["entities"]["customer"]["representations"][0]["authorityy"] = "PREFER"
        refused = apply_document(con, MODEL, typo, True)
        if refused["status"] != "ERROR" or "SEMANTIC_FUSION_011" not in refused["message"]:
            raise AssertionError(f"a misspelled key was not refused by name: {refused}")
        print("ok a misspelled declaration key is refused by name")

        wrong_model = fused_document()
        wrong_model["model"] = "some_other_model"
        refused = apply_document(con, MODEL, wrong_model, True)
        if refused["status"] != "ERROR" or "SEMANTIC_FUSION_015" not in refused["message"]:
            raise AssertionError(
                f"a document naming another model was applied anyway: {refused}")
        print("ok a document that names a different model is refused")

        orphan = {"entities": {"customer": {"representations": [{
            "name": "orphan", "source_kind": "RELATION", "source_schema": SCHEMA,
            "source_object": "C_CRM", "priority": 50,
            "identity_binding": {"source_expression": "c.account_id",
                                 "binding_kind": "DIRECT"}}]}}}
        refused = apply_document(con, MODEL, orphan, True)
        if refused["status"] != "ERROR" or "SEMANTIC_FUSION_014" not in refused["message"]:
            raise AssertionError(
                f"an identity binding with no identity was accepted: {refused}")
        print("ok an identity binding without an identity is refused")

        # ---- and the fused model still answers correctly --------------------
        request = {"model": MODEL, "object": "C360", "dimensions": ["cname"]}
        statement = con.execute(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON("
            f"{literal(json.dumps(request))})")
        names = [name.lower() for name in statement.columns().keys()]
        result = dict(zip(names, statement.fetchone()))
        assert_equal("the fused model still compiles", result["status"], "OK")
        rows = {str(row[0]) for row in execute(con, result["generated_sql"])}
        assert_equal("the fused model returns the resolved names", rows, {"Alice", "Bob"})

        print("fusion declaration document verified")
        return 0
    finally:
        for model in (NARROW, MIRROR, MODEL):
            try:
                execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({literal(model)})")
            except Exception:  # noqa: BLE001 - best effort
                pass
        try:
            con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        finally:
            con.close()


if __name__ == "__main__":
    raise SystemExit(main())
