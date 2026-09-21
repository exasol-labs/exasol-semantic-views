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
COVERED = "fusion_decl_coverage"
FEWKEYS = "fusion_decl_fewkeys"


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


def export_raw(con: Any, model: str, entity: str | None = None) -> tuple:
    """The single export row: (scope_kind, scope_name, representation_count, json)."""
    rows = execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_FUSION_DECLARATION("
        f"{literal(model)}, {literal(entity) if entity else 'NULL'})")
    if len(rows) != 1:
        raise AssertionError(
            f"export must be one document, got {len(rows)} rows -- a caller "
            "should never have to merge them client-side")
    return rows[0]


def export_document(con: Any, model: str) -> dict:
    """The whole model's fusion layer as one comparable object."""
    document = json.loads(str(export_raw(con, model)[3]))
    return document.get("entities") or {}


def representation_count(con: Any, model: str) -> int:
    return int(scalar(
        con,
        "SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r"
        " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = r.MODEL_ID"
        f" WHERE m.MODEL_NAME = {literal(model)} AND r.STATUS = 'ACTIVE'") or 0)


def build_sources(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    # OPENED_AT exists so the coverage case below can declare a canonical
    # half-open partition; SEMANTIC_MODEL_042 requires the predicate to be
    # `<qualified column> < / >= TIMESTAMP '...'` matching the declared bounds.
    con.execute(f"CREATE TABLE {SCHEMA}.C_MDM (CUSTOMER_ID DECIMAL(18,0), NAME VARCHAR(50), OPENED_AT TIMESTAMP)")
    # CUSTOMER_ID as well as ACCOUNT_ID: the identity cases below map one to the
    # other through XREF, but the coverage case has no identity -- and without one
    # an alternate has to expose the entity's own key (SEMANTIC_MODEL_036).
    con.execute(f"CREATE TABLE {SCHEMA}.C_CRM (ACCOUNT_ID VARCHAR(20), NAME VARCHAR(50),"
                f" OPENED_AT TIMESTAMP, CUSTOMER_ID DECIMAL(18,0))")
    con.execute(f"CREATE TABLE {SCHEMA}.XREF (ACCOUNT_ID VARCHAR(20), CUSTOMER_ID DECIMAL(18,0))")
    con.execute(f"INSERT INTO {SCHEMA}.C_MDM VALUES "
                f"(1,'Alice',TIMESTAMP '2025-06-01 00:00:00'),"
                f"(2,'Bob',TIMESTAMP '2025-07-01 00:00:00')")
    con.execute(f"INSERT INTO {SCHEMA}.C_CRM VALUES "
                f"('A-1','Alice',TIMESTAMP '2026-06-01 00:00:00',1),"
                f"('A-2','Bob',TIMESTAMP '2026-07-01 00:00:00',2)")
    con.execute(f"INSERT INTO {SCHEMA}.XREF VALUES ('A-1',1),('A-2',2)")


def build_model(con: Any, model: str, published: bool,
                with_identity: bool = True) -> None:
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
    ) + ((
        f"ADD_SEMANTIC_IDENTITY({literal(model)}, 'customer', 'cid', 'GLOBAL',"
        f" 'DECIMAL(18,0)', 'Certified identity')",
        f"ADD_IDENTITY_BINDING({literal(model)}, 'cid', 'primary', 'c.customer_id', 'DIRECT')",
    ) if with_identity else ()):
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

        # Convergence has to hold for a document carrying an attribute *policy*
        # too: that operation had no comparison, so five of six reported "already
        # matches" while it kept APPLIED_COUNT at 1 forever -- a permanent false
        # positive for any CI check reading that as drift.
        execute(con,
                "EXECUTE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY("
                f"{literal(MODEL)}, 'DIMENSION', 'cname', 'PREFER')")
        with_policy = export_document(con, MODEL)
        if not (with_policy.get("customer") or {}).get("attribute_policies"):
            raise AssertionError(
                f"fixture no longer exports a policy: {with_policy}")
        for attempt in range(1, 4):
            converged = apply_document(con, MODEL, {"entities": with_policy}, False)
            assert_equal(f"a document with a policy converges (apply #{attempt})",
                         [converged["status"], int(converged["applied"])], ["OK", 0])
        if "nothing to do" not in again["message"]:
            raise AssertionError(f"a no-op apply should say so: {again['message']}")
        print("ok an already-applied document reports nothing to do")

        # ---- the export contract --------------------------------------------
        #
        # "The whole tier-2 layer of a model, as one JSON document" has to be
        # literally true, or a caller has to merge rows the docs never mention.
        # And `model` has to be present *always*: SEMANTIC_FUSION_015 reads that
        # key to refuse a document applied to the wrong model, and the first
        # version of this export emitted it only when there was no fusion -- so
        # the guard could never fire on an exported-then-reapplied file, which is
        # the one workflow it exists for.
        scope_kind, scope_name, reps, payload = export_raw(con, MODEL)
        assert_equal("a whole-model export is one MODEL row", scope_kind, "MODEL")
        assert_equal("named for the model", scope_name, MODEL)
        whole = json.loads(str(payload))
        assert_equal("the document always names its model", whole.get("model"), MODEL)
        assert_equal("representation count is the document's total", int(reps),
                     sum(len(e["representations"]) for e in whole["entities"].values()))
        # An empty entities map is an object, not an array: one JSON type per
        # field, or every consumer has to handle both.
        assert_equal("an unfused model exports entities as an object",
                     str(export_raw(con, "sales")[3]),
                     '{"entities":{},"model":"sales"}')
        entity_scope = export_raw(con, MODEL, "customer")
        assert_equal("asking for one entity says so", entity_scope[0], "ENTITY")
        assert_equal("and still returns a complete document",
                     json.loads(str(entity_scope[3])).get("model"), MODEL)

        # The guard is now reachable where it matters: an exported file carries
        # the model name, so applying it to the wrong model is refused.
        wrong = execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION("
            f"{literal('sales')}, {literal(json.dumps(whole))}, TRUE)")
        if str(wrong[0][0]) != "ERROR" or "SEMANTIC_FUSION_015" not in str(wrong[0][2]):
            raise AssertionError(
                f"an exported document was accepted by another model: {wrong[0]}")
        print("ok an exported document is refused by a model it does not name")

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

        unknown_entity = apply_document(
            con, MODEL, {"entities": {"nosuchentity": {"representations": []}}}, True)
        if unknown_entity["status"] != "ERROR" or \
                "SEMANTIC_FUSION_018" not in unknown_entity["message"]:
            raise AssertionError(
                "a typo'd entity name was ignored -- the likeliest error in a "
                f"hand-edited document: {unknown_entity}")
        print("ok an entity the model does not have is refused by name")

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

        # A representation-scoped `coverage`, which docs/data-fusion.md presents
        # as one of the three ways to complete an alternate. It could never be
        # applied: the document builds the batch entry the coverage script wants
        # but left off the representation it is about, so every such declaration
        # came back as "COVERAGE_JSON[1].representation_name is required" -- for a
        # name the author had no way to supply, because the document schema has
        # no field for it. The enclosing representation *is* the subject, which
        # is the contract that page states and that `attribute_bindings` already
        # kept.
        # A representation-scoped `coverage`, which docs/data-fusion.md presents
        # as one of the three ways to complete an alternate, and which could
        # never be applied.
        #
        # Its own model, because temporal coverage and a certified semantic
        # identity are mutually exclusive on one entity (SEMANTIC_MODEL_047) and
        # the fixture above has an identity.
        CUT = "2026-01-01 00:00:00"
        build_model(con, COVERED, published=True, with_identity=False)

        def coverage_document(crm_coverage: dict, primary_coverage=None) -> dict:
            representations = [{
                "name": "crm", "source_kind": "RELATION", "source_schema": SCHEMA,
                "source_object": "C_CRM", "priority": 20,
                "coverage": crm_coverage}]
            if primary_coverage is not None:
                representations.insert(0, {
                    "name": "primary", "source_kind": "RELATION",
                    "source_schema": SCHEMA, "source_object": "C_MDM",
                    "priority": 10, "coverage": primary_coverage})
            document = {"entities": {"customer": {
                "representations": representations}}}
            if primary_coverage is not None:
                # A partitioned set needs every attribute bound on every
                # partition (SEMANTIC_MODEL_052) -- the compiler clones each leaf
                # branch per partition, so an attribute missing from one of them
                # has nothing to read there.
                document["entities"]["customer"]["attribute_bindings"] = [{
                    "attribute_type": "DIMENSION", "attribute_name": "cname",
                    "representation": "crm", "source_expression": "c.name",
                    "binding_role": "PREFER", "binding_priority": 1}]
            return document

        # Coverage is all-or-nothing by design -- a partitioned set cannot be
        # initialized one representation at a time -- so naming only the new
        # representation is refused, and says which one is missing. Before, it
        # asked for `COVERAGE_JSON[1].representation_name`: a field the document
        # schema does not have, naming nothing the author could supply.
        partial = apply_document(con, COVERED, coverage_document(
            {"valid_from": CUT, "predicate": f"c.opened_at >= TIMESTAMP '{CUT}'"}),
            dry_run=False)
        assert_equal("coverage for one representation names the one it lacks",
                     "missing: primary" in str(partial["message"]), True)
        assert_equal("and not a field the document cannot carry",
                     "representation_name" in str(partial["message"]), False)

        # The whole partition, which is what the batch has always wanted. This is
        # the route the report found unreachable.
        result = apply_document(con, COVERED, coverage_document(
            {"valid_from": CUT, "predicate": f"c.opened_at >= TIMESTAMP '{CUT}'"},
            {"valid_to": CUT, "predicate": f"c.opened_at < TIMESTAMP '{CUT}'"}),
            dry_run=False)
        assert_equal("a representation-scoped coverage applies",
                     (result["status"], result["error_code"]), ("OK", None))
        stored = execute(con, (
            "SELECT r.REPRESENTATION_NAME, r.COVERAGE_PREDICATE"
            " FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS r"
            " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = r.MODEL_ID"
            f" WHERE UPPER(m.MODEL_NAME) = UPPER({literal(COVERED)})"
            " AND r.STATUS = 'ACTIVE' AND r.COVERAGE_PREDICATE IS NOT NULL"))
        assert_equal("and lands on both representations", len(stored), 2)

        # Re-applying the same document is a no-op, which is the contract the
        # whole document form is built on. It also proves coverage reaches a
        # representation that already exists: that path carried authority and
        # identity and dropped coverage silently -- accepted, applied nothing,
        # reported OK.
        again = apply_document(con, COVERED, coverage_document(
            {"valid_from": CUT, "predicate": f"c.opened_at >= TIMESTAMP '{CUT}'"},
            {"valid_to": CUT, "predicate": f"c.opened_at < TIMESTAMP '{CUT}'"}),
            dry_run=False)
        assert_equal("re-applying it changes nothing",
                     (again["status"], again["applied"]), ("OK", 0))

        # ---- narrower in *rows*, which is a different failure ---------------
        #
        # The case above is narrower in columns: the same customers, fewer
        # attributes, which representation-scoped FALLBACK bindings settle. A
        # source that carries fewer *keys* fails SEMANTIC_MODEL_038 instead, and
        # its message used to offer the same three completions as everything
        # else -- of which one was broken (the coverage route above), one does
        # not apply (bindings are about columns), and one refuses on its own
        # grounds (SEMANTIC_MODEL_049). A reader was sent round all three.
        con.execute(f"CREATE TABLE {SCHEMA}.C_PARTIAL"
                    " (CUSTOMER_ID DECIMAL(18,0), LOYALTY_TIER VARCHAR(20))")
        con.execute(f"INSERT INTO {SCHEMA}.C_PARTIAL VALUES (1,'GOLD')")
        # Without a semantic identity, so the key-set comparison that answers is
        # SEMANTIC_MODEL_038. With one, the identity's own key-set check answers
        # first (SEMANTIC_MODEL_049) -- which is the report's point: the same
        # source is refused by a different rule depending on which route you try,
        # and none of the routes _038 offered could settle it.
        build_model(con, FEWKEYS, published=True, with_identity=False)
        partial_doc = {"entities": {"customer": {
            "representations": [{
                "name": "partial", "source_kind": "RELATION",
                "source_schema": SCHEMA, "source_object": "C_PARTIAL",
                "priority": 50, "authority": "SUPPLEMENTAL",
                "attribute_bindings": [{
                    "attribute_type": "DIMENSION", "attribute_name": "cname",
                    "source_expression": "CAST(NULL AS VARCHAR(50))",
                    "binding_role": "FALLBACK", "binding_priority": 3}]}]}}}
        fewer_keys = apply_document(con, FEWKEYS, partial_doc, dry_run=True)
        message = str(fewer_keys["message"])
        assert_equal("a source with fewer keys is refused",
                     fewer_keys["status"], "ERROR")
        assert_equal("and the refusal says it is about rows, not columns",
                     "difference in rows, not in columns" in message, True)
        assert_equal("and names the route that works",
                     "LEFT JOINs it onto the primary's keys" in message, True)
        # The three it used to offer, one of which cannot help here.
        assert_equal("and no longer offers attribute bindings as a completion",
                     "attribute bindings with ADD_ATTRIBUTE_BINDING" in message,
                     False)

        print("fusion declaration document verified")
        return 0
    finally:
        for model in (FEWKEYS, COVERED, NARROW, MIRROR, MODEL):
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
