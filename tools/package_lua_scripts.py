#!/usr/bin/env python3
"""Package Lua runtime sources into Exasol CREATE SCRIPT install SQL."""

from __future__ import annotations

import hashlib
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALL_SQL = ROOT / "sql/install/003_create_semantic_admin_scripts.sql"
AGENT_INSTALL_SQL = ROOT / "sql/install/006_create_semantic_agent_views.sql"
COMPILER_SOURCE = ROOT / "lua/semantic_layer/compiler/request_json.lua"
MATERIALIZATIONS_SOURCE = ROOT / "lua/semantic_layer/compiler/materializations.lua"
VALIDATOR_SOURCE = ROOT / "lua/semantic_layer/admin/validator.lua"
JSON_SOURCE = ROOT / "lua/semantic_layer/shared/json.lua"
ROWS_SOURCE = ROOT / "lua/semantic_layer/shared/rows.lua"
SQL_TEXT_SOURCE = ROOT / "lua/semantic_layer/shared/sql_text.lua"
CATALOG_ROLLBACK_SOURCE = ROOT / "lua/semantic_layer/shared/catalog_rollback.lua"
GRAIN_GRAPH_SOURCE = ROOT / "lua/semantic_layer/shared/grain_graph.lua"
SOURCE_COLUMNS_SOURCE = ROOT / "lua/semantic_layer/shared/source_columns.lua"
IDENTITY_JOIN_SOURCE = ROOT / "lua/semantic_layer/shared/identity_join.lua"
QUERY_SPEC_SOURCE = ROOT / "lua/semantic_layer/compiler/query_spec.lua"
CATALOG_SNAPSHOT_SOURCE = ROOT / "lua/semantic_layer/compiler/catalog_snapshot.lua"
METRIC_PLAN_SOURCE = ROOT / "lua/semantic_layer/compiler/metric_plan.lua"
PHYSICAL_PLAN_SOURCE = ROOT / "lua/semantic_layer/compiler/physical_plan.lua"
GRAIN_SQL_SOURCE = ROOT / "lua/semantic_layer/compiler/grain_sql.lua"
SEMANTIC_DEFINITION_SOURCE = ROOT / "lua/semantic_layer/admin/semantic_definition.lua"
FUSION_DECLARATION_SOURCE = ROOT / "lua/semantic_layer/admin/fusion_declaration.lua"
AGENT_SOURCE = ROOT / "lua/semantic_layer/agent/runtime.lua"

BEGIN = "-- BEGIN GENERATED COMPILER_RUNTIME"
END = "-- END GENERATED COMPILER_RUNTIME"
VALIDATOR_BEGIN = "-- BEGIN GENERATED VALIDATOR_RUNTIME"
VALIDATOR_END = "-- END GENERATED VALIDATOR_RUNTIME"
SEMANTIC_BEGIN = "-- BEGIN GENERATED SEMANTIC_DEFINITION_RUNTIME"
SEMANTIC_END = "-- END GENERATED SEMANTIC_DEFINITION_RUNTIME"

FUSION_BEGIN = "-- BEGIN GENERATED FUSION_RUNTIME"
FUSION_END = "-- END GENERATED FUSION_RUNTIME"
SCRIPT_PARAMETERS_BEGIN = "-- BEGIN GENERATED ADMIN_SCRIPT_PARAMETERS"
SCRIPT_PARAMETERS_END = "-- END GENERATED ADMIN_SCRIPT_PARAMETERS"
CATALOG_VIEWS_SQL = ROOT / "sql/install/002_create_semantic_catalog_views.sql"
SOURCE_VIEWS_SQL = ROOT / "sql/install/007_create_semantic_source_views.sql"
SOURCE_VIEWS_BEGIN = "-- BEGIN GENERATED SEMANTIC_SOURCE_VIEWS"
SOURCE_VIEWS_END = "-- END GENERATED SEMANTIC_SOURCE_VIEWS"

# The two views 007 writes by hand. Everything else in SEMANTIC_SOURCE is
# generated, so a reference to anything not in this set must resolve to a
# catalog table or the build fails.
SOURCE_VIEWS_HANDWRITTEN = {"EFFECTIVE_PRINCIPAL", "AUTHORIZED_MODELS", "MODEL_RELATIONS",
                            "MY_AGENT_REQUESTS", "MY_QUERY_LOG"}

# The compiler modules whose catalog reads define the scoped surface. The admin
# modules are deliberately absent: VALIDATE_MODEL and the authoring scripts are
# run by modellers against SYS_SEMANTIC, and scoping them would hide a model
# from the person maintaining it.
SOURCE_VIEW_READERS = [
    ROOT / "lua/semantic_layer/compiler/request_json.lua",
    ROOT / "lua/semantic_layer/compiler/materializations.lua",
    ROOT / "lua/semantic_layer/compiler/query_spec.lua",
    ROOT / "lua/semantic_layer/compiler/catalog_snapshot.lua",
    ROOT / "lua/semantic_layer/compiler/metric_plan.lua",
    ROOT / "lua/semantic_layer/compiler/physical_plan.lua",
    ROOT / "lua/semantic_layer/compiler/grain_sql.lua",
]

