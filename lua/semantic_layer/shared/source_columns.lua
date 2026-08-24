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

ESV_SOURCE_COLUMNS = M
