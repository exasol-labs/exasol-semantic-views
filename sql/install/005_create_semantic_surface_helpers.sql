ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;

CREATE OR REPLACE LUA SCALAR SCRIPT SEMANTIC_ADMIN.SEMANTIC_GUARD()
RETURNS VARCHAR(2000000) AS
function run(ctx)
    error("SEMANTIC_SURFACE_001: semantic query requires the Lua SQL preprocessor. Run EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL() for this session, or ask an administrator to set it database-wide. If it is already active, this session lacks the privileges to run it: SEMANTIC_USER carries them, and GRANT_MODEL_ROLE grants it.", 0)
end
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(
  MODEL_NAME
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

-- NULL arrives as userdata, and userdata is truthy, so `value or ""` would
-- render it as an address. Every caller here wants an absent value to read as
-- the empty string -- `missing("")` is true, and a comment built from it is
-- simply omitted.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
end

local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_SURFACE_002: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_SURFACE_003: invalid " .. label .. ": " .. name)
    end
    return name
end

local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local function quote_ident(name)
    local text = tostring(name)
    text = string.gsub(text, '"', '""')
    return '"' .. text .. '"'
end

local function quote_qualified(schema_name, object_name)
    return quote_ident(schema_name) .. "." .. quote_ident(object_name)
end

local function sql_string(value)
    if missing(value) then
        return "NULL"
    end
    local text = tostring(value)
    text = string.gsub(text, "'", "''")
    return "'" .. text .. "'"
end

local function utf8_prefix(value, max_bytes)
    local text = trim(value)
    if #text <= max_bytes then
        return text
    end
    local content_limit = max_bytes - 3
    local index = 1
    local last = 0
    while index <= #text do
        local byte = string.byte(text, index)
        local width = 1
        if byte >= 240 then
            width = 4
        elseif byte >= 224 then
            width = 3
        elseif byte >= 192 then
            width = 2
        end
        if index + width - 1 > content_limit then
            break
        end
        last = index + width - 1
        index = index + width
    end
    return string.sub(text, 1, last) .. "..."
end

local function semantic_comment(summary, guidance)
    local text = trim(summary)
    if not missing(guidance) then
        text = text .. " " .. trim(guidance)
    end
    return utf8_prefix(text, 2000)
end

local function safe_data_type(data_type)
    local text = trim(data_type)
    if text == "" then
        error("SEMANTIC_SURFACE_004: missing data type")
    end
    if string.find(text, ";", 1, true)
        or string.find(text, "--", 1, true)
        or string.find(text, "/*", 1, true)
        or string.find(text, "*/", 1, true)
        or string.find(text, "'", 1, true)
        or string.find(text, '"', 1, true) then
        error("SEMANTIC_SURFACE_005: unsafe data type: " .. text)
    end
    if not string.match(text, "^[A-Za-z][A-Za-z0-9_ ,%(%)]+$") then
        error("SEMANTIC_SURFACE_005: unsafe data type: " .. text)
    end
    return text
end

local requested_model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local model_rows = query([[
    SELECT MODEL_ID, MODEL_NAME, ACTIVE_VERSION_ID AS VERSION_ID, PUBLISHED_SCHEMA, DESCRIPTION
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = requested_model_name})
if model_rows == nil or #model_rows == 0 then
    error("SEMANTIC_SURFACE_010: model not found: " .. requested_model_name)
end

local model = {
    id = row_value(model_rows[1], "MODEL_ID", 1),
    name = row_value(model_rows[1], "MODEL_NAME", 2),
    version_id = row_value(model_rows[1], "VERSION_ID", 3),
    published_schema = row_value(model_rows[1], "PUBLISHED_SCHEMA", 4),
    description = row_value(model_rows[1], "DESCRIPTION", 5),
}
if missing(model.version_id) then
    error("SEMANTIC_SURFACE_011: model has no active version: " .. tostring(model.name))
end
if missing(model.published_schema) then
    error("SEMANTIC_SURFACE_012: model has no published schema: " .. tostring(model.name))
end

local validation_rows = query([[
    EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)
]], {model_name = model.name})
for _, issue in ipairs(validation_rows or {}) do
    local severity = row_value(issue, "SEVERITY", 1)
    if severity == "ERROR" or severity == "PRECONDITION" then
        error("SEMANTIC_SURFACE_013: model validation failed: "
            .. tostring(row_value(issue, "RULE_CODE", 4)) .. " "
            .. tostring(row_value(issue, "MESSAGE", 5)))
    end
end

-- Drop the compile cache for this model_version. PUBLISH_MODEL is the
-- canonical "model definition or materializations changed" point, so cached
-- compile results for the prior view of this version are no longer trusted.
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})

