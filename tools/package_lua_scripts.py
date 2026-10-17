#!/usr/bin/env python3
"""Build the install SQL from its sources.

The sources are hand-written, and each language lives in its own files:
`sql/install/*.sql` holds the SQL, including every script's signature, and
`lua/semantic_layer/` holds all Lua -- the runtime libraries, and under
`scripts/` the body of every script. A source file marks what goes where with
one line: `-- @lua <path>` for a script body, `-- @generated <NAME>` for a
generated part. This script writes the complete files to `build/install/`,
which is what the installer runs and the release ships. Nothing generated is
checked in, and no source file holds generated text.

Generated parts:

- one runtime library script per entry of RUNTIMES, concatenated from lua/;
- SEMANTIC_SOURCE_VIEWS, derived from the compiler's catalog reads;
- ADMIN_SCRIPT_PARAMETERS, derived from every script signature in the build.
"""

from __future__ import annotations

import collections
import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import typing
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "sql/install"
BUILD_DIR = ROOT / "build/install"
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
COMPILE_RESULT_SOURCE = ROOT / "lua/semantic_layer/compiler/compile_result.lua"
SEMANTIC_SQL_SYNTAX_SOURCE = ROOT / "lua/semantic_layer/compiler/semantic_sql_syntax.lua"
DATABRICKS_IMPORT_SOURCE = ROOT / "lua/semantic_layer/admin/databricks_import.lua"
SEMANTIC_DEFINITION_SOURCE = ROOT / "lua/semantic_layer/admin/semantic_definition.lua"
FUSION_DECLARATION_SOURCE = ROOT / "lua/semantic_layer/admin/fusion_declaration.lua"
AGENT_SOURCE = ROOT / "lua/semantic_layer/agent/runtime.lua"

SCRIPT_PARAMETERS_BEGIN = "-- BEGIN GENERATED ADMIN_SCRIPT_PARAMETERS"
SCRIPT_PARAMETERS_END = "-- END GENERATED ADMIN_SCRIPT_PARAMETERS"
SOURCE_VIEWS_BEGIN = "-- BEGIN GENERATED SEMANTIC_SOURCE_VIEWS"
SOURCE_VIEWS_END = "-- END GENERATED SEMANTIC_SOURCE_VIEWS"

# The two views 007 writes by hand. Everything else in SEMANTIC_SOURCE is
# generated, so a reference to anything not in this set must resolve to a
# catalog table or the build fails.
SOURCE_VIEWS_HANDWRITTEN = {"EFFECTIVE_PRINCIPAL", "AUTHORIZED_MODELS", "MODEL_RELATIONS",
                            "MY_AGENT_REQUESTS", "MY_QUERY_LOG", "MY_SETTINGS"}

