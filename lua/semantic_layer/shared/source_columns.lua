-- Physical column-name resolution shared by the validator and compiler
-- runtimes. The packaging step embeds this source into both Exasol scripts so
-- the installed runtime has no external dependency.
--
-- A declared unique-key column carries the name the modeler typed, in whatever
-- case they typed it. Exasol resolves an unquoted identifier case-insensitively
-- but a quoted one exactly, so rendering a declared `customer_id` as
-- `alias."customer_id"` against a physical `CUSTOMER_ID` produces SQL that
-- parses, plans, and then fails at execution.
--
-- The validator resolved declared names against EXA_ALL_COLUMNS before probing;
-- the compiler quoted them verbatim. That asymmetry is exactly what let a model
-- validate clean, compile to `STATUS = OK`, and then fail to execute. Both
-- runtimes now resolve through this module, so what the validator probes and
-- what the compiler renders cannot drift apart.

local M = {}

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function cache_key(source_schema, source_object, column_name)
    return string.upper(tostring(source_schema)) .. "."
        .. string.upper(tostring(source_object)) .. "."
        .. string.upper(tostring(column_name))
end

-- Return the physical column name as the database spells it, or nil plus a
-- reason. An exact match wins over a case-insensitive one, so a source that
-- genuinely carries two columns differing only in case still resolves to the
-- declared spelling. `cache` is an optional caller-owned table; the module
-- keeps no state of its own so a long-running session cannot serve a stale
-- name after a source is redefined.
-- Resolve two declared column names against one source in a single call.
--
-- The F5 identity mapping relation is always addressed as a pair -- the
-- source-local key and the semantic key of the same cross-reference table -- and
-- both used to be quoted verbatim, so a lower-case declaration probed as
-- `"account_id"` against a physical ACCOUNT_ID and failed (BUG-G03). Living here
-- rather than in each runtime keeps the validator's probes and the compiler's
-- rendering on one implementation, and costs neither runtime a file-scope local:
-- Exasol caps a Lua function at 200 locals and the compiler runtime's main chunk
-- is already at that ceiling.
--
-- Each name falls back to its declared spelling when the metadata cannot answer,
-- so a source outside EXA_ALL_COLUMNS probes exactly as it did before and
-- reports its own error rather than one invented here.
function M.resolve_pair(query_fn, source_schema, source_object, first, second, cache)
    local first_name = M.resolve(query_fn, source_schema, source_object,
        first, cache) or first
    local second_name = M.resolve(query_fn, source_schema, source_object,
        second, cache) or second
    return first_name, second_name
end

function M.resolve(query_fn, source_schema, source_object, column_name, cache)
    if missing(source_schema) or missing(source_object) or missing(column_name) then
        return nil, "source column is not visible: " .. tostring(column_name)
    end
    local key = cache_key(source_schema, source_object, column_name)
    if cache ~= nil and cache[key] ~= nil then
        local cached = cache[key]
        if cached.name ~= nil then return cached.name, nil end
        return nil, cached.error
    end

    local ok, rows = pcall(query_fn, [[
        SELECT COLUMN_NAME
        FROM SYS.EXA_ALL_COLUMNS
        WHERE (COLUMN_SCHEMA = :schema_name OR COLUMN_SCHEMA = UPPER(:schema_name))
          AND (COLUMN_TABLE = :object_name OR COLUMN_TABLE = UPPER(:object_name))
          AND (COLUMN_NAME = :column_name OR COLUMN_NAME = UPPER(:column_name))
        ORDER BY CASE WHEN COLUMN_NAME = :column_name THEN 0 ELSE 1 END
        LIMIT 1
    ]], {
        schema_name = source_schema,
        object_name = source_object,
        column_name = column_name,
    })
    if not ok then
        return nil, tostring(rows)
    end
    if rows == nil or #rows == 0 then
        local reason = "source column is not visible: " .. tostring(column_name)
        if cache ~= nil then cache[key] = {error = reason} end
        return nil, reason
    end
    local row = rows[1]
    local name = row["COLUMN_NAME"] or row["column_name"] or row[1]
    if missing(name) then
        local reason = "source column is not visible: " .. tostring(column_name)
        if cache ~= nil then cache[key] = {error = reason} end
        return nil, reason
    end
    name = tostring(name)
    if cache ~= nil then cache[key] = {name = name} end
    return name, nil