# A child table carries no MODEL_ID, so it is scoped through the parent that
# does. This is the one part that cannot be derived: it is the foreign key, and
# the FK constraints are declared DISABLE with no column metadata a generator
# could read back. Maps table -> (parent table, shared key column).
SOURCE_VIEW_PARENT_SCOPE = {
    "MATERIALIZATION_COLUMNS":   ("MATERIALIZATIONS", "MATERIALIZATION_ID"),
    "METRIC_DEPENDENCIES":       ("METRICS", "METRIC_ID"),
    "METRIC_FILTERS":            ("METRICS", "METRIC_ID"),
    "METRIC_INPUTS":             ("METRICS", "METRIC_ID"),
    "OBJECT_COLUMNS":            ("SEMANTIC_OBJECTS", "OBJECT_ID"),
    "RELATIONSHIP_KEY_MAPPINGS": ("RELATIONSHIPS", "RELATIONSHIP_ID"),
    "UNIQUE_KEY_COLUMNS":        ("UNIQUE_KEYS", "UNIQUE_KEY_ID"),
}

SOURCE_VIEW_REFERENCE = re.compile(r"\bSEMANTIC_SOURCE\.([A-Z_0-9]+)")

# The authorization rule, written once and expanded into every generated view.
# Kept as a subquery over MODEL_ID so a view body stays `SELECT * FROM <table>
# WHERE MODEL_ID IN (...)` -- readable, and identical in every view.
AUTHORIZED_MODEL_IDS = """SELECT m.MODEL_ID FROM SYS_SEMANTIC.MODELS m
       WHERE NOT EXISTS (SELECT 1 FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS g
                          WHERE g.MODEL_ID = m.MODEL_ID AND g.STATUS = 'ACTIVE')
          OR UPPER(m.OWNER_ROLE) = UPPER(CURRENT_USER)
          OR UPPER(m.OWNER_ROLE) IN (SELECT UPPER(ROLE_NAME) FROM EXA_SESSION_ROLES)
          OR EXISTS (SELECT 1 FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS g
                      WHERE g.MODEL_ID = m.MODEL_ID AND g.STATUS = 'ACTIVE'
                        AND (UPPER(g.ROLE_NAME) = UPPER(CURRENT_USER)
                             OR UPPER(g.ROLE_NAME) = 'PUBLIC'
                             OR UPPER(g.ROLE_NAME) IN (SELECT UPPER(ROLE_NAME)
                                                         FROM EXA_SESSION_ROLES)))
          OR EXISTS (SELECT 1 FROM EXA_SESSION_ROLES WHERE ROLE_NAME = 'DBA')"""


def source_view_tables() -> list[str]:
    """Every SYS_SEMANTIC table the compiler reads through SEMANTIC_SOURCE."""
    found: set[str] = set()
    for path in SOURCE_VIEW_READERS:
        for name in SOURCE_VIEW_REFERENCE.findall(path.read_text(encoding="utf-8")):
            if name not in SOURCE_VIEWS_HANDWRITTEN:
                found.add(name)
    return sorted(found)


def source_views_block() -> str:
    """One thin, principal-scoped view per table, derived from the reads above.

    `SELECT *` rather than a column list on purpose: the view is re-created by
    every install, so it tracks the table instead of restating it, and a column
    added to 001 needs no second edit here.

    The authorization predicate is expanded into each view rather than left as a
    reference to SEMANTIC_SOURCE.AUTHORIZED_MODELS. That is a measured choice,
    not a stylistic one: every view layer costs about five milliseconds of fixed
    planning overhead in Exasol, and load_catalog runs seventeen statements on a
    cold compile, so the indirection cost more than the whole rest of the
    filter. It is still written once -- here -- and AUTHORIZED_MODELS remains the
    readable statement of the same rule, with a test asserting the two agree.
    """
    catalog = (ROOT / "sql/install/001_create_semantic_catalog.sql").read_text(encoding="utf-8")
    lines = []
    for table in source_view_tables():
        if f"SYS_SEMANTIC.{table} (" not in catalog:
            raise SystemExit(
                f"SEMANTIC_SOURCE.{table} is read by the compiler but "
                f"SYS_SEMANTIC.{table} is not created by 001")
        lines.append(f"CREATE OR REPLACE VIEW SEMANTIC_SOURCE.{table} AS")
        lines.append(f"SELECT * FROM SYS_SEMANTIC.{table}")
        if table in SOURCE_VIEW_PARENT_SCOPE:
            parent, key = SOURCE_VIEW_PARENT_SCOPE[table]
            lines.append(f" WHERE {key} IN (SELECT {key} FROM SYS_SEMANTIC.{parent}")
            lines.append(f"                  WHERE MODEL_ID IN ({AUTHORIZED_MODEL_IDS}));")
        else:
            lines.append(f" WHERE MODEL_ID IN ({AUTHORIZED_MODEL_IDS});")
        lines.append("")
    body = "\n".join(lines).rstrip()
    # The markers are part of the block: replace_between_markers consumes them.
    return f"""{SOURCE_VIEWS_BEGIN}
{body}

-- Every physical relation this model's compiled SQL may read, in one view.
--
-- The compile cache checks a cached statement against this set before serving
-- it (see compile_cache.trust_boundary). That check runs on every cache hit, so
-- it reads one view carrying the authorization filter once rather than three
-- tables carrying it three times.
--
-- The three sources are the declarations a planner can turn into a FROM clause:
-- an entity's representation, a materialization substituted for one, and an F5
-- identity mapping relation joined into one. It is created after the views it
-- reads, which is why it lives at the end of the generated block.
CREATE OR REPLACE VIEW SEMANTIC_SOURCE.MODEL_RELATIONS AS
SELECT VERSION_ID, 'REPRESENTATION' AS RELATION_KIND,
       SOURCE_SCHEMA AS RELATION_SCHEMA, SOURCE_OBJECT AS RELATION_OBJECT
  FROM SEMANTIC_SOURCE.ENTITY_REPRESENTATIONS WHERE STATUS = 'ACTIVE'
UNION ALL
SELECT VERSION_ID, 'MATERIALIZATION', PHYSICAL_SCHEMA, PHYSICAL_OBJECT
  FROM SEMANTIC_SOURCE.MATERIALIZATIONS WHERE STATUS = 'ACTIVE'
UNION ALL
SELECT VERSION_ID, 'IDENTITY_MAPPING', SOURCE_SCHEMA, SOURCE_OBJECT
  FROM SEMANTIC_SOURCE.IDENTITY_MAPPING_RELATIONS WHERE STATUS = 'ACTIVE';
{SOURCE_VIEWS_END}
"""
# A callable admin script, with or without a RETURNS clause.
#
# Requiring `RETURNS` used to be the whole bug: the mutators that "complete
# without returning rows" (CREATE_MODEL, ADD_ENTITY, ADD_RELATIONSHIP, ...) are
# declared `) AS`, so nine callable APIs were silently absent from the published
# signatures -- and CALL_ADMIN_JSON resolves names from nothing else, so the
# named-call path could not perform the first five steps of the documented
# bootstrap. The exclusion was systematic rather than incidental, which is why it
# went unnoticed: every script it hit was one that returns no rows.
SCRIPT_SIGNATURE = re.compile(
    r"CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN\.([A-Z_0-9]+)\s*"
    r"(?:\(([^)]*)\))?\s*(?:\nRETURNS\s+\w+\s*)?\bAS\b",
    re.M,
)