query("CREATE SCHEMA IF NOT EXISTS " .. quote_ident(model.published_schema))
query("COMMENT ON SCHEMA " .. quote_ident(model.published_schema) .. " IS "
    .. sql_string(semantic_comment(
        "Published semantic model " .. tostring(model.name)
            .. (missing(model.description) and "." or ": " .. tostring(model.description) .. "."),
        "Official Exasol MCP clients can set SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR; SQL sessions can call SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL; structured adapters can use COMPILE_REQUEST_JSON.")))
query("CREATE TABLE IF NOT EXISTS " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY") .. " (ENTRY_NAME VARCHAR(256), ENTRY_VALUE VARCHAR(2000000))")
query("COMMENT ON TABLE " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY") .. " IS "
    .. sql_string("MCP-visible discovery table for semantic model " .. tostring(model.name)
        .. ". Query this table for entrypoint, object, field, and example-query guidance."))
query("DELETE FROM " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY"))
query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
    .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('MODEL_NAME', " .. sql_string(model.name) .. ")")
query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
    .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('MODEL_DESCRIPTION', " .. sql_string(model.description) .. ")")
query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
    .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('QUERY_ENTRYPOINT', 'EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()')")
query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
    .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('MCP_GUIDANCE', "
    .. sql_string("With the official Exasol MCP Server, call set_exasol_preprocessor for SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR, verify it with list_exasol_preprocessors, then query published semantic views with execute_exasol_query. Put LIMIT in semantic SQL instead of using MCP row_limit. Query SEMANTIC_AGENT.FIELDS_FOR_AGENT for fields.") .. ")")
query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
    .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('FIELD_DISCOVERY_QUERY', "
    .. sql_string("SELECT FIELD_KIND, FIELD_NAME, DATA_TYPE, DESCRIPTION FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE MODEL_NAME = '" .. tostring(model.name) .. "' ORDER BY OBJECT_NAME, FIELD_KIND, FIELD_NAME") .. ")")
query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
    .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('COMPATIBILITY_QUERY', "
    .. sql_string("SELECT METRIC_NAME, DIMENSION_NAME, IS_VALID, REASON_CODE FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT WHERE MODEL_NAME = '" .. tostring(model.name) .. "' ORDER BY OBJECT_NAME, METRIC_NAME, DIMENSION_NAME") .. ")")

local object_rows = query([[
    SELECT OBJECT_ID, OBJECT_NAME, DESCRIPTION
    FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND STATUS = 'ACTIVE'
    ORDER BY OBJECT_NAME
]], {model_id = model.id, version_id = model.version_id})

local output_rows = {}
for _, object_row in ipairs(object_rows or {}) do
    local object_id = row_value(object_row, "OBJECT_ID", 1)
    local object_name = row_value(object_row, "OBJECT_NAME", 2)
    local object_description = row_value(object_row, "DESCRIPTION", 3)
    query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
        .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('SEMANTIC_OBJECT', "
        .. sql_string(model.published_schema .. "." .. tostring(object_name)) .. ")")
    query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
        .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('SEMANTIC_OBJECT_DESCRIPTION', "
        .. sql_string(model.published_schema .. "." .. tostring(object_name) .. ": "
            .. trim(object_description)) .. ")")
    query("INSERT INTO " .. quote_qualified(model.published_schema, "SEMANTIC_DISCOVERY")
        .. " (ENTRY_NAME, ENTRY_VALUE) VALUES ('SEMANTIC_SELECT_EXAMPLE', "
        .. sql_string("SELECT * FROM " .. model.published_schema .. "." .. tostring(object_name) .. " LIMIT 10") .. ")")
    local column_rows = query([[
        SELECT
          oc.COLUMN_NAME,
          oc.COLUMN_KIND,
          COALESCE(d.DATA_TYPE, f.DATA_TYPE, mt.DATA_TYPE) AS DATA_TYPE,
          oc.ORDINAL_POSITION,
          COALESCE(d.DESCRIPTION, f.DESCRIPTION, mt.DESCRIPTION) AS DESCRIPTION,
          -- Fusion changes the number a column reports, so a BI user reading
          -- only the column comment should be told which sources it came from
          -- and how they were combined.
          (
            SELECT COUNT(*)
            FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
            WHERE er.ENTITY_ID = COALESCE(d.ENTITY_ID, f.ENTITY_ID, mt.BASE_ENTITY_ID)
              AND er.VERSION_ID = :version_id
              AND er.STATUS = 'ACTIVE'
          ) AS SOURCE_COUNT,
          COALESCE(
            (
              SELECT afp.FUSION_STRATEGY
              FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES afp
              WHERE afp.ATTRIBUTE_TYPE = oc.COLUMN_KIND
                AND afp.ATTRIBUTE_ID = oc.OBJECT_REF_ID
                AND afp.VERSION_ID = :version_id
                AND afp.STATUS = 'ACTIVE'
              LIMIT 1
            ),
            (
              SELECT 'UNION'
              FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
              WHERE er.ENTITY_ID = COALESCE(d.ENTITY_ID, f.ENTITY_ID, mt.BASE_ENTITY_ID)
                AND er.VERSION_ID = :version_id
                AND er.STATUS = 'ACTIVE'
                AND er.COVERAGE_PREDICATE IS NOT NULL
              LIMIT 1
            ),
            'NONE'
          ) AS FUSION_STRATEGY
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON oc.COLUMN_KIND = 'DIMENSION'
         AND d.DIMENSION_ID = oc.OBJECT_REF_ID
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON oc.COLUMN_KIND = 'FACT'
         AND f.FACT_ID = oc.OBJECT_REF_ID
        LEFT JOIN SYS_SEMANTIC.METRICS mt
          ON oc.COLUMN_KIND = 'METRIC'
         AND mt.METRIC_ID = oc.OBJECT_REF_ID
        WHERE oc.OBJECT_ID = :object_id
          AND oc.IS_VISIBLE = TRUE
        ORDER BY oc.ORDINAL_POSITION
    ]], {object_id = object_id, version_id = model.version_id})

    if column_rows == nil or #column_rows == 0 then
        error("SEMANTIC_SURFACE_014: semantic object has no visible columns: " .. tostring(object_name))
    end

    local column_declarations = {}
    local select_parts = {}
    for _, column_row in ipairs(column_rows) do
        local column_name = row_value(column_row, "COLUMN_NAME", 1)
        local data_type = safe_data_type(row_value(column_row, "DATA_TYPE", 3))
        local description = row_value(column_row, "DESCRIPTION", 5)
        local source_count = tonumber(row_value(column_row, "SOURCE_COUNT", 6) or 1) or 1
        local fusion_strategy = upper(row_value(column_row, "FUSION_STRATEGY", 7) or "NONE")
        local provenance = nil
        if source_count > 1 and fusion_strategy == "UNION" then
            provenance = "Fused across " .. tostring(source_count)
                .. " temporal partitions (F3 UNION)."
        elseif source_count > 1 and fusion_strategy ~= "NONE" then
            provenance = "Fused across " .. tostring(source_count)
                .. " sources (" .. fusion_strategy .. ")."
        elseif source_count > 1 then
            provenance = "Read from one of " .. tostring(source_count)
                .. " representations of its entity."
        end
        local comment_text = trim(description)
        if provenance ~= nil then
            comment_text = missing(comment_text) and provenance
                or (comment_text .. " " .. provenance)
        end
        local declaration = quote_ident(upper(column_name))
        if not missing(comment_text) then
            declaration = declaration .. " COMMENT IS " .. sql_string(utf8_prefix(comment_text, 2000))
        end
        column_declarations[#column_declarations + 1] = declaration
        select_parts[#select_parts + 1] = "CAST(SEMANTIC_ADMIN.SEMANTIC_GUARD() AS "
            .. data_type .. ") AS " .. quote_ident(upper(column_name))
    end

    query("CREATE OR REPLACE VIEW " .. quote_qualified(model.published_schema, object_name)
        .. " (\n  " .. table.concat(column_declarations, ",\n  ") .. "\n) AS\nSELECT\n  "
        -- The guard is in the WHERE clause as well as in every column, because a
        -- statement that selects no column never evaluates one. `SELECT COUNT(*)
        -- FROM <object>` without the preprocessor counted the guard view's own
        -- single row and returned 1 -- a plausible number for a question this
        -- view exists to refuse, and the worst shape of wrong. A predicate has to
        -- be evaluated for the row to be counted at all.
        .. table.concat(select_parts, ",\n  ")
        .. "\nFROM DUAL\nWHERE SEMANTIC_ADMIN.SEMANTIC_GUARD() IS NOT NULL\nCOMMENT IS "
        .. sql_string(semantic_comment(
            "Semantic object " .. tostring(model.name) .. "." .. tostring(object_name)
                .. (missing(object_description) and "." or ": " .. tostring(object_description) .. "."),
            "Field descriptions are published as column comments and in SEMANTIC_AGENT.FIELDS_FOR_AGENT. Official Exasol MCP clients can set SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR; SQL sessions can call SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL; structured adapters can use COMPILE_REQUEST_JSON.")))

    output_rows[#output_rows + 1] = {
        model.name,
        model.published_schema,
        object_name,
        #column_rows,
        "PUBLISHED",
    }
end

query([[
    UPDATE SYS_SEMANTIC.MODELS
    SET STATUS = 'PUBLISHED',
        UPDATED_AT = CURRENT_TIMESTAMP
    WHERE MODEL_ID = :model_id
]], {model_id = model.id})

local version_rows = query([[
    SELECT VERSION_NUMBER FROM SYS_SEMANTIC.MODEL_VERSIONS
    WHERE VERSION_ID = :version_id
]], {version_id = model.version_id})
local version_number = 1
if version_rows ~= nil and #version_rows > 0 then
    version_number = row_value(version_rows[1], "VERSION_NUMBER", 1) or 1
end

local count_rows = query([[
    SELECT COALESCE(MAX(PUBLISH_NUMBER), 0) + 1 AS NEXT_PUBLISH_NUMBER
    FROM SYS_SEMANTIC.MODEL_PUBLISH_HISTORY
    WHERE MODEL_ID = :model_id
]], {model_id = model.id})
local publish_number = 1
if count_rows ~= nil and #count_rows > 0 then
    publish_number = row_value(count_rows[1], "NEXT_PUBLISH_NUMBER", 1) or 1
end

query([[
    INSERT INTO SYS_SEMANTIC.MODEL_PUBLISH_HISTORY
      (MODEL_ID, VERSION_ID, VERSION_NUMBER, PUBLISH_NUMBER)
    VALUES (:model_id, :version_id, :version_number, :publish_number)
]], {
    model_id = model.id,
    version_id = model.version_id,
    version_number = version_number,
    publish_number = publish_number,
})

-- Roles granted this model before it had a published schema still need SELECT on
-- it. GRANT_MODEL_ROLE cannot grant a schema that does not exist yet, so the
-- other half of that ordering lives here: publishing catches up every active
-- grant. Best effort per role -- one role dropped out from under the catalog
-- must not fail a publish that otherwise succeeded.
local granted_roles = query([[
    SELECT DISTINCT ROLE_NAME FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS
    WHERE MODEL_ID = :model_id AND STATUS = 'ACTIVE'
]], {model_id = model.id})
for _, grant_row in ipairs(granted_roles or {}) do
    local granted_role = grant_row[1] or grant_row.ROLE_NAME
    if granted_role ~= nil and tostring(granted_role) ~= "" then
        pcall(query, "GRANT SELECT ON SCHEMA " .. quote_ident(model.published_schema)
            .. " TO " .. quote_ident(granted_role))
    end
end

exit(output_rows, [[
  MODEL_NAME VARCHAR(256),
  PUBLISHED_SCHEMA VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  COLUMN_COUNT DECIMAL(18,0),
  STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REFRESH_SEMANTIC_SURFACE(
  MODEL_NAME
)
RETURNS TABLE AS
local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local rows = query([[
    EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(:model_name)
]], {model_name = MODEL_NAME})

local out = {}
for _, row in ipairs(rows or {}) do
    out[#out + 1] = {
        row_value(row, "MODEL_NAME", 1),
        row_value(row, "PUBLISHED_SCHEMA", 2),
        row_value(row, "OBJECT_NAME", 3),
        row_value(row, "COLUMN_COUNT", 4),
        row_value(row, "STATUS", 5),
    }
end

exit(out, [[
  MODEL_NAME VARCHAR(256),
  PUBLISHED_SCHEMA VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  COLUMN_COUNT DECIMAL(18,0),
  STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()
RETURNS TABLE AS
query([[ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR]])
exit({{"OK", "SESSION", "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR", "Semantic SQL enabled for this session."}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(256),
  MESSAGE VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()
RETURNS TABLE AS
query([[ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL]])
exit({{"OK", "SESSION", null, "Semantic SQL disabled for this session."}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(256),
  MESSAGE VARCHAR(2000000)
]])
/
