-- Luacheck configuration: lua/, tests/lua/, and the script bodies in
-- lua/semantic_layer/scripts/ (tools/dev/lint_script_bodies.py lints those, with
-- each script's parameters declared). Run through tools/run_static_checks.sh.

-- Exasol 7.1+ runs Lua 5.4.
std = "lua54"

-- The scripting API Exasol provides to every script.
-- https://docs.exasol.com/db/latest/database_concepts/scripting/general_script_language.htm
read_globals = {
    "query", "pquery", "exit", "import", "output", "null", "exa", "sqlparsing",
}

-- The shared modules' namespaces. A runtime script is one chunk of several
-- concatenated sources, and these are how the parts reach one another; see
-- "Every runtime that uses a shared module must embed it" in CLAUDE.md.
globals = {
    "ESV_JSON", "ESV_ROWS", "ESV_SQL_TEXT", "ESV_SOURCE_COLUMNS", "ESV_IDENTITY_JOIN",
    "ESV_GRAIN_GRAPH", "ESV_CATALOG_ROLLBACK", "ESV_METRIC_PLAN", "ESV_QUERY_SPEC",
    "ESV_CATALOG_SNAPSHOT", "ESV_PHYSICAL_PLAN", "ESV_GRAIN_SQL", "ESV_MATERIALIZATIONS",
    "ESV_FUSION_DECLARATION", "ESV_RUNTIME_BUILD", "ESV_TEST_MODE",
}

-- `import()` exposes a script's top-level globals as its namespace, so a
-- runtime defines its public functions as globals on purpose, and nothing in
-- the same file reads them (131: unused global).
allow_defined_top = true
ignore = { "131" }

-- Callbacks and query mocks keep the signature their caller passes.
unused_args = false

-- Long SQL literals are the norm here, and wrapping them changes the SQL.
max_line_length = false

-- The namespace import() gives the materialization runtime.
files["lua/semantic_layer/compiler/request_json.lua"] = { read_globals = { "materializations" } }

files["tests/lua"] = {
    -- The test harness stands in for Exasol and inspects runtime internals.
    allow_defined = true,
    globals = { "ESV_COMPILER_TEST_API" },
}