# The compiler modules whose catalog reads define the scoped surface. The admin
# modules are deliberately absent: VALIDATE_MODEL and the authoring scripts are
# run by modellers against SYS_SEMANTIC, and scoping them would hide a model
# from the person maintaining it.
SOURCE_VIEW_READERS = [
    # The human catalog and the agent discovery surface read it as well. Both
    # used to read SYS_SEMANTIC directly and were granted to every caller, so a
    # principal holding one model could read every other model's metric and
    # dimension expressions from the view beside the one that correctly reported
    # the model as not visible.
    ROOT / "sql/install/002_create_semantic_catalog_views.sql",
    ROOT / "sql/install/006_create_semantic_agent_views.sql",
    # The agent runtime reads the scoped log views for EXPLAIN_COMPILED_SQL, so
    # it is scanned too -- otherwise a read it adds would have no view and fail
    # for exactly the non-SYS caller the surface exists for.
    ROOT / "lua/semantic_layer/agent/runtime.lua",
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
    "MODEL_EVOLUTION_REVIEWS":   ("MODEL_EVOLUTION_SUGGESTIONS", "SUGGESTION_ID"),
    "MODEL_EVOLUTION_TARGETS":   ("MODEL_EVOLUTION_SUGGESTIONS", "SUGGESTION_ID"),
    "VALIDATION_RESULTS":        ("VALIDATION_RUNS", "VALIDATION_RUN_ID"),
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
{SOURCE_VIEWS_END}"""
# Every script declaration form, for the drift assertion in
# admin_script_parameters_block: it has to see the scripts that must *not* be
# published as well as the ones that must.
ANY_SCRIPT_DECLARATION = re.compile(
    r"CREATE OR REPLACE (?:[A-Z]+ )*SCRIPT SEMANTIC_ADMIN\.([A-Z_0-9]+)",
    re.M,
)


def non_callable_scripts() -> frozenset[str]:
    """Scripts in SEMANTIC_ADMIN that are not callable APIs, so publish no signature.

    Derived, not listed: the runtime libraries other scripts `import`, and every
    script whose annotation declares a `@kind` other than a scripting script --
    the UDF called from generated view SQL and the preprocessor the session
    invokes. A hand-kept list had to be edited for each new runtime and could
    name a script that no longer existed.
    """
    udfs = {script.name for script in script_registry().values() if script.kind != "scripting"}
    return frozenset(RUNTIMES) | udfs


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

# The body starts after the header's `AS`, not after its first line: a script
# with parameters declares them one per line before `RETURNS ... AS`.
SCRIPT_BODY = re.compile(
    r"^CREATE OR REPLACE (?:[A-Z]+ )*SCRIPT SEMANTIC_ADMIN\.([A-Z_0-9]+)\b[^/]*?\bAS\n"
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


# The count above sees declarations at column 0 only, so it misses what Lua
# actually limits: locals *active at once*. A top-level `do` block's locals are
# active on top of every top-level local declared before it, and code run
# directly in such a block adds its own. COMPILER_RUNTIME was counted at 188
# while its true peak was 197 -- three to spare, not twelve. So where a Lua
# interpreter is available the peak is measured by the compiler itself: prepend
# N unused locals and find the largest N that still compiles; the peak is the
# limit minus N. One interpreter process measures every script of a file.
LUA_PEAK_PROBE = r"""
local limit = tonumber(arg[1])
for path in io.lines(arg[2]) do
    local file = assert(io.open(path))
    local body = file:read("a")
    file:close()
    local function compiles(extra)
        local fn, err = load(string.rep("local _ = 0\n", extra) .. body)
        return fn ~= nil, err
    end
    local ok, err = compiles(0)
    if not ok and tostring(err):find("too many local variables", 1, true) then
        io.write(path, "\tover\n")  -- already past the limit
    elseif not ok then
        io.write(path, "\t?\n")  -- does not compile here for another reason
    else
        local lo, hi = 0, limit
        while lo < hi do
            local mid = (lo + hi + 1) // 2
            if compiles(mid) then lo = mid else hi = mid - 1 end
        end
        io.write(path, "\t", limit - lo, "\n")
    end
end
"""


def lua_interpreter() -> str | None:
    """The interpreter to measure with: LUA_BIN, else lua5.4, else lua."""
    for candidate in (os.environ.get("LUA_BIN"), "lua5.4", "lua"):
        if candidate and shutil.which(candidate):
            return candidate
    return None


def measured_local_peaks(bodies: dict[str, str]) -> dict[str, int]:
    """Peak active main-chunk locals per script, as the Lua compiler sees them.

    Empty when no interpreter is installed; a script that does not compile under
    the local interpreter (Exasol runs Lua 5.4) is left out, so the caller falls
    back to the count for it.
    """
    interpreter = lua_interpreter()
    if interpreter is None or not bodies:
        return {}
    with tempfile.TemporaryDirectory() as scratch:
        paths = {}
        for index, (name, body) in enumerate(bodies.items()):
            target = Path(scratch) / f"{index}.lua"
            target.write_text(body, encoding="utf-8")
            paths[str(target)] = name
        listing = Path(scratch) / "bodies.txt"
        listing.write_text("\n".join(paths) + "\n", encoding="utf-8")
        probe = Path(scratch) / "probe.lua"
        probe.write_text(LUA_PEAK_PROBE, encoding="utf-8")
        result = subprocess.run([interpreter, str(probe), str(MAIN_CHUNK_LOCAL_LIMIT), str(listing)],
                                capture_output=True, text=True, check=False)
    peaks = {}
    for line in result.stdout.splitlines():
        path, _, value = line.partition("\t")
        if value.isdigit():
            peaks[paths[path]] = int(value)
        elif value == "over":
            peaks[paths[path]] = MAIN_CHUNK_LOCAL_LIMIT + 1
    return peaks


def check_main_chunk_locals(path: Path, text: str) -> None:
    over: list[str] = []
    bodies = {match.group(1): match.group(2) for match in SCRIPT_BODY.finditer(text)}
    measured = measured_local_peaks(bodies)
    for name, body in bodies.items():
        count = measured.get(name)
        how = "peak active, measured"
        if count is None:
            count = main_chunk_local_count(body)
            how = "counted; install a Lua interpreter to measure the peak"
        if count > MAIN_CHUNK_LOCAL_LIMIT:
            needs = (f"more than {MAIN_CHUNK_LOCAL_LIMIT} ({main_chunk_local_count(body)}"
                     " declared at the top level)") if name in measured else str(count)
            over.append(
                f"{name} needs {needs} main-chunk locals active at once"
                f" (limit {MAIN_CHUNK_LOCAL_LIMIT}; {how})"
            )
        elif count >= MAIN_CHUNK_LOCAL_WARN_AT:
            headroom = MAIN_CHUNK_LOCAL_LIMIT - count
            print(
                f"      {name}: {count}/{MAIN_CHUNK_LOCAL_LIMIT} main-chunk locals,"
                f" {headroom} left ({how})"
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


def sql_text_literal(text: str) -> str:
    return "'" + text.replace("'", "''") + "'"


def admin_script_parameters_block(built: dict[str, str] | None = None) -> str:
    """A queryable signature for every callable SEMANTIC_ADMIN script.

    Exasol checks parameter arity in the SQL layer, before a script body runs,
    so a wrong call count can only ever produce `expected N script parameters
    but got M` -- no script name, no parameter name. The signatures are
    therefore published as data, generated from the same annotation blocks the
    CREATE SCRIPT statements are generated from, so the two cannot disagree. The
    built files are read only to check that nothing was declared another way.
    """
    if built is None:
        built = assemble_without_parameters()
    registry = script_registry()
    excluded = non_callable_scripts()
    # In installation order: the order the sources' `-- @lua` lines install them.
    installed = [Path(path).stem.upper()
                 for source in sorted(SOURCE_DIR.glob("*.sql"))
                 for path in LUA_BODY.findall(source.read_text(encoding="utf-8"))]
    rows: list[str] = []
    published: set[str] = set()
    declared = {script for name, text in built.items() if not name.startswith("002_")
                for script in ANY_SCRIPT_DECLARATION.findall(text)}
    for script_name in installed:
        if script_name in excluded:
            continue
        published.add(script_name)
        script = registry[script_name]
        parameters = [name for name, _ in script.params]
        summary = sql_text_literal(script.summary)
        if not parameters:
            rows.append(
                f"  ('{script_name}', 0, NULL, NULL, "
                f"'EXECUTE SCRIPT SEMANTIC_ADMIN.{script_name}()', NULL, {summary})"
            )
            continue
        template = "EXECUTE SCRIPT SEMANTIC_ADMIN.{}({})".format(
            script_name, ", ".join(f"<{name.lower()}>" for name in parameters)
        )
        escaped_template = template.replace("'", "''")
        for ordinal, (parameter, description) in enumerate(script.params, start=1):
            rows.append(
                f"  ('{script_name}', {len(parameters)}, {ordinal}, "
                f"'{parameter}', '{escaped_template}', "
                f"{sql_text_literal(description)}, {summary})"
            )
    # Enforce the "cannot drift" claim instead of intending it. A callable script
    # that the signature pattern fails to match is invisible to CALL_ADMIN_JSON
    # and to anyone reading the catalog, and the failure is a clean
    # SEMANTIC_ADMIN_100 that looks like the script does not exist.
    unpublished = sorted(declared - published - excluded)
    if unpublished:
        raise SystemExit(
            "package_lua_scripts: these SEMANTIC_ADMIN scripts are declared but "
            "publish no signature, so CALL_ADMIN_JSON cannot reach them: "
            + ", ".join(unpublished)
            + ". A script is published from its annotation block, so this one was "
            "declared some other way."
        )
    stale = sorted(excluded - declared)
    if stale:
        raise SystemExit(
            "package_lua_scripts: these runtime libraries or UDFs are not "
            "installed: " + ", ".join(stale)
        )

    body = ",\n".join(rows)
    return f"""{SCRIPT_PARAMETERS_BEGIN}
CREATE OR REPLACE VIEW SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS AS
SELECT
  CAST(SCRIPT_NAME AS VARCHAR(128)) AS SCRIPT_NAME,
  CAST(PARAMETER_COUNT AS DECIMAL(18,0)) AS PARAMETER_COUNT,
  CAST(ORDINAL_POSITION AS DECIMAL(18,0)) AS ORDINAL_POSITION,
  CAST(PARAMETER_NAME AS VARCHAR(128)) AS PARAMETER_NAME,
  CAST(CALL_TEMPLATE AS VARCHAR(2000000)) AS CALL_TEMPLATE,
  CAST(PARAMETER_DESCRIPTION AS VARCHAR(2000)) AS PARAMETER_DESCRIPTION,
  CAST(SCRIPT_DESCRIPTION AS VARCHAR(2000)) AS SCRIPT_DESCRIPTION
FROM (VALUES
{body}
) AS signatures (SCRIPT_NAME, PARAMETER_COUNT, ORDINAL_POSITION, PARAMETER_NAME, CALL_TEMPLATE,
                 PARAMETER_DESCRIPTION, SCRIPT_DESCRIPTION);
{SCRIPT_PARAMETERS_END}"""


# Sources whose content can change what the compiler emits for a given request.
# The materialization runtime is included because the compiler imports it and its
# choices land in the generated SQL.
COMPILE_RELEVANT_SOURCES = (
    "JSON_SOURCE", "ROWS_SOURCE", "SQL_TEXT_SOURCE", "GRAIN_GRAPH_SOURCE",
    "SOURCE_COLUMNS_SOURCE", "IDENTITY_JOIN_SOURCE", "QUERY_SPEC_SOURCE",
    "CATALOG_SNAPSHOT_SOURCE", "METRIC_PLAN_SOURCE", "PHYSICAL_PLAN_SOURCE",
    "GRAIN_SQL_SOURCE", "COMPILE_RESULT_SOURCE", "SEMANTIC_SQL_SYNTAX_SOURCE",
    "COMPILER_SOURCE", "MATERIALIZATIONS_SOURCE",
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


# Every runtime library script and the lua/ sources it is concatenated from, in
# order. Shared modules come first because the module after them reads their
# globals; the chunks share none, so a runtime that uses a shared module must
# list it (tests/unit/test_conventions.py checks).
#
# The validator carries metric_plan so it classifies metrics with the planner's
# own code: a metric that cannot be planned is refused when it is defined, not
# when it is queried. FUSION_RUNTIME is its own script rather than more of
# SEMANTIC_DEFINITION_RUNTIME, which is near the 200-local ceiling, and it
# carries shared/json.lua instead of importing the definition runtime for a
# codec, so a null it decodes is its own module's null.
RUNTIMES: dict[str, tuple[str, ...]] = {
    "VALIDATOR_RUNTIME": (
        "JSON_SOURCE", "ROWS_SOURCE", "SQL_TEXT_SOURCE", "GRAIN_GRAPH_SOURCE",
        "SOURCE_COLUMNS_SOURCE", "IDENTITY_JOIN_SOURCE", "METRIC_PLAN_SOURCE",
        "VALIDATOR_SOURCE"),
    "MATERIALIZATION_RUNTIME": (
        "BUILD_STAMP", "JSON_SOURCE", "ROWS_SOURCE", "MATERIALIZATIONS_SOURCE"),
    "COMPILER_RUNTIME": (
        "BUILD_STAMP", "JSON_SOURCE", "ROWS_SOURCE", "SQL_TEXT_SOURCE",
        "GRAIN_GRAPH_SOURCE", "SOURCE_COLUMNS_SOURCE", "IDENTITY_JOIN_SOURCE",
        "QUERY_SPEC_SOURCE", "CATALOG_SNAPSHOT_SOURCE", "METRIC_PLAN_SOURCE",
        "PHYSICAL_PLAN_SOURCE", "GRAIN_SQL_SOURCE", "COMPILE_RESULT_SOURCE",
        "SEMANTIC_SQL_SYNTAX_SOURCE", "COMPILER_SOURCE"),
    "SEMANTIC_DEFINITION_RUNTIME": (
        "JSON_SOURCE", "ROWS_SOURCE", "SQL_TEXT_SOURCE", "CATALOG_ROLLBACK_SOURCE",
        "DATABRICKS_IMPORT_SOURCE", "SEMANTIC_DEFINITION_SOURCE"),
    "FUSION_RUNTIME": (
        "JSON_SOURCE", "ROWS_SOURCE", "CATALOG_ROLLBACK_SOURCE",
        "FUSION_DECLARATION_SOURCE"),
    "AGENT_RUNTIME": ("JSON_SOURCE", "ROWS_SOURCE", "AGENT_SOURCE"),
    # What a script body shares instead of copying: each one that reads a single
    # value imports this and binds ESV_ROWS.scalar. An import, not text spliced
    # into the body, so a line number Exasol reports stays the file's own.
    "SCRIPT_SUPPORT_RUNTIME": ("JSON_SOURCE", "ROWS_SOURCE"),
}

PLACEHOLDER = re.compile(r"^-- @generated (\S+)$", re.M)
LUA_BODY = re.compile(r"^-- @lua (\S+)$", re.M)
SCRIPTS_DIR = ROOT / "lua/semantic_layer/scripts"


PARAMETERS_DOC = SCRIPTS_DIR / "PARAMETERS.md"

# The annotation block at the top of a script file: a `--- summary` line, then
# tags. It stays in the installed body, so a line number Exasol reports is the
# line number in the file.
ANNOTATION_TAG = re.compile(r"^-- @(\w+)(?:\s+(.*?))?\s*$")
SCRIPT_KINDS = {
    "scripting": "CREATE OR REPLACE SCRIPT",
    "scalar": "CREATE OR REPLACE LUA SCALAR SCRIPT",
    "preprocessor": "CREATE OR REPLACE LUA PREPROCESSOR SCRIPT",
}
PARAMETER_NAME = re.compile(r"^[A-Z][A-Z0-9_]*$")


class Script(typing.NamedTuple):
    """One script, as its file's annotations declare it.

    A NamedTuple rather than a dataclass: this module is loaded by path from the
    installer, the tests and the linter, and a dataclass needs its module
    registered in sys.modules.
    """

    path: Path
    name: str                         # e.g. CREATE_MODEL, in schema SEMANTIC_ADMIN
    kind: str                         # a key of SCRIPT_KINDS
    summary: str
    params: tuple[tuple[str, str], ...]   # (name, description), in call order
    returns: str                      # TABLE, ROWCOUNT, nothing, or a scalar type

    def statement(self) -> str:
        """The CREATE SCRIPT statement: generated header, the file as the body."""
        head = f"{SCRIPT_KINDS[self.kind]} SEMANTIC_ADMIN.{self.name}"
        if self.kind != "preprocessor":
            names = [name for name, _ in self.params]
            head += ("(\n" + ",\n".join(f"  {name}" for name in names) + "\n)") if names else "()"
        head += " AS" if self.returns == "nothing" else f"\nRETURNS {self.returns} AS"
        body = self.path.read_text(encoding="utf-8").removesuffix("\n")
        return f"{head}\n{body}\n/"


def shared_parameter_descriptions() -> dict[str, str]:
    """`| `NAME` | description |` rows of lua/semantic_layer/scripts/PARAMETERS.md."""
    rows = re.findall(r"^\| `([A-Z][A-Z0-9_]*)` \| (.+?) \|$",
                      PARAMETERS_DOC.read_text(encoding="utf-8"), re.M)
    shared: dict[str, str] = {}
    for name, description in rows:
        if name in shared:
            raise SystemExit(f"package_lua_scripts: {PARAMETERS_DOC.name} describes {name} twice")
        shared[name] = description.strip()
    return shared


def parse_script(path: Path, shared: dict[str, str]) -> Script:
    """Read a script file's annotation block; refuse anything incomplete."""
    where = path.relative_to(ROOT) if path.is_relative_to(ROOT) else path
    lines = path.read_text(encoding="utf-8").split("\n")
    block = []
    for line in lines:
        if not line.startswith("--"):
            break
        block.append(line)
    if not block or not block[0].startswith("--- ") or not block[0][4:].strip():
        raise SystemExit(f"{where}: must open with a `--- <summary>` line")
    summary = block[0][4:].strip()
    tags: dict[str, list[str]] = {}
    for line in block[1:]:
        match = ANNOTATION_TAG.match(line)
        if match:
            tags.setdefault(match.group(1), []).append(match.group(2) or "")
    unknown = sorted(set(tags) - {"script", "kind", "param", "returns"})
    if unknown:
        raise SystemExit(f"{where}: unknown annotation(s) " + ", ".join("@" + t for t in unknown))
    for single in ("script", "returns"):
        if len(tags.get(single, [])) != 1:
            raise SystemExit(f"{where}: needs exactly one @{single}")
    qualified = tags["script"][0]
    expected = f"SEMANTIC_ADMIN.{path.stem.upper()}"
    if qualified != expected:
        raise SystemExit(f"{where}: @script {qualified}; the file name says {expected}")
    kind = (tags.get("kind") or ["scripting"])[0]
    if kind not in SCRIPT_KINDS:
        raise SystemExit(f"{where}: @kind {kind}; expected one of {', '.join(SCRIPT_KINDS)}")
    params: list[tuple[str, str]] = []
    for text in tags.get("param", []):
        name, _, description = text.partition(" ")
        description = description.strip() or shared.get(name, "")
        if not PARAMETER_NAME.match(name):
            raise SystemExit(f"{where}: @param '{name}' is not an upper-case parameter name")
        if any(name == seen for seen, _ in params):
            raise SystemExit(f"{where}: @param {name} declared twice")
        if not description:
            raise SystemExit(f"{where}: @param {name} has no description here or in "
                             f"{PARAMETERS_DOC.relative_to(ROOT)}")
        params.append((name, description))
    if kind != "scripting" and params:
        raise SystemExit(f"{where}: only a scripting script takes @param")
    returns = tags["returns"][0]
    if kind == "scripting" and returns not in ("TABLE", "ROWCOUNT", "nothing"):
        raise SystemExit(f"{where}: @returns {returns}; a scripting script returns TABLE, ROWCOUNT or nothing")
    if kind == "preprocessor" and returns != "nothing":
        raise SystemExit(f"{where}: a preprocessor returns nothing")
    body = "\n".join(lines[len(block):])
    unused = [name for name, _ in params if not re.search(rf"\b{name}\b", body)]
    if unused:
        raise SystemExit(f"{where}: declares @param {', '.join(unused)} but never reads it")
    return Script(path, path.stem.upper(), kind, summary, tuple(params), returns)


def script_registry() -> dict[str, Script]:
    """Every script file, parsed, by script name."""
    shared = shared_parameter_descriptions()
    scripts = {path.stem.upper(): parse_script(path, shared)
               for path in sorted(SCRIPTS_DIR.glob("*.lua"))}
    used = {name for script in scripts.values() for name, _ in script.params}
    stale = sorted(set(shared) - used)
    if stale:
        raise SystemExit(f"package_lua_scripts: {PARAMETERS_DOC.name} describes parameters "
                         "no script takes: " + ", ".join(stale))
    return scripts


def inline_scripts(texts: dict[str, str]) -> dict[str, str]:
    """Replace each `-- @lua <path>` line with that script's whole statement."""
    registry = script_registry()
    used: set[Path] = set()

    def statement(match: re.Match[str]) -> str:
        path = (ROOT / match.group(1)).resolve()
        if path.parent != SCRIPTS_DIR or not path.is_file():
            raise SystemExit(f"package_lua_scripts: '-- @lua {match.group(1)}' names no "
                             f"file in {SCRIPTS_DIR.relative_to(ROOT)}/")
        if path in used:
            raise SystemExit(f"package_lua_scripts: {match.group(1)} is installed twice")
        used.add(path)
        return registry[path.stem.upper()].statement()

    inlined = {name: LUA_BODY.sub(statement, text) for name, text in texts.items()}
    orphans = sorted(path.name for path in SCRIPTS_DIR.glob("*.lua") if path.resolve() not in used)
    if orphans:
        raise SystemExit("package_lua_scripts: no source installs " + ", ".join(orphans))
    return inlined


def runtime_script(name: str) -> str:
    """CREATE SCRIPT for one runtime library, between its generated markers."""
    parts = []
    for source in RUNTIMES[name]:
        if source == "BUILD_STAMP":
            # A global, not a local: the 200-local ceiling applies to the sum of
            # the concatenated sources in one chunk, and this must not spend one.
            parts.append(f'ESV_RUNTIME_BUILD = "{runtime_build_id()}"')
        else:
            parts.append(globals()[source].read_text(encoding="utf-8").rstrip())
    body = "\n\n".join(parts)
    return (f"-- BEGIN GENERATED SEMANTIC_ADMIN.{name}\n"
            f"CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.{name} AS\n{body}\n/\n"
            f"-- END GENERATED SEMANTIC_ADMIN.{name}")


def compiler_block() -> str:
    """The two compiler libraries, as the build places them."""
    return (runtime_script("MATERIALIZATION_RUNTIME") + "\n\n"
            + runtime_script("COMPILER_RUNTIME"))


def expand(name: str, text: str, parts: dict[str, str], used: set[str]) -> str:
    def replace(match: re.Match[str]) -> str:
        part = match.group(1)
        if part not in parts:
            raise SystemExit(
                f"package_lua_scripts: {name} asks for '@generated {part}', which "
                f"nothing generates. Known: {', '.join(sorted(parts))}.")
        if part in used:
            raise SystemExit(f"package_lua_scripts: '@generated {part}' appears twice.")
        used.add(part)
        return parts[part]
    return PLACEHOLDER.sub(replace, text)


def sources() -> dict[str, str]:
    texts = {path.name: path.read_text(encoding="utf-8")
             for path in sorted(SOURCE_DIR.glob("*.sql"))}
    for name, text in texts.items():
        if "-- BEGIN GENERATED" in text:
            raise SystemExit(
                f"package_lua_scripts: sql/install/{name} contains generated text. "
                "Sources hold a one-line '-- @generated <NAME>' placeholder instead.")
    return inline_scripts(texts)


def assemble_without_parameters() -> dict[str, str]:
    """Every install file built, except the signature view that reads them."""
    parts = {f"SEMANTIC_ADMIN.{name}": runtime_script(name) for name in RUNTIMES}
    parts["SEMANTIC_SOURCE_VIEWS"] = source_views_block()
    used: set[str] = set()
    built = {name: text if name.startswith("002_") else expand(name, text, parts, used)
             for name, text in sources().items()}
    missing = sorted(set(parts) - used)
    if missing:
        raise SystemExit("package_lua_scripts: no source places " + ", ".join(missing))
    return built


def assemble() -> dict[str, str]:
    """The complete install files, by name: what build/install/ holds."""
    built = assemble_without_parameters()
    for name, text in built.items():
        check_main_chunk_locals(Path(name), text)
    # A later CREATE OR REPLACE silently wins, so a second definition of a script
    # is dead code at best, and at worst the one someone edits.
    declared = collections.Counter(
        script for text in built.values() for script in ANY_SCRIPT_DECLARATION.findall(text))
    twice = sorted(script for script, count in declared.items() if count > 1)
    if twice:
        raise SystemExit("package_lua_scripts: defined more than once: " + ", ".join(twice))
    signatures = {"ADMIN_SCRIPT_PARAMETERS": admin_script_parameters_block(built)}
    used: set[str] = set()
    for name in [name for name in built if name.startswith("002_")]:
        built[name] = expand(name, built[name], signatures, used)
    if not used:
        raise SystemExit("package_lua_scripts: no source places ADMIN_SCRIPT_PARAMETERS")
    return built


def main() -> int:
    built = assemble()
    BUILD_DIR.mkdir(parents=True, exist_ok=True)
    for stale in sorted(set(path.name for path in BUILD_DIR.glob("*.sql")) - set(built)):
        (BUILD_DIR / stale).unlink()
    for name, text in built.items():
        target = BUILD_DIR / name
        if target.exists() and target.read_text(encoding="utf-8") == text:
            print(f"unchanged {target.relative_to(ROOT)}")
        else:
            target.write_text(text, encoding="utf-8")
            print(f"updated {target.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