# Every script declaration form, for the drift assertion below. Deliberately
# broader than SCRIPT_SIGNATURE: it has to see the scripts that must *not* be
# published as well as the ones that must.
ANY_SCRIPT_DECLARATION = re.compile(
    r"CREATE OR REPLACE (?:[A-Z]+ )*SCRIPT SEMANTIC_ADMIN\.([A-Z_0-9]+)",
    re.M,
)

# Scripts that exist in SEMANTIC_ADMIN but are not callable APIs, so they carry
# no published signature. Imported as libraries (`import(...)`) or invoked by
# Exasol itself, never by a caller through CALL_ADMIN_JSON.
#
# This list is the reason the assertion below can be strict. A new runtime
# library has to be added here on purpose; anything else that stops being
# published fails packaging instead of going quiet.
NON_CALLABLE_SCRIPTS = frozenset({
    "AGENT_RUNTIME",
    "COMPILER_RUNTIME",
    "MATERIALIZATION_RUNTIME",
    "FUSION_RUNTIME",
    "SEMANTIC_DEFINITION_RUNTIME",
    "SEMANTIC_GUARD",          # LUA SCALAR, called from generated view SQL
    "SEMANTIC_PREPROCESSOR",   # LUA PREPROCESSOR, invoked by the session
    "VALIDATOR_RUNTIME",
})

AGENT_BEGIN = "-- BEGIN GENERATED AGENT_RUNTIME"
AGENT_END = "-- END GENERATED AGENT_RUNTIME"


# Exasol's Lua caps a single function at 200 local variables, and a generated
# runtime script is one `CREATE ... AS` chunk holding several concatenated source
# files -- so the ceiling applies to the *sum* of their top-level locals, not to
# any one file. Exceeding it fails at install time with
#
#   failed to create script: syntax error in line 7202:
#   too many local variables (limit is 200) in main function
#
# which names a line in a generated artefact and no source file. COMPILER_RUNTIME
# reached exactly 200 during the BUG-G03 fix, and adding one helper broke the
# install; the fix was to move that helper into a shared module, which is not a
# move that generalises. Counting here turns the wall into a build error that
# names the script, the count, and the sources it is assembled from.
MAIN_CHUNK_LOCAL_LIMIT = 200

# Report the ceiling before it is hit. A script this close cannot absorb another
# top-level local, which is worth knowing before writing one rather than after.
MAIN_CHUNK_LOCAL_WARN_AT = 190

SCRIPT_BODY = re.compile(
    r"^CREATE OR REPLACE (?:[A-Z]+ )*SCRIPT SEMANTIC_ADMIN\.([A-Z_0-9]+)[^\n]*\n"
    r"(.*?)^/$",
    re.S | re.M,
)

LOCAL_FUNCTION = re.compile(r"local\s+function\s+[\w.:]+")
LOCAL_NAMES = re.compile(r"local\s+([^=]+?)\s*(?:=|$)")


def main_chunk_local_count(body: str) -> int:
    """Locals declared in a script's main chunk.

    Counts declared *names*, not statements, because `local a, b` costs two. A
    declaration at column 0 is in the main chunk and one that is indented is
    inside a function -- true throughout these sources, and validated against the
    real ceiling: this returns exactly 200 for the COMPILER_RUNTIME body that
    Exasol accepted, and 201 for the one it rejected.
    """
    total = 0
    for line in body.splitlines():
        if not line.startswith("local"):
            continue
        if LOCAL_FUNCTION.match(line):
            total += 1
            continue
        names = LOCAL_NAMES.match(line)
        if names:
            total += len([part for part in names.group(1).split(",") if part.strip()])
    return total