end

-- Return a source relation's schema and name as the database spells them, or
-- nil plus a reason. The same rule as a column: an exact match wins, then the
-- upper-case spelling an unquoted identifier folds to.
--
-- The compiler quotes an entity's source exactly as stored, so a name stored
-- as typed -- dbt's ref() renders `slv_customer` for a table Exasol created as
-- SLV_CUSTOMER -- named a relation that does not exist. ADD_ENTITY accepted it,
-- and the mistake surfaced steps later as expression errors on every field
-- read from it. Declaring a source resolves it here instead, and the validator
-- asks the same question of what is stored.
function M.resolve_relation(query_fn, source_schema, source_object)
    if missing(source_schema) or missing(source_object) then
        return nil, nil, "source relation is required"
    end
    local ok, rows = pcall(query_fn, [[
        SELECT SCHEMA_NAME, OBJECT_NAME FROM (
          SELECT TABLE_SCHEMA AS SCHEMA_NAME, TABLE_NAME AS OBJECT_NAME
            FROM SYS.EXA_ALL_TABLES
           WHERE (TABLE_SCHEMA = :schema_name OR TABLE_SCHEMA = UPPER(:schema_name))
             AND (TABLE_NAME = :object_name OR TABLE_NAME = UPPER(:object_name))
          UNION ALL
          SELECT VIEW_SCHEMA, VIEW_NAME
            FROM SYS.EXA_ALL_VIEWS
           WHERE (VIEW_SCHEMA = :schema_name OR VIEW_SCHEMA = UPPER(:schema_name))
             AND (VIEW_NAME = :object_name OR VIEW_NAME = UPPER(:object_name))
          UNION ALL
          -- SYS.DUAL and the system views are in neither list above.
          SELECT SCHEMA_NAME, OBJECT_NAME
            FROM SYS.EXA_SYSCAT
           WHERE (SCHEMA_NAME = :schema_name OR SCHEMA_NAME = UPPER(:schema_name))
             AND (OBJECT_NAME = :object_name OR OBJECT_NAME = UPPER(:object_name))
        ) visible
        ORDER BY CASE WHEN SCHEMA_NAME = :schema_name THEN 0 ELSE 1 END,
                 CASE WHEN OBJECT_NAME = :object_name THEN 0 ELSE 1 END
        LIMIT 1
    ]], {schema_name = source_schema, object_name = source_object})
    local reason = "source relation is not visible: " .. tostring(source_schema)
        .. "." .. tostring(source_object)
    if not ok then
        return nil, nil, tostring(rows)
    end
    if rows == nil or #rows == 0 then
        return nil, nil, reason
    end
    local row = rows[1]
    local schema_name = row["SCHEMA_NAME"] or row["schema_name"] or row[1]
    local object_name = row["OBJECT_NAME"] or row["object_name"] or row[2]
    if missing(schema_name) or missing(object_name) then
        return nil, nil, reason
    end
    return tostring(schema_name), tostring(object_name), nil
end

-- The declaring scripts' form: the resolved spelling, which is what they
-- store, or SEMANTIC_ADMIN_227 naming the relation as it was given.
function M.require_relation(query_fn, source_schema, source_object)
    local schema_name, object_name = M.resolve_relation(query_fn, source_schema, source_object)
    if schema_name == nil then
        error("SEMANTIC_ADMIN_227: source relation " .. tostring(source_schema) .. "."
            .. tostring(source_object) .. " does not exist or is not visible to "
            .. "this user. A name is matched as written, then in upper case, the"
            .. " way Exasol folds an unquoted identifier.", 0)
    end
    return schema_name, object_name
end

ESV_SOURCE_COLUMNS = M
