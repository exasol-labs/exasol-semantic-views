ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;

CREATE OR REPLACE LUA PREPROCESSOR SCRIPT SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR AS
-- This script runs for EVERY statement in the session -- and every nested query
-- a Lua script issues is itself a statement, so this cost is multiplied by the
-- internal query count of every admin script that runs in the session.
-- Importing both runtimes unconditionally cost ~21 ms per statement and made
-- VALIDATE_MODEL 2.7x slower with semantic SQL enabled. So decide what the
-- statement could possibly be before importing anything, and never import a
-- runtime that cannot apply. See plans/preprocessor-latency.md.

local original_sql = sqlparsing.getsqltext()

-- SQL NULL reaches Lua as truthy userdata, so `tostring(X or "")` would render
-- an address rather than falling back. Guard explicitly, as every other script
-- here does.
local scan_text = ""
if original_sql ~= nil and original_sql ~= null then
    scan_text = tostring(original_sql)
end
local head = string.match(string.upper(scan_text), "^%s*(.-)%s*$")

-- Semantic DDL and introspection. Every form semantic_definition.preprocess_sql
-- dispatches on begins with one of these five words AND names SEMANTIC, so this
-- gate is strictly weaker than its own dispatch and cannot skip a form it would
-- have handled.
local COMMAND_WORDS = {ALTER = true, SHOW = true, DESCRIBE = true, EXPLAIN = true, EXPORT = true}
local needs_definition = COMMAND_WORDS[string.match(head, "^(%a+)") or ""] ~= nil
    and string.find(head, "SEMANTIC", 1, true) ~= nil

-- The same lexical early-out compile_sql_for_preprocessor already applies,
-- moved to before the import instead of after it.
local looks_like_query = string.find(head, "SELECT", 1, true) ~= nil
    and string.find(head, "FROM", 1, true) ~= nil

-- Does the statement name a schema this layer owns? Answering costs one small
-- catalog read; guessing wrong in the permissive direction only costs an import
-- the compiler would then decline, so every uncertain case answers "yes".
local function references_semantic_schema()
    -- parse_semantic_sql accepts only schema.object, so a statement naming no
    -- qualified relation can never be rewritten. Collect every qualifier rather
    -- than only the one after FROM: over-collecting costs at worst one import,
    -- while missing one would silently stop rewriting a valid semantic query.
    local candidates, seen = {}, {}
    for name in string.gmatch(head, '"?([%a_][%w_]*)"?%s*%.') do
        if not seen[name] then
            seen[name] = true
            candidates[#candidates + 1] = name
        end
    end
    if #candidates == 0 then return false end

    local ok, rows = pcall(function()
        return query([[SELECT UPPER(PUBLISHED_SCHEMA) AS PUBLISHED_SCHEMA
                       FROM SYS_SEMANTIC.MODELS WHERE PUBLISHED_SCHEMA IS NOT NULL]])
    end)
    if not ok or rows == nil then
        return true    -- catalog unreadable: fail open and let the compiler decide
    end
    for i = 1, #rows do
        if seen[tostring(rows[i][1])] then return true end
    end

    -- A published schema whose model row is gone is an orphaned publication,
    -- which compile_sql_for_preprocessor names as SEMANTIC_QUERY_005 rather
    -- than letting the view guard tell the user to enable the preprocessor they
    -- have already enabled. Keeping that case reachable costs a sub-millisecond
    -- read of the discovery table itself; finding it through EXA_ALL_TABLES
    -- costs 55 ms, which is why this probes the candidate directly. The name is
    -- matched as [%a_][%w_]* above, so it cannot carry a quote.
    --
    -- Skipping this probe for the layer's own schemas was tried and reverted:
    -- it saved nothing measurable (VALIDATE_MODEL 1.24x -> 1.22x, inside the
    -- noise) and rested on a premise that turns out to be false -- CREATE_MODEL
    -- accepts SEMANTIC_ADMIN as a published schema, so a managed schema can be
    -- orphaned like any other.
    for i = 1, math.min(#candidates, 4) do
        if pcall(function()
            query('SELECT 1 FROM "' .. candidates[i] .. '"."SEMANTIC_DISCOVERY" WHERE 1 = 0')
        end) then
            return true
        end
    end
    return false
end

local result = {status = "UNCHANGED"}

-- Importing a runtime needs EXECUTE on it, which a principal outside this layer
-- does not have. That must not turn their ordinary SQL into an error: the
-- preprocessor's job is to rewrite semantic statements, and one it cannot
-- rewrite goes to the database exactly as written. A genuinely semantic query
-- then meets the published view's own guard, which says what to do about it.
local function with_runtime(script_name, alias, apply)
    local imported = pcall(exa.import, script_name, alias)
    if not imported then
        return {status = "UNCHANGED"}
    end
    return apply()
end

if needs_definition then
    result = with_runtime("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition",
        function() return semantic_definition.preprocess_sql(original_sql) end)
end

if result.status == "UNCHANGED" and looks_like_query and references_semantic_schema() then
    result = with_runtime("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler",
        function() return compiler.compile_sql_for_preprocessor(original_sql) end)
end

if result.status == "UNCHANGED" then
    sqlparsing.setsqltext(original_sql)
elseif result.status == "OK" then
    sqlparsing.setsqltext(result.generated_sql)
else
    error((result.error_code or "SEMANTIC_QUERY_999") .. ": " .. (result.error_message or "Semantic SQL preprocessing failed."), 0)
end
/

-- Database-wide activation is the supported BI deployment mode
-- (docs/admin-db-wide-setup.md), and Exasol runs the preprocessor as the caller.
-- Without this grant, `ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT` denies *every*
-- statement to every principal that has not been granted SEMANTIC_USER --
-- including `SELECT 1` from a user with no relationship to this layer at all.
-- The supported deployment mode was a database-wide outage.
--
-- The grant is safe to make to PUBLIC because this script decides whether a
-- statement is semantic and does nothing else. It reads no model data of its
-- own: the catalog probe below is wrapped, and the runtimes that can read the
-- catalog are imported only when the statement could possibly need them and are
-- still subject to the caller's own privileges.
GRANT EXECUTE ON SCRIPT SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR TO PUBLIC;