def check_main_chunk_locals(path: Path, text: str) -> None:
    over: list[str] = []
    for match in SCRIPT_BODY.finditer(text):
        name, body = match.group(1), match.group(2)
        count = main_chunk_local_count(body)
        if count > MAIN_CHUNK_LOCAL_LIMIT:
            over.append(
                f"{name} declares {count} main-chunk locals"
                f" (limit {MAIN_CHUNK_LOCAL_LIMIT})"
            )
        elif count >= MAIN_CHUNK_LOCAL_WARN_AT:
            headroom = MAIN_CHUNK_LOCAL_LIMIT - count
            print(
                f"      {name}: {count}/{MAIN_CHUNK_LOCAL_LIMIT} main-chunk locals,"
                f" {headroom} left"
            )
    if over:
        raise SystemExit(
            f"package_lua_scripts: {path.name} would not install -- "
            + "; ".join(over)
            + ". Exasol allows 200 locals per function and a runtime script is one"
            " chunk of concatenated sources, so this is their sum. Move a helper"
            " into an existing shared module (lua/semantic_layer/shared/), attach"
            " it to a module table instead of declaring a local, or split the"
            " source file."
        )


def admin_script_parameters_block() -> str:
    """A queryable signature for every callable SEMANTIC_ADMIN script.

    Exasol checks parameter arity in the SQL layer, before a script body runs,
    so a wrong call count can only ever produce `expected N script parameters
    but got M` -- no script name, no parameter name. The signatures are
    therefore published as data, generated from the install SQL itself so they
    cannot drift from the scripts they describe.
    """
    rows: list[str] = []
    published: set[str] = set()
    declared: set[str] = set()
    for path in sorted(
        (ROOT / "sql/install").glob("*.sql"), key=lambda candidate: candidate.name
    ):
        if path.name.startswith("002_"):
            continue
        text = path.read_text(encoding="utf-8")
        declared.update(ANY_SCRIPT_DECLARATION.findall(text))
        for match in SCRIPT_SIGNATURE.finditer(text):
            script_name = match.group(1)
            if script_name in NON_CALLABLE_SCRIPTS:
                continue
            published.add(script_name)
            parameters = [
                parameter.strip()
                for parameter in (match.group(2) or "").split(",")
                if parameter.strip()
            ]
            if not parameters:
                rows.append(
                    f"  ('{script_name}', 0, NULL, NULL, "
                    f"'EXECUTE SCRIPT SEMANTIC_ADMIN.{script_name}()')"
                )
                continue
            template = "EXECUTE SCRIPT SEMANTIC_ADMIN.{}({})".format(
                script_name, ", ".join(f"<{name.lower()}>" for name in parameters)
            )
            escaped_template = template.replace("'", "''")
            for ordinal, parameter in enumerate(parameters, start=1):
                rows.append(
                    f"  ('{script_name}', {len(parameters)}, {ordinal}, "
                    f"'{parameter}', '{escaped_template}')"
                )
    # Enforce the "cannot drift" claim instead of intending it. A callable script
    # that the signature pattern fails to match is invisible to CALL_ADMIN_JSON
    # and to anyone reading the catalog, and the failure is a clean
    # SEMANTIC_ADMIN_100 that looks like the script does not exist.
    unpublished = sorted(declared - published - NON_CALLABLE_SCRIPTS)
    if unpublished:
        raise SystemExit(
            "package_lua_scripts: these SEMANTIC_ADMIN scripts are declared but "
            "publish no signature, so CALL_ADMIN_JSON cannot reach them: "
            + ", ".join(unpublished)
            + ". Either the declaration does not match SCRIPT_SIGNATURE, or the "
            "script is a runtime library and belongs in NON_CALLABLE_SCRIPTS."
        )
    stale = sorted(NON_CALLABLE_SCRIPTS - declared)
    if stale:
        raise SystemExit(
            "package_lua_scripts: NON_CALLABLE_SCRIPTS lists scripts that no "
            "longer exist: " + ", ".join(stale) + ". Remove them so the list "
            "cannot hide a future script of the same name."
        )

    body = ",\n".join(rows)
    return f"""{SCRIPT_PARAMETERS_BEGIN}
CREATE OR REPLACE VIEW SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS AS
SELECT
  CAST(SCRIPT_NAME AS VARCHAR(128)) AS SCRIPT_NAME,
  CAST(PARAMETER_COUNT AS DECIMAL(18,0)) AS PARAMETER_COUNT,
  CAST(ORDINAL_POSITION AS DECIMAL(18,0)) AS ORDINAL_POSITION,
  CAST(PARAMETER_NAME AS VARCHAR(128)) AS PARAMETER_NAME,
  CAST(CALL_TEMPLATE AS VARCHAR(2000000)) AS CALL_TEMPLATE
FROM (VALUES
{body}
) AS signatures (SCRIPT_NAME, PARAMETER_COUNT, ORDINAL_POSITION, PARAMETER_NAME, CALL_TEMPLATE);
{SCRIPT_PARAMETERS_END}"""


