--- Deletes a model and all its catalog rows, dropping its published schema if no other model uses it; returns one row.
-- @script SEMANTIC_ADMIN.DROP_MODEL
-- @param MODEL_NAME
-- @returns TABLE

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
end

local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. name)
    end
    return name
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local scalar = script_support.ESV_ROWS.scalar

local function quote_ident(name)
    return '"' .. string.gsub(tostring(name), '"', '""') .. '"'
end

local requested_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local model_rows = query([[
    SELECT MODEL_ID, MODEL_NAME, PUBLISHED_SCHEMA
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = requested_name})
if model_rows == nil or #model_rows == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. requested_name)
end

local model_id = row_value(model_rows[1], "MODEL_ID", 1)
local model_name = row_value(model_rows[1], "MODEL_NAME", 2)
local published_schema = row_value(model_rows[1], "PUBLISHED_SCHEMA", 3)
local schema_dropped = false

if not missing(published_schema) then
    local normalized_schema = upper(published_schema)
    local protected_schemas = {
        SYS = true,
        EXA_STATISTICS = true,
        SYS_SEMANTIC = true,
        SEMANTIC_ADMIN = true,
        SEMANTIC_CATALOG = true,
        SEMANTIC_AGENT = true,
        MART = true,
    }
    local other_models = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.MODELS
        WHERE MODEL_ID <> :model_id
          AND UPPER(PUBLISHED_SCHEMA) = UPPER(:published_schema)
    ]], {model_id = model_id, published_schema = published_schema})
    local schema_exists = scalar([[
        SELECT COUNT(*)
        FROM SYS.EXA_ALL_SCHEMAS
        WHERE UPPER(SCHEMA_NAME) = UPPER(:published_schema)
    ]], {published_schema = published_schema})
    if tonumber(other_models or 0) == 0
        and tonumber(schema_exists or 0) > 0
        and not protected_schemas[normalized_schema] then
        query("DROP SCHEMA " .. quote_ident(published_schema) .. " CASCADE")
        schema_dropped = true
    end
end

query([[
    DELETE FROM SYS_SEMANTIC.MODEL_EVOLUTION_SUGGESTIONS
    WHERE MODEL_ID = :model_id
       OR AGENT_REQUEST_ID IN (
            SELECT AGENT_REQUEST_ID FROM SYS_SEMANTIC.AGENT_REQUEST_LOG
            WHERE MODEL_ID = :model_id
       )
       OR QUERY_LOG_ID IN (
            SELECT QUERY_LOG_ID FROM SYS_SEMANTIC.QUERY_LOG
            WHERE MODEL_ID = :model_id
       )
       OR FEEDBACK_ID IN (
            SELECT FEEDBACK_ID FROM SYS_SEMANTIC.AGENT_FEEDBACK
            WHERE AGENT_REQUEST_ID IN (
                    SELECT AGENT_REQUEST_ID FROM SYS_SEMANTIC.AGENT_REQUEST_LOG
                    WHERE MODEL_ID = :model_id
                  )
               OR QUERY_LOG_ID IN (
                    SELECT QUERY_LOG_ID FROM SYS_SEMANTIC.QUERY_LOG
                    WHERE MODEL_ID = :model_id
                  )
       )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.AGENT_FEEDBACK
    WHERE AGENT_REQUEST_ID IN (
            SELECT AGENT_REQUEST_ID FROM SYS_SEMANTIC.AGENT_REQUEST_LOG
            WHERE MODEL_ID = :model_id
          )
       OR QUERY_LOG_ID IN (
            SELECT QUERY_LOG_ID FROM SYS_SEMANTIC.QUERY_LOG
            WHERE MODEL_ID = :model_id
          )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.VALIDATION_RESULTS
    WHERE MODEL_ID = :model_id
       OR VALIDATION_RUN_ID IN (
            SELECT VALIDATION_RUN_ID FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id
       )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
    WHERE UNIQUE_KEY_ID IN (
        SELECT UNIQUE_KEY_ID FROM SYS_SEMANTIC.UNIQUE_KEYS WHERE MODEL_ID = :model_id
    )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
    WHERE RELATIONSHIP_ID IN (
        SELECT RELATIONSHIP_ID FROM SYS_SEMANTIC.RELATIONSHIPS WHERE MODEL_ID = :model_id
    )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
    WHERE OBJECT_ID IN (
        SELECT OBJECT_ID FROM SYS_SEMANTIC.SEMANTIC_OBJECTS WHERE MODEL_ID = :model_id
    )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
    WHERE METRIC_ID IN (
        SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE MODEL_ID = :model_id
    )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.METRIC_INPUTS
    WHERE METRIC_ID IN (
        SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE MODEL_ID = :model_id
    )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.METRIC_FILTERS
    WHERE METRIC_ID IN (
        SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE MODEL_ID = :model_id
    )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.MATERIALIZATION_COLUMNS
    WHERE MATERIALIZATION_ID IN (
        SELECT MATERIALIZATION_ID FROM SYS_SEMANTIC.MATERIALIZATIONS
        WHERE MODEL_ID = :model_id
    )
]], {model_id = model_id})
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID IN (
        SELECT VERSION_ID FROM SYS_SEMANTIC.MODEL_VERSIONS WHERE MODEL_ID = :model_id
    )
]], {model_id = model_id})

local model_tables = {
    "METRIC_TYPE_OBSERVATIONS",
    "METRIC_DIMENSION_MATRIX",
    "MODEL_ROLE_GRANTS",
    "MODEL_PUBLISH_HISTORY",
    "MATERIALIZATIONS",
    "AGENT_INSTRUCTIONS",
    "VERIFIED_QUERIES",
    "CUSTOM_EXTENSIONS",
    "SYNONYMS",
    "SEMANTIC_DEFINITION_SOURCES",
    "IDENTITY_MAPPING_RELATIONS",
    "IDENTITY_BINDINGS",
    "SEMANTIC_IDENTITIES",
    "ATTRIBUTE_FUSION_POLICIES",
    "ATTRIBUTE_BINDINGS",
    "DIMENSIONS",
    "FACTS",
    "METRICS",
    "RELATIONSHIPS",
    "SEMANTIC_OBJECTS",
    "UNIQUE_KEYS",
    "REPRESENTATION_AUTHORITIES",
    "ENTITY_REPRESENTATIONS",
    "ENTITIES",
    "AGENT_REQUEST_LOG",
    "QUERY_LOG",
    "VALIDATION_RUNS",
    "MODEL_VERSIONS",
}
for _, table_name in ipairs(model_tables) do
    query("DELETE FROM SYS_SEMANTIC." .. table_name .. " WHERE MODEL_ID = :model_id",
        {model_id = model_id})
end
query("DELETE FROM SYS_SEMANTIC.MODELS WHERE MODEL_ID = :model_id", {model_id = model_id})

exit({{model_name, published_schema or null, schema_dropped, "DROPPED"}}, [[
  MODEL_NAME VARCHAR(256),
  PUBLISHED_SCHEMA VARCHAR(256),
  SCHEMA_DROPPED BOOLEAN,
  STATUS VARCHAR(32)
]])