def validator_block() -> str:
    json_source = JSON_SOURCE.read_text(encoding="utf-8").rstrip()
    rows_source = ROWS_SOURCE.read_text(encoding="utf-8").rstrip()
    sql_text_source = SQL_TEXT_SOURCE.read_text(encoding="utf-8").rstrip()
    graph_source = GRAIN_GRAPH_SOURCE.read_text(encoding="utf-8").rstrip()
    source_columns_source = SOURCE_COLUMNS_SOURCE.read_text(encoding="utf-8").rstrip()
    identity_join_source = IDENTITY_JOIN_SOURCE.read_text(encoding="utf-8").rstrip()
    # The validator classifies metrics with the planner's own code so a metric
    # that cannot be planned is rejected when it is defined, not when it is
    # queried. Reimplementing the classification here would let the two drift.
    metric_plan_source = METRIC_PLAN_SOURCE.read_text(encoding="utf-8").rstrip()
    source = VALIDATOR_SOURCE.read_text(encoding="utf-8").rstrip()
    return f"""{VALIDATOR_BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.VALIDATOR_RUNTIME AS
{json_source}

{rows_source}

{sql_text_source}

{graph_source}

{source_columns_source}

{identity_join_source}

{metric_plan_source}

{source}
/
{VALIDATOR_END}"""


# Sources whose content can change what the compiler emits for a given request.
# The materialization runtime is included because the compiler imports it and its
# choices land in the generated SQL.
COMPILE_RELEVANT_SOURCES = (
    "JSON_SOURCE", "ROWS_SOURCE", "SQL_TEXT_SOURCE", "GRAIN_GRAPH_SOURCE",
    "SOURCE_COLUMNS_SOURCE", "IDENTITY_JOIN_SOURCE", "QUERY_SPEC_SOURCE",
    "CATALOG_SNAPSHOT_SOURCE", "METRIC_PLAN_SOURCE", "PHYSICAL_PLAN_SOURCE",
    "GRAIN_SQL_SOURCE", "COMPILER_SOURCE", "MATERIALIZATIONS_SOURCE",
)


def runtime_build_id() -> str:
    """Identity of the compiled runtime, for the compile-cache key.

    `SYS_SEMANTIC.COMPILE_CACHE` maps a request to the SQL a compiler produced
    for it. `VALIDATE_MODEL` clears entries when the *model* changes, and the
    canonical text carries `PLAN_VERSION` so a planner bump invalidates -- but a
    parser or renderer change that leaves that constant alone did not, so a
    cached statement from an older runtime kept being served after the runtime
    was replaced. That is not hypothetical: it happened during the BI
    investigation and silently changed observable results.

    Hashing the sources that determine compiler output gives every build its own
    keyspace, so a stale entry is unreachable rather than wrong. It is also
    content-addressed: rebuilding identical sources yields the same id, so a
    rebuild that changes nothing keeps its warm cache, and a downgrade back to a
    previous runtime finds its own entries again.
    """
    digest = hashlib.sha256()
    for name in COMPILE_RELEVANT_SOURCES:
        path = globals()[name]
        digest.update(name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()[:16]


def compiler_block() -> str:
    json_source = JSON_SOURCE.read_text(encoding="utf-8").rstrip()
    rows_source = ROWS_SOURCE.read_text(encoding="utf-8").rstrip()
    sql_text_source = SQL_TEXT_SOURCE.read_text(encoding="utf-8").rstrip()
    graph_source = GRAIN_GRAPH_SOURCE.read_text(encoding="utf-8").rstrip()
    source_columns_source = SOURCE_COLUMNS_SOURCE.read_text(encoding="utf-8").rstrip()
    identity_join_source = IDENTITY_JOIN_SOURCE.read_text(encoding="utf-8").rstrip()
    query_spec_source = QUERY_SPEC_SOURCE.read_text(encoding="utf-8").rstrip()
    catalog_snapshot_source = CATALOG_SNAPSHOT_SOURCE.read_text(encoding="utf-8").rstrip()
    metric_plan_source = METRIC_PLAN_SOURCE.read_text(encoding="utf-8").rstrip()
    physical_plan_source = PHYSICAL_PLAN_SOURCE.read_text(encoding="utf-8").rstrip()
    grain_sql_source = GRAIN_SQL_SOURCE.read_text(encoding="utf-8").rstrip()
    source = COMPILER_SOURCE.read_text(encoding="utf-8").rstrip()
    materializations_source = MATERIALIZATIONS_SOURCE.read_text(encoding="utf-8").rstrip()
    build_id = runtime_build_id()
    # A global, not a local: the 200-local ceiling applies to the sum of the
    # concatenated sources in one chunk, and this must not spend one of them.
    stamp = f'ESV_RUNTIME_BUILD = "{build_id}"'
    return f"""{BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME AS
{stamp}

{json_source}

{rows_source}

{materializations_source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILER_RUNTIME AS
{stamp}

{json_source}

{rows_source}

{sql_text_source}

{graph_source}

{source_columns_source}

{identity_join_source}

{query_spec_source}

{catalog_snapshot_source}

{metric_plan_source}

{physical_plan_source}

{grain_sql_source}

{source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  REQUEST_JSON
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_request_json(REQUEST_JSON)

exit({{
    {{
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.agent_request_id or null,
    }}
}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  ORIGINAL_SQL VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  CLARIFICATION_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  AGENT_REQUEST_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL(
  ORIGINAL_SQL
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_sql(ORIGINAL_SQL)

exit({{
    {{
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        ORIGINAL_SQL or null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.agent_request_id or null,
    }}
}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  ORIGINAL_SQL VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  CLARIFICATION_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  AGENT_REQUEST_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL_DEBUG(
  ORIGINAL_SQL,
  CLIENT_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_sql_debug(ORIGINAL_SQL, CLIENT_NAME)

exit({{
    {{
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        ORIGINAL_SQL or null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.query_log_id or null,
    }}
}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  ORIGINAL_SQL VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  CLARIFICATION_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  QUERY_LOG_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SUGGEST_GRAIN_METADATA(
  MODEL_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local rows = compiler.suggest_grain_metadata(MODEL_NAME)

exit(rows or {{}}, [[
  SUGGESTION_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(512),
  REASON_CODE VARCHAR(128),
  PROPOSED_METADATA_JSON VARCHAR(2000000)
]])
/
{END}"""


def semantic_definition_block() -> str:
    json_source = JSON_SOURCE.read_text(encoding="utf-8").rstrip()
    rows_source = ROWS_SOURCE.read_text(encoding="utf-8").rstrip()
    rollback_source = CATALOG_ROLLBACK_SOURCE.read_text(encoding="utf-8").rstrip()
    sql_text_source = SQL_TEXT_SOURCE.read_text(encoding="utf-8").rstrip()
    source = SEMANTIC_DEFINITION_SOURCE.read_text(encoding="utf-8").rstrip()
    return f"""{SEMANTIC_BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME AS
{json_source}

{rows_source}

{sql_text_source}

{rollback_source}

{source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  DEFINITION_SQL,
  DRY_RUN
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_semantic_definition(DEFINITION_SQL, DRY_RUN)

exit(rows or {{}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000),
  NORMALIZED_JSON VARCHAR(2000000),
  OPERATION_COUNT DECIMAL(18,0),
  VALIDATION_RUN_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION_OR_FAIL(
  DEFINITION_SQL,
  DRY_RUN
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_semantic_definition(DEFINITION_SQL, DRY_RUN)
local first = rows ~= nil and rows[1] or nil
if first ~= nil and first[1] == "ERROR" then
    local code = first[2] or "SEMANTIC_DDL_999"
    local message = tostring(first[3] or "Semantic definition apply failed.")
    if string.find(message, code, 1, true) == nil then
        message = code .. ": " .. message
    end
    error(message, 0)
end

exit(rows or {{}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000),
  NORMALIZED_JSON VARCHAR(2000000),
  OPERATION_COUNT DECIMAL(18,0),
  VALIDATION_RUN_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.APPLY_NORMALIZED_OSI_IMPORT(
  PLAN_JSON,
  VALIDATE_AFTER_APPLY,
  WARNINGS_AS_ERRORS
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_normalized_osi_import(
    PLAN_JSON,
    VALIDATE_AFTER_APPLY,
    WARNINGS_AS_ERRORS
)

exit(rows or {{}}, [[
  STATUS VARCHAR(32),
  OPERATION_INDEX DECIMAL(18,0),
  OPERATION_NAME VARCHAR(128),
  TARGET VARCHAR(512),
  SOURCE_PATH VARCHAR(2000000),
  ROW_COUNT DECIMAL(18,0),
  WARNING_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  MESSAGE VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(
  YAML_TEXT,
  MODEL_NAME,
  PUBLISHED_SCHEMA,
  APPLY_IMPORT
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.import_databricks_metric_view(
    YAML_TEXT,
    MODEL_NAME,
    PUBLISHED_SCHEMA,
    APPLY_IMPORT
)

exit(rows or {{}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  MODEL_NAME VARCHAR(256),
  GENERATED_DDL VARCHAR(2000000),
  DIAGNOSTICS_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_METRIC(
  MODEL_NAME,
  OBJECT_NAME,
  METRIC_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.describe_semantic_metric(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {{}}, [[
  SECTION_NAME VARCHAR(128),
  PROPERTY_NAME VARCHAR(256),
  PROPERTY_VALUE VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.EXPLAIN_SEMANTIC_METRIC(
  MODEL_NAME,
  OBJECT_NAME,
  METRIC_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.explain_semantic_metric(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {{}}, [[
  SECTION_NAME VARCHAR(128),
  ITEM_NAME VARCHAR(256),
  DETAIL_TEXT VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION(
  MODEL_NAME,
  OBJECT_NAME,
  METRIC_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.export_semantic_definition(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {{}}, [[
  DEFINITION_KIND VARCHAR(64),
  DEFINITION_REF VARCHAR(1024),
  DEFINITION_SQL VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()
RETURNS TABLE AS
query("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR")
exit({{{{"OK", "SESSION", "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR", "Semantic SQL enabled for this session."}}}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(512),
  MESSAGE VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()
RETURNS TABLE AS
query("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
exit({{{{"OK", "SESSION", null, "Semantic SQL disabled for this session."}}}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(512),
  MESSAGE VARCHAR(2000000)
]])
/
{SEMANTIC_END}"""


def fusion_declaration_block() -> str:
    """The tier-2 fusion document surface.

    Its own script rather than more of SEMANTIC_DEFINITION_RUNTIME: that chunk
    is near Exasol's 200 main-chunk locals, and a document format that will grow
    should not spend someone else's headroom.

    It carries shared/json.lua rather than importing the definition runtime for a
    codec. Importing was the cheap way to avoid a fifth copy of the encoder, but
    it made a document format depend on the DDL parser, and it left this module
    holding decoded values whose null sentinel belonged to another module -- so
    an explicit `null` in a declaration was unrecognisable here. Two locals of
    this chunk's budget buy back both.
    """
    json_source = JSON_SOURCE.read_text(encoding="utf-8").rstrip()
    rows_source = ROWS_SOURCE.read_text(encoding="utf-8").rstrip()
    rollback_source = CATALOG_ROLLBACK_SOURCE.read_text(encoding="utf-8").rstrip()
    source = FUSION_DECLARATION_SOURCE.read_text(encoding="utf-8").rstrip()
    return f"""{FUSION_BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.FUSION_RUNTIME AS
{json_source}

{rows_source}

{rollback_source}

{source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.EXPORT_FUSION_DECLARATION(
  MODEL_NAME,
  ENTITY_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.FUSION_RUNTIME", "fusion")

local rows = fusion.export_fusion_declaration(MODEL_NAME, ENTITY_NAME)

exit(rows or {{}}, [[
  SCOPE_KIND VARCHAR(32),
  SCOPE_NAME VARCHAR(256),
  REPRESENTATION_COUNT DECIMAL(18,0),
  DECLARATION_JSON VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION(
  MODEL_NAME,
  DECLARATION_JSON,
  DRY_RUN
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.FUSION_RUNTIME", "fusion")

local rows = fusion.apply_fusion_declaration(MODEL_NAME, DECLARATION_JSON, DRY_RUN)

exit(rows or {{}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000),
  OPERATION_COUNT DECIMAL(18,0),
  APPLIED_COUNT DECIMAL(18,0)
]])
/
{FUSION_END}"""


def agent_block() -> str:
    json_source = JSON_SOURCE.read_text(encoding="utf-8").rstrip()
    rows_source = ROWS_SOURCE.read_text(encoding="utf-8").rstrip()
    source = AGENT_SOURCE.read_text(encoding="utf-8").rstrip()
    return f"""{AGENT_BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.AGENT_RUNTIME AS
{json_source}

{rows_source}

{source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  MODEL_NAME,
  SCOPE_TYPE,
  SCOPE_NAME,
  INSTRUCTION_KIND,
  INSTRUCTION_TEXT,
  APPLIES_TO_ROLE,
  PRIORITY
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.add_agent_instruction(
    MODEL_NAME,
    SCOPE_TYPE,
    SCOPE_NAME,
    INSTRUCTION_KIND,
    INSTRUCTION_TEXT,
    APPLIES_TO_ROLE,
    PRIORITY
)

exit(rows or {{}}, [[
  INSTRUCTION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  SCOPE_TYPE VARCHAR(64),
  SCOPE_NAME VARCHAR(512),
  INSTRUCTION_KIND VARCHAR(64),
  STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY(
  MODEL_NAME,
  OBJECT_NAME,
  QUERY_NAME,
  NATURAL_LANGUAGE_TEXT,
  REQUEST_JSON,
  EXPECTED_RESULT_SHAPE,
  IS_ONBOARDING_EXAMPLE
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.add_verified_query(
    MODEL_NAME,
    OBJECT_NAME,
    QUERY_NAME,
    NATURAL_LANGUAGE_TEXT,
    REQUEST_JSON,
    EXPECTED_RESULT_SHAPE,
    IS_ONBOARDING_EXAMPLE
)

exit(rows or {{}}, [[
  VERIFIED_QUERY_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  QUERY_NAME VARCHAR(512),
  STATUS VARCHAR(32),
  GENERATED_SQL VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS(
  QUERY_TEXT,
  MODEL_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.search_semantic_objects(QUERY_TEXT, MODEL_NAME)

exit(rows or {{}}, [[
  RESULT_TYPE VARCHAR(64),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  FIELD_KIND VARCHAR(64),
  FIELD_NAME VARCHAR(256),
  DISPLAY_NAME VARCHAR(512),
  DESCRIPTION VARCHAR(2000000),
  MATCH_TEXT VARCHAR(2000000),
  SCORE DECIMAL(18,0),
  IS_CERTIFIED BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT(
  MODEL_NAME,
  OBJECT_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.describe_semantic_object(MODEL_NAME, OBJECT_NAME)

exit(rows or {{}}, [[
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  ROW_KIND VARCHAR(64),
  FIELD_KIND VARCHAR(64),
  FIELD_NAME VARCHAR(256),
  SQL_COLUMN_NAME VARCHAR(256),
  DATA_TYPE VARCHAR(128),
  DESCRIPTION VARCHAR(2000000),
  DETAILS_JSON VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY(
  MODEL_NAME,
  OBJECT_NAME,
  QUERY_MODE
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.get_business_glossary(MODEL_NAME, OBJECT_NAME, QUERY_MODE)

exit(rows or {{}}, [[
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  QUERY_MODE VARCHAR(64),
  GLOSSARY_TEXT VARCHAR(2000000),
  GLOSSARY_JSON VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL(
  HANDLE_TYPE,
  HANDLE_ID
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.explain_compiled_sql(HANDLE_TYPE, HANDLE_ID)

exit(rows or {{}}, [[
  HANDLE_TYPE VARCHAR(64),
  HANDLE_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  VERSION_ID DECIMAL(18,0),
  STATUS VARCHAR(64),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  REQUEST_TEXT VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  REQUESTED_DIMENSIONS VARCHAR(2000000),
  REQUESTED_METRICS VARCHAR(2000000),
  SELECTED_MATERIALIZATION VARCHAR(512)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK(
  HANDLE_TYPE,
  HANDLE_ID,
  VERDICT,
  COMMENT_TEXT,
  PROPOSED_CHANGE_JSON
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.record_agent_feedback(
    HANDLE_TYPE,
    HANDLE_ID,
    VERDICT,
    COMMENT_TEXT,
    PROPOSED_CHANGE_JSON
)

exit(rows or {{}}, [[
  FEEDBACK_ID DECIMAL(18,0),
  SUGGESTION_ID DECIMAL(18,0),
  HANDLE_TYPE VARCHAR(64),
  HANDLE_ID DECIMAL(18,0),
  VERDICT VARCHAR(64),
  REVIEW_STATUS VARCHAR(64)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION(
  MODEL_NAME,
  SUGGESTION_KIND,
  OBJECT_TYPE,
  OBJECT_NAME,
  PROPOSED_CHANGE_JSON,
  RATIONALE
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.propose_model_evolution(
    MODEL_NAME,
    SUGGESTION_KIND,
    OBJECT_TYPE,
    OBJECT_NAME,
    PROPOSED_CHANGE_JSON,
    RATIONALE
)

exit(rows or {{}}, [[
  SUGGESTION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  VERSION_ID DECIMAL(18,0),
  SUGGESTION_KIND VARCHAR(64),
  OBJECT_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(512),
  REVIEW_STATUS VARCHAR(64),
  IS_DUPLICATE BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION(
  SUGGESTION_ID,
  DECISION,
  REVIEW_NOTE
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.review_model_evolution(
    SUGGESTION_ID,
    DECISION,
    REVIEW_NOTE
)

exit(rows or {{}}, [[
  SUGGESTION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  VERSION_ID DECIMAL(18,0),
  SUGGESTION_KIND VARCHAR(64),
  REVIEW_STATUS VARCHAR(64),
  REVIEWED_BY VARCHAR(256),
  ACTIVATION_STATUS VARCHAR(64)
]])
/
{AGENT_END}"""


def replace_between_markers(text: str, block: str, begin: str, end: str) -> str:
    if begin in text and end in text:
        before = text[: text.index(begin)]
        after = text[text.index(end) + len(end) :]
        return before.rstrip() + "\n\n" + block + after
    return text.rstrip() + "\n\n" + block + "\n"


def main() -> int:
    original = INSTALL_SQL.read_text(encoding="utf-8")
    updated = replace_between_markers(original, validator_block(), VALIDATOR_BEGIN, VALIDATOR_END)
    updated = replace_between_markers(updated, semantic_definition_block(), SEMANTIC_BEGIN, SEMANTIC_END)
    updated = replace_between_markers(updated, fusion_declaration_block(), FUSION_BEGIN, FUSION_END)
    updated = replace_between_markers(updated, compiler_block(), BEGIN, END)
    check_main_chunk_locals(INSTALL_SQL, updated)
    if updated != original:
        INSTALL_SQL.write_text(updated, encoding="utf-8")
        print(f"updated {INSTALL_SQL.relative_to(ROOT)}")
    else:
        print(f"unchanged {INSTALL_SQL.relative_to(ROOT)}")

    original_catalog = CATALOG_VIEWS_SQL.read_text(encoding="utf-8")
    updated_catalog = replace_between_markers(
        original_catalog, admin_script_parameters_block(),
        SCRIPT_PARAMETERS_BEGIN, SCRIPT_PARAMETERS_END)
    if updated_catalog != original_catalog:
        CATALOG_VIEWS_SQL.write_text(updated_catalog, encoding="utf-8")
        print(f"updated {CATALOG_VIEWS_SQL.relative_to(ROOT)}")
    else:
        print(f"unchanged {CATALOG_VIEWS_SQL.relative_to(ROOT)}")

    original_source = SOURCE_VIEWS_SQL.read_text(encoding="utf-8")
    updated_source = replace_between_markers(
        original_source, source_views_block(), SOURCE_VIEWS_BEGIN, SOURCE_VIEWS_END)
    if updated_source != original_source:
        SOURCE_VIEWS_SQL.write_text(updated_source, encoding="utf-8")
        print(f"updated {SOURCE_VIEWS_SQL.relative_to(ROOT)}")
    else:
        print(f"unchanged {SOURCE_VIEWS_SQL.relative_to(ROOT)}")

    original_agent = AGENT_INSTALL_SQL.read_text(encoding="utf-8")
    updated_agent = replace_between_markers(original_agent, agent_block(), AGENT_BEGIN, AGENT_END)
    check_main_chunk_locals(AGENT_INSTALL_SQL, updated_agent)
    if updated_agent != original_agent:
        AGENT_INSTALL_SQL.write_text(updated_agent, encoding="utf-8")
        print(f"updated {AGENT_INSTALL_SQL.relative_to(ROOT)}")
    else:
        print(f"unchanged {AGENT_INSTALL_SQL.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
