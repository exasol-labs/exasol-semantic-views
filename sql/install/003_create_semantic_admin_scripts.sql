CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(
  MODEL_NAME,
  PUBLISHED_SCHEMA,
  DESCRIPTION,
  OWNER_ROLE
) AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local published_schema = normalize_name(PUBLISHED_SCHEMA, "PUBLISHED_SCHEMA")

local existing = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if tonumber(existing or 0) > 0 then
    error("SEMANTIC_ADMIN_010: duplicate model name: " .. model_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.MODELS (
      MODEL_NAME, PUBLISHED_SCHEMA, DESCRIPTION, OWNER_ROLE, STATUS,
      PREPROCESSOR_SCHEMA, PREPROCESSOR_SCRIPT, SURFACE_TYPE
    ) VALUES (
      :model_name, :published_schema, :description, :owner_role, 'DRAFT',
      'SEMANTIC_ADMIN', 'SEMANTIC_PREPROCESSOR', 'VIEW_PREPROCESSOR'
    )
]], {
    model_name = model_name,
    published_schema = published_schema,
    description = optional_text(DESCRIPTION),
    owner_role = optional_text(OWNER_ROLE)
})

local model_id = scalar([[
    SELECT MODEL_ID
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})

query([[
    INSERT INTO SYS_SEMANTIC.MODEL_VERSIONS (
      MODEL_ID, VERSION_NUMBER, VERSION_LABEL, STATUS, CHANGE_SUMMARY
    ) VALUES (
      :model_id, 1, 'initial', 'DRAFT', 'Initial model version'
    )
]], {model_id = model_id})

local version_id = scalar([[
    SELECT VERSION_ID
    FROM SYS_SEMANTIC.MODEL_VERSIONS
    WHERE MODEL_ID = :model_id AND VERSION_NUMBER = 1
]], {model_id = model_id})

query([[
    UPDATE SYS_SEMANTIC.MODELS
    SET ACTIVE_VERSION_ID = :version_id,
        UPDATED_AT = CURRENT_TIMESTAMP,
        UPDATED_BY = CURRENT_USER
    WHERE MODEL_ID = :model_id
]], {version_id = version_id, model_id = model_id})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DROP_MODEL(
  MODEL_NAME
)
RETURNS TABLE AS
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

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return row_value(rows[1], "VALUE", 1) or rows[1][1]
end

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
    DELETE FROM SYS_SEMANTIC.AGENT_SUGGESTIONS
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
    DELETE FROM SYS_SEMANTIC.CALCULATION_ITEMS
    WHERE CALCULATION_GROUP_ID IN (
        SELECT CALCULATION_GROUP_ID FROM SYS_SEMANTIC.CALCULATION_GROUPS
        WHERE MODEL_ID = :model_id
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
    "METRIC_DIMENSION_MATRIX",
    "MODEL_ROLE_GRANTS",
    "MODEL_PUBLISH_HISTORY",
    "OBJECT_PRIVILEGES",
    "MATERIALIZATIONS",
    "AGENT_INSTRUCTIONS",
    "VERIFIED_QUERIES",
    "CUSTOM_EXTENSIONS",
    "SYNONYMS",
    "CALCULATION_GROUPS",
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
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  MODEL_NAME,
  ENTITY_NAME,
  SOURCE_SCHEMA,
  SOURCE_OBJECT,
  SOURCE_ALIAS,
  PRIMARY_KEY_EXPR,
  GRAIN_DESCRIPTION,
  DESCRIPTION
) AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local source_schema = normalize_name(SOURCE_SCHEMA, "SOURCE_SCHEMA")
local source_object = normalize_name(SOURCE_OBJECT, "SOURCE_OBJECT")
local source_alias = normalize_name(SOURCE_ALIAS, "SOURCE_ALIAS")
local reserved_alias = scalar([[
    SELECT COUNT(*)
    FROM SYS.EXA_SQL_KEYWORDS
    WHERE UPPER(KEYWORD) = UPPER(:source_alias)
      AND RESERVED = TRUE
]], {source_alias = source_alias})
if tonumber(reserved_alias or 0) > 0 then
    error("SEMANTIC_ADMIN_044: entity alias '" .. source_alias
        .. "' is an Exasol reserved word; choose another alias")
end
local model = model_row(model_name)

local duplicate_name = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.ENTITIES
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
if tonumber(duplicate_name or 0) > 0 then
    error("SEMANTIC_ADMIN_012: duplicate entity name: " .. entity_name)
end

local duplicate_alias = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.ENTITIES
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(SOURCE_ALIAS) = UPPER(:source_alias)
]], {model_id = model.model_id, version_id = model.version_id, source_alias = source_alias})
if tonumber(duplicate_alias or 0) > 0 then
    error("SEMANTIC_ADMIN_013: duplicate entity alias: " .. source_alias)
end

query([[
    INSERT INTO SYS_SEMANTIC.ENTITIES (
      MODEL_ID, VERSION_ID, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT,
      SOURCE_ALIAS, PRIMARY_KEY_EXPR, GRAIN_DESCRIPTION, DESCRIPTION, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_name, :source_schema, :source_object,
      :source_alias, :primary_key_expr, :grain_description, :description, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_name = entity_name,
    source_schema = source_schema,
    source_object = source_object,
    source_alias = source_alias,
    primary_key_expr = optional_text(PRIMARY_KEY_EXPR),
    grain_description = optional_text(GRAIN_DESCRIPTION),
    description = optional_text(DESCRIPTION)
})

local entity_id = scalar([[
    SELECT ENTITY_ID
    FROM SYS_SEMANTIC.ENTITIES
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
query([[
    INSERT INTO SYS_SEMANTIC.ENTITY_REPRESENTATIONS (
      MODEL_ID, VERSION_ID, ENTITY_ID, REPRESENTATION_NAME, SOURCE_KIND,
      SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS, REPRESENTATION_ROLE,
      PRIORITY, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, 'primary', 'RELATION',
      :source_schema, :source_object, :source_alias, 'PRIMARY', 1, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id,
    source_schema = source_schema,
    source_object = source_object,
    source_alias = source_alias,
})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION(
  MODEL_NAME,
  ENTITY_NAME,
  REPRESENTATION_NAME,
  SOURCE_KIND,
  SOURCE_SCHEMA,
  SOURCE_OBJECT,
  PRIORITY,
  FRESHNESS_POLICY
)
RETURNS TABLE AS
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

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return row_value(rows[1], "VALUE", 1) or rows[1][1]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local source_schema = normalize_name(SOURCE_SCHEMA, "SOURCE_SCHEMA")
local source_object = normalize_name(SOURCE_OBJECT, "SOURCE_OBJECT")
local source_kind = missing(SOURCE_KIND) and "RELATION" or upper(trim(SOURCE_KIND))
if source_kind ~= "RELATION" and source_kind ~= "VIRTUAL_SCHEMA" then
    error("SEMANTIC_ADMIN_003: invalid SOURCE_KIND: " .. tostring(SOURCE_KIND))
end
local priority = missing(PRIORITY) and 100 or tonumber(PRIORITY)
if priority == nil or priority < 1 or priority % 1 ~= 0 then
    error("SEMANTIC_ADMIN_003: PRIORITY must be a positive integer")
end

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID, p.SOURCE_ALIAS
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
     AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS p
      ON p.ENTITY_ID = e.ENTITY_ID
     AND p.MODEL_ID = e.MODEL_ID
     AND p.VERSION_ID = e.VERSION_ID
     AND p.REPRESENTATION_ROLE = 'PRIMARY'
     AND p.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_014: entity or active primary representation not found: " .. entity_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local source_alias = row_value(rows[1], "SOURCE_ALIAS", 4)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
]], {entity_id = entity_id, representation_name = representation_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_046: duplicate representation name: " .. representation_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.ENTITY_REPRESENTATIONS (
      MODEL_ID, VERSION_ID, ENTITY_ID, REPRESENTATION_NAME, SOURCE_KIND,
      SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS, REPRESENTATION_ROLE,
      PRIORITY, FRESHNESS_POLICY, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :representation_name, :source_kind,
      :source_schema, :source_object, :source_alias, 'ALTERNATE',
      :priority, :freshness_policy, 'ACTIVE'
    )
]], {
    model_id = model_id,
    version_id = version_id,
    entity_id = entity_id,
    representation_name = representation_name,
    source_kind = source_kind,
    source_schema = source_schema,
    source_object = source_object,
    source_alias = source_alias,
    priority = priority,
    freshness_policy = missing(FRESHNESS_POLICY) and null or tostring(FRESHNESS_POLICY),
})
local representation_id = scalar([[
    SELECT REPRESENTATION_ID
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
]], {entity_id = entity_id, representation_name = representation_name})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})

exit({{representation_id, model_name, entity_name, representation_name,
    source_kind, source_schema, source_object, source_alias, "ALTERNATE", priority}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  SOURCE_KIND VARCHAR(64),
  SOURCE_SCHEMA VARCHAR(256),
  SOURCE_OBJECT VARCHAR(256),
  SOURCE_ALIAS VARCHAR(128),
  REPRESENTATION_ROLE VARCHAR(64),
  PRIORITY DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY(
  MODEL_NAME, ENTITY_NAME, IDENTITY_NAME, IDENTITY_KIND, DATA_TYPE, DESCRIPTION
)
RETURNS TABLE AS
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function upper(value) return string.upper(trim(value)) end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local model_name = trim(MODEL_NAME)
local entity_name = trim(ENTITY_NAME)
local identity_name = trim(IDENTITY_NAME)
local identity_kind = upper(IDENTITY_KIND)
local data_type = trim(DATA_TYPE)
if model_name == "" or entity_name == "" or identity_name == "" or data_type == "" then
    error("SEMANTIC_ADMIN_001: model, entity, identity, and data type are required")
end
if identity_kind ~= "BUSINESS" and identity_kind ~= "GLOBAL" then
    error("SEMANTIC_ADMIN_003: IDENTITY_KIND must be BUSINESS or GLOBAL")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID
    FROM SYS_SEMANTIC.MODELS m JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local existing = query([[
    SELECT IDENTITY_ID FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND UPPER(IDENTITY_NAME) = UPPER(:identity_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      identity_name = identity_name})
local conflicting = query([[
    SELECT IDENTITY_ID FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND UPPER(IDENTITY_NAME) = UPPER(:identity_name)
      AND ENTITY_ID <> :entity_id AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      identity_name = identity_name})
if conflicting ~= nil and #conflicting > 0 then
    error("SEMANTIC_ADMIN_011: duplicate semantic identity name: " .. identity_name)
end
local entity_identity = query([[
    SELECT IDENTITY_NAME FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND UPPER(IDENTITY_NAME) <> UPPER(:identity_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      identity_name = identity_name})
if entity_identity ~= nil and #entity_identity > 0 then
    error("SEMANTIC_ADMIN_051: entity already has an active semantic identity: "
        .. tostring(row_value(entity_identity[1], "IDENTITY_NAME", 1)))
end
local identity_id
if existing ~= nil and #existing > 0 then
    identity_id = row_value(existing[1], "IDENTITY_ID", 1)
    query([[
        UPDATE SYS_SEMANTIC.SEMANTIC_IDENTITIES
        SET IDENTITY_KIND = :identity_kind, DATA_TYPE = :data_type,
            DESCRIPTION = :description, UPDATED_AT = CURRENT_TIMESTAMP,
            UPDATED_BY = CURRENT_USER
        WHERE IDENTITY_ID = :identity_id
    ]], {identity_id = identity_id, identity_kind = identity_kind,
          data_type = data_type, description = DESCRIPTION})
else
    query([[
        INSERT INTO SYS_SEMANTIC.SEMANTIC_IDENTITIES (
          MODEL_ID, VERSION_ID, ENTITY_ID, IDENTITY_NAME, IDENTITY_KIND,
          DATA_TYPE, DESCRIPTION, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :identity_name, :identity_kind,
          :data_type, :description, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          identity_name = identity_name, identity_kind = identity_kind,
          data_type = data_type, description = DESCRIPTION})
    local ids = query("SELECT MAX(IDENTITY_ID) FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id",
        {model_id = model_id, version_id = version_id})
    identity_id = ids[1][1]
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
exit({{identity_id, model_name, entity_name, identity_name, identity_kind, data_type}}, [[
  IDENTITY_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), IDENTITY_KIND VARCHAR(32), DATA_TYPE VARCHAR(128)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING(
  MODEL_NAME, IDENTITY_NAME, REPRESENTATION_NAME, SOURCE_EXPRESSION, BINDING_KIND
)
RETURNS TABLE AS
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function upper(value) return string.upper(trim(value)) end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local model_name = trim(MODEL_NAME)
local identity_name = trim(IDENTITY_NAME)
local representation_name = trim(REPRESENTATION_NAME)
local source_expression = trim(SOURCE_EXPRESSION)
local binding_kind = upper(BINDING_KIND)
if source_expression == "" then error("SEMANTIC_ADMIN_001: SOURCE_EXPRESSION is required") end
if binding_kind ~= "DIRECT" and binding_kind ~= "MAPPED" then
    error("SEMANTIC_ADMIN_003: BINDING_KIND must be DIRECT or MAPPED")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, si.ENTITY_ID, si.IDENTITY_ID,
           er.REPRESENTATION_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.MODEL_ID = m.MODEL_ID AND si.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name) AND si.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = si.ENTITY_ID AND er.VERSION_ID = si.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, identity_name = identity_name,
      representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_049: identity or representation not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local identity_id = row_value(rows[1], "IDENTITY_ID", 4)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 5)
local existing = query([[
    SELECT IDENTITY_BINDING_ID FROM SYS_SEMANTIC.IDENTITY_BINDINGS
    WHERE IDENTITY_ID = :identity_id AND REPRESENTATION_ID = :representation_id
      AND STATUS = 'ACTIVE'
]], {identity_id = identity_id, representation_id = representation_id})
local binding_id
if existing ~= nil and #existing > 0 then
    binding_id = row_value(existing[1], "IDENTITY_BINDING_ID", 1)
    query([[
        UPDATE SYS_SEMANTIC.IDENTITY_BINDINGS
        SET SOURCE_EXPRESSION = :source_expression, BINDING_KIND = :binding_kind,
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE IDENTITY_BINDING_ID = :binding_id
    ]], {binding_id = binding_id, source_expression = source_expression,
          binding_kind = binding_kind})
else
    query([[
        INSERT INTO SYS_SEMANTIC.IDENTITY_BINDINGS (
          MODEL_ID, VERSION_ID, ENTITY_ID, IDENTITY_ID, REPRESENTATION_ID,
          SOURCE_EXPRESSION, BINDING_KIND, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :identity_id, :representation_id,
          :source_expression, :binding_kind, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          identity_id = identity_id, representation_id = representation_id,
          source_expression = source_expression, binding_kind = binding_kind})
    local ids = query("SELECT MAX(IDENTITY_BINDING_ID) FROM SYS_SEMANTIC.IDENTITY_BINDINGS WHERE IDENTITY_ID = :identity_id",
        {identity_id = identity_id})
    binding_id = ids[1][1]
end
if binding_kind == "DIRECT" then
    query("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_BINDING_ID = :binding_id",
        {binding_id = binding_id})
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
exit({{binding_id, model_name, identity_name, representation_name,
    source_expression, binding_kind}}, [[
  IDENTITY_BINDING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256),
  SOURCE_EXPRESSION VARCHAR(2000000), BINDING_KIND VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_MAPPING_RELATION(
  MODEL_NAME, IDENTITY_NAME, REPRESENTATION_NAME, SOURCE_SCHEMA, SOURCE_OBJECT,
  SOURCE_LOCAL_COLUMN, SEMANTIC_KEY_COLUMN, CERTIFICATION_STATUS
)
RETURNS TABLE AS
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function upper(value) return string.upper(trim(value)) end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local certification = upper(CERTIFICATION_STATUS)
if trim(MODEL_NAME) == "" or trim(IDENTITY_NAME) == ""
    or trim(REPRESENTATION_NAME) == "" or trim(SOURCE_SCHEMA) == ""
    or trim(SOURCE_OBJECT) == "" or trim(SOURCE_LOCAL_COLUMN) == ""
    or trim(SEMANTIC_KEY_COLUMN) == "" then
    error("SEMANTIC_ADMIN_001: model, identity, representation, mapping source, and mapping columns are required")
end
if certification ~= "CERTIFIED" then
    error("SEMANTIC_ADMIN_003: runtime identity mappings must be CERTIFIED")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, ib.IDENTITY_BINDING_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.MODEL_ID = m.MODEL_ID AND si.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name) AND si.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = si.ENTITY_ID AND er.VERSION_ID = si.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.IDENTITY_BINDINGS ib
      ON ib.IDENTITY_ID = si.IDENTITY_ID AND ib.REPRESENTATION_ID = er.REPRESENTATION_ID
     AND ib.BINDING_KIND = 'MAPPED' AND ib.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = trim(MODEL_NAME), identity_name = trim(IDENTITY_NAME),
      representation_name = trim(REPRESENTATION_NAME)})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_050: active MAPPED identity binding not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local binding_id = row_value(rows[1], "IDENTITY_BINDING_ID", 3)
query("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_BINDING_ID = :binding_id",
    {binding_id = binding_id})
query([[
    INSERT INTO SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS (
      MODEL_ID, VERSION_ID, IDENTITY_BINDING_ID, SOURCE_SCHEMA, SOURCE_OBJECT,
      SOURCE_LOCAL_COLUMN, SEMANTIC_KEY_COLUMN, CERTIFICATION_STATUS, STATUS
    ) VALUES (
      :model_id, :version_id, :binding_id, :source_schema, :source_object,
      :source_local_column, :semantic_key_column, :certification, 'ACTIVE'
    )
]], {model_id = model_id, version_id = version_id, binding_id = binding_id,
      source_schema = trim(SOURCE_SCHEMA), source_object = trim(SOURCE_OBJECT),
      source_local_column = trim(SOURCE_LOCAL_COLUMN),
      semantic_key_column = trim(SEMANTIC_KEY_COLUMN), certification = certification})
local ids = query("SELECT MAX(IDENTITY_MAPPING_ID) FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_BINDING_ID = :binding_id",
    {binding_id = binding_id})
local mapping_id = ids[1][1]
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
exit({{mapping_id, trim(MODEL_NAME), trim(IDENTITY_NAME),
    trim(REPRESENTATION_NAME), trim(SOURCE_SCHEMA), trim(SOURCE_OBJECT), certification}}, [[
  IDENTITY_MAPPING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256),
  SOURCE_SCHEMA VARCHAR(256), SOURCE_OBJECT VARCHAR(256),
  CERTIFICATION_STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_MAPPING_RELATION(
  MODEL_NAME, IDENTITY_NAME, REPRESENTATION_NAME
)
RETURNS TABLE AS
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local model_name = trim(MODEL_NAME)
local identity_name = trim(IDENTITY_NAME)
local representation_name = trim(REPRESENTATION_NAME)
if model_name == "" or identity_name == "" or representation_name == "" then
    error("SEMANTIC_ADMIN_001: model, identity, and representation are required")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, im.IDENTITY_MAPPING_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.MODEL_ID = m.MODEL_ID AND si.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name) AND si.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = si.ENTITY_ID AND er.VERSION_ID = si.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.IDENTITY_BINDINGS ib
      ON ib.IDENTITY_ID = si.IDENTITY_ID AND ib.REPRESENTATION_ID = er.REPRESENTATION_ID
     AND ib.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS im
      ON im.IDENTITY_BINDING_ID = ib.IDENTITY_BINDING_ID AND im.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, identity_name = identity_name,
      representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_052: active identity mapping relation not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local mapping_id = row_value(rows[1], "IDENTITY_MAPPING_ID", 3)
query("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_MAPPING_ID = :mapping_id",
    {mapping_id = mapping_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
exit({{mapping_id, model_name, identity_name, representation_name, "REMOVED"}}, [[
  IDENTITY_MAPPING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING(
  MODEL_NAME, IDENTITY_NAME, REPRESENTATION_NAME
)
RETURNS TABLE AS
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
end
local model_name = trim(MODEL_NAME)
local identity_name = trim(IDENTITY_NAME)
local representation_name = trim(REPRESENTATION_NAME)
if model_name == "" or identity_name == "" or representation_name == "" then
    error("SEMANTIC_ADMIN_001: model, identity, and representation are required")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, ib.IDENTITY_BINDING_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.MODEL_ID = m.MODEL_ID AND si.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name) AND si.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = si.ENTITY_ID AND er.VERSION_ID = si.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.IDENTITY_BINDINGS ib
      ON ib.IDENTITY_ID = si.IDENTITY_ID AND ib.REPRESENTATION_ID = er.REPRESENTATION_ID
     AND ib.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, identity_name = identity_name,
      representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_053: active identity binding not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local binding_id = row_value(rows[1], "IDENTITY_BINDING_ID", 3)
local mapping_count = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS
    WHERE IDENTITY_BINDING_ID = :binding_id AND STATUS = 'ACTIVE'
]], {binding_id = binding_id})
if tonumber(mapping_count or 0) > 0 then
    error("SEMANTIC_ADMIN_054: cannot remove an identity binding with an active mapping relation; remove the mapping relation first")
end
query("DELETE FROM SYS_SEMANTIC.IDENTITY_BINDINGS WHERE IDENTITY_BINDING_ID = :binding_id",
    {binding_id = binding_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
exit({{binding_id, model_name, identity_name, representation_name, "REMOVED"}}, [[
  IDENTITY_BINDING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY(
  MODEL_NAME, ENTITY_NAME, IDENTITY_NAME
)
RETURNS TABLE AS
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
end
local model_name = trim(MODEL_NAME)
local entity_name = trim(ENTITY_NAME)
local identity_name = trim(IDENTITY_NAME)
if model_name == "" or entity_name == "" or identity_name == "" then
    error("SEMANTIC_ADMIN_001: model, entity, and identity are required")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, si.IDENTITY_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.ENTITY_ID = e.ENTITY_ID AND si.VERSION_ID = e.VERSION_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name) AND si.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
      identity_name = identity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_055: active semantic identity not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local identity_id = row_value(rows[1], "IDENTITY_ID", 3)
local binding_count = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.IDENTITY_BINDINGS
    WHERE IDENTITY_ID = :identity_id AND STATUS = 'ACTIVE'
]], {identity_id = identity_id})
if tonumber(binding_count or 0) > 0 then
    error("SEMANTIC_ADMIN_056: cannot remove a semantic identity with active bindings; remove the bindings first")
end
query("DELETE FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES WHERE IDENTITY_ID = :identity_id",
    {identity_id = identity_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
exit({{identity_id, model_name, entity_name, identity_name, "REMOVED"}}, [[
  IDENTITY_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY(
  MODEL_NAME,
  ENTITY_NAME,
  REPRESENTATION_NAME,
  AUTHORITY_ROLE
)
RETURNS TABLE AS
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function upper(value) return string.upper(trim(value)) end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local model_name = trim(MODEL_NAME)
local entity_name = trim(ENTITY_NAME)
local representation_name = trim(REPRESENTATION_NAME)
local authority_role = upper(AUTHORITY_ROLE)
if model_name == "" or entity_name == "" or representation_name == "" then
    error("SEMANTIC_ADMIN_001: model, entity, and representation names are required")
end
if authority_role ~= "AUTHORITATIVE" and authority_role ~= "PREFER"
    and authority_role ~= "SUPPLEMENTAL" then
    error("SEMANTIC_ADMIN_003: AUTHORITY_ROLE must be AUTHORITATIVE, PREFER, or SUPPLEMENTAL")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID, er.REPRESENTATION_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
      representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_047: active representation not found: " .. representation_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 4)
local existing = query([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.REPRESENTATION_AUTHORITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND REPRESENTATION_ID = :representation_id
]], {model_id = model_id, version_id = version_id,
      representation_id = representation_id})
if tonumber(existing[1][1] or 0) == 0 then
    query([[
        INSERT INTO SYS_SEMANTIC.REPRESENTATION_AUTHORITIES (
          MODEL_ID, VERSION_ID, ENTITY_ID, REPRESENTATION_ID, AUTHORITY_ROLE, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :representation_id, :authority_role, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          representation_id = representation_id, authority_role = authority_role})
else
    query([[
        UPDATE SYS_SEMANTIC.REPRESENTATION_AUTHORITIES
        SET AUTHORITY_ROLE = :authority_role, STATUS = 'ACTIVE',
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND REPRESENTATION_ID = :representation_id
    ]], {model_id = model_id, version_id = version_id,
          representation_id = representation_id, authority_role = authority_role})
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})
exit({{model_name, entity_name, representation_name, authority_role}}, [[
  MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256), AUTHORITY_ROLE VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY(
  MODEL_NAME,
  ATTRIBUTE_TYPE,
  ATTRIBUTE_NAME,
  FUSION_STRATEGY
)
RETURNS TABLE AS
local function trim(value) return tostring(value or ""):match("^%s*(.-)%s*$") end
local function upper(value) return string.upper(trim(value)) end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local model_name = trim(MODEL_NAME)
local attribute_type = upper(ATTRIBUTE_TYPE)
local attribute_name = trim(ATTRIBUTE_NAME)
local fusion_strategy = upper(FUSION_STRATEGY)
if attribute_type ~= "DIMENSION" and attribute_type ~= "FACT" then
    error("SEMANTIC_ADMIN_003: ATTRIBUTE_TYPE must be DIMENSION or FACT")
end
if fusion_strategy ~= "PREFER" and fusion_strategy ~= "COALESCE"
    and fusion_strategy ~= "RECONCILE" then
    error("SEMANTIC_ADMIN_003: FUSION_STRATEGY must be PREFER, COALESCE, or RECONCILE")
end
local table_name = attribute_type == "DIMENSION" and "DIMENSIONS" or "FACTS"
local id_column = attribute_type == "DIMENSION" and "DIMENSION_ID" or "FACT_ID"
local name_column = attribute_type == "DIMENSION" and "DIMENSION_NAME" or "FACT_NAME"
local rows = query(
    "SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, a.ENTITY_ID, a." .. id_column
      .. " FROM SYS_SEMANTIC.MODELS m JOIN SYS_SEMANTIC." .. table_name .. " a"
      .. " ON a.MODEL_ID = m.MODEL_ID AND a.VERSION_ID = m.ACTIVE_VERSION_ID"
      .. " AND UPPER(a." .. name_column .. ") = UPPER(:attribute_name)"
      .. " AND a.STATUS = 'ACTIVE' WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)",
    {model_name = model_name, attribute_name = attribute_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_021: " .. attribute_type .. " not found: " .. attribute_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local attribute_id = row_value(rows[1], id_column, 4)
local existing = query([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
]], {model_id = model_id, version_id = version_id,
      attribute_type = attribute_type, attribute_id = attribute_id})
if tonumber(existing[1][1] or 0) == 0 then
    query([[
        INSERT INTO SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES (
          MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
          FUSION_STRATEGY, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :attribute_type, :attribute_id,
          :fusion_strategy, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          attribute_type = attribute_type, attribute_id = attribute_id,
          fusion_strategy = fusion_strategy})
else
    query([[
        UPDATE SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
        SET FUSION_STRATEGY = :fusion_strategy, STATUS = 'ACTIVE',
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
    ]], {model_id = model_id, version_id = version_id,
          attribute_type = attribute_type, attribute_id = attribute_id,
          fusion_strategy = fusion_strategy})
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})
exit({{model_name, attribute_type, attribute_name, fusion_strategy}}, [[
  MODEL_NAME VARCHAR(256), ATTRIBUTE_TYPE VARCHAR(32),
  ATTRIBUTE_NAME VARCHAR(256), FUSION_STRATEGY VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE(
  MODEL_NAME,
  ENTITY_NAME,
  REPRESENTATION_NAME,
  COVERAGE_PREDICATE,
  VALID_FROM,
  VALID_TO
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function normalize_name(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. name)
    end
    return name
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local predicate = missing(COVERAGE_PREDICATE) and null or trim(COVERAGE_PREDICATE)
local valid_from = missing(VALID_FROM) and null or VALID_FROM
local valid_to = missing(VALID_TO) and null or VALID_TO
if predicate == null and (valid_from ~= null or valid_to ~= null) then
    error("SEMANTIC_ADMIN_003: coverage bounds require COVERAGE_PREDICATE")
end
if predicate ~= null and valid_from == null and valid_to == null then
    error("SEMANTIC_ADMIN_003: UNION partition requires VALID_FROM or VALID_TO")
end

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, er.REPRESENTATION_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
     AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID
     AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {
    model_name = model_name,
    entity_name = entity_name,
    representation_name = representation_name,
})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_047: active representation not found: " .. representation_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 3)

query([[
    UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    SET COVERAGE_PREDICATE = :coverage_predicate,
        VALID_FROM = :valid_from,
        VALID_TO = :valid_to,
        UPDATED_AT = CURRENT_TIMESTAMP,
        UPDATED_BY = CURRENT_USER
    WHERE REPRESENTATION_ID = :representation_id
]], {
    representation_id = representation_id,
    coverage_predicate = predicate,
    valid_from = valid_from,
    valid_to = valid_to,
})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})

exit({{representation_id, model_name, entity_name, representation_name,
    predicate == null and "NONE" or "UNION", predicate, valid_from, valid_to}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  FUSION_STRATEGY VARCHAR(32),
  COVERAGE_PREDICATE VARCHAR(2000000),
  VALID_FROM TIMESTAMP,
  VALID_TO TIMESTAMP
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION(
  MODEL_NAME,
  ENTITY_NAME,
  REPRESENTATION_NAME
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value) return tostring(value):match("^%s*(.-)%s*$") end
local function normalize_name(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. name)
    end
    return name
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function scalar(sql_text, params)
    local scalar_rows = query(sql_text, params or {})
    if scalar_rows == nil or #scalar_rows == 0 then return nil end
    return scalar_rows[1][1]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID,
           er.REPRESENTATION_ID, er.SOURCE_SCHEMA, er.SOURCE_OBJECT,
           er.SOURCE_ALIAS, e.SOURCE_ALIAS AS ENTITY_SOURCE_ALIAS,
           er.REPRESENTATION_ROLE
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
     AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID
     AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
    representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_045: active representation not found: " .. representation_name)
end
local row = rows[1]
local model_id = row_value(row, "MODEL_ID", 1)
local version_id = row_value(row, "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(row, "ENTITY_ID", 3)
local representation_id = row_value(row, "REPRESENTATION_ID", 4)
local source_schema = row_value(row, "SOURCE_SCHEMA", 5)
local source_object = row_value(row, "SOURCE_OBJECT", 6)
local source_alias = row_value(row, "SOURCE_ALIAS", 7)
local entity_source_alias = row_value(row, "ENTITY_SOURCE_ALIAS", 8)
if string.upper(tostring(source_alias)) ~= string.upper(tostring(entity_source_alias)) then
    error("SEMANTIC_ADMIN_048: representation alias does not match the entity alias: "
        .. tostring(entity_source_alias))
end
local previous_rows = query([[
    SELECT REPRESENTATION_ID, REPRESENTATION_NAME
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND REPRESENTATION_ROLE = 'PRIMARY'
      AND STATUS = 'ACTIVE'
]], {entity_id = entity_id})
local previous_representation_id = previous_rows and previous_rows[1]
    and row_value(previous_rows[1], "REPRESENTATION_ID", 1) or nil
local previous_name = previous_rows and previous_rows[1]
    and row_value(previous_rows[1], "REPRESENTATION_NAME", 2) or null
local changed = tostring(row_value(row, "REPRESENTATION_ROLE", 9)) ~= "PRIMARY"

if changed then
    local stale_default_count = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS defaults
        WHERE defaults.ENTITY_ID = :entity_id
          AND defaults.REPRESENTATION_ID = :previous_representation_id
          AND defaults.IS_DEFAULT = TRUE
          AND defaults.STATUS = 'ACTIVE'
          AND EXISTS (
            SELECT 1
            FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS explicit
            WHERE explicit.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
              AND explicit.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
              AND explicit.REPRESENTATION_ID = defaults.REPRESENTATION_ID
              AND explicit.IS_DEFAULT = FALSE
              AND explicit.STATUS = 'ACTIVE'
          )
    ]], {entity_id = entity_id,
        previous_representation_id = previous_representation_id})

    if tonumber(stale_default_count or 0) > 0 then
        -- Repair catalog states produced by the pre-fix promotion path. Move a
        -- collided compatibility default back to the requested representation
        -- when that representation has no binding for the attribute. If it
        -- already has an explicit binding, the stale default is redundant.
        query([[
            UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
            SET REPRESENTATION_ID = :representation_id,
                UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
            WHERE ATTRIBUTE_BINDING_ID IN (
              SELECT defaults.ATTRIBUTE_BINDING_ID
              FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS defaults
              WHERE defaults.ENTITY_ID = :entity_id
                AND defaults.REPRESENTATION_ID = :previous_representation_id
                AND defaults.IS_DEFAULT = TRUE
                AND defaults.STATUS = 'ACTIVE'
                AND EXISTS (
                  SELECT 1 FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS explicit
                  WHERE explicit.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
                    AND explicit.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
                    AND explicit.REPRESENTATION_ID = defaults.REPRESENTATION_ID
                    AND explicit.IS_DEFAULT = FALSE
                    AND explicit.STATUS = 'ACTIVE'
                )
                AND NOT EXISTS (
                  SELECT 1 FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS target
                  WHERE target.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
                    AND target.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
                    AND target.REPRESENTATION_ID = :representation_id
                    AND target.STATUS = 'ACTIVE'
                )
            )
        ]], {entity_id = entity_id, representation_id = representation_id,
            previous_representation_id = previous_representation_id})
        query([[
            DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
            WHERE ATTRIBUTE_BINDING_ID IN (
              SELECT defaults.ATTRIBUTE_BINDING_ID
              FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS defaults
              WHERE defaults.ENTITY_ID = :entity_id
                AND defaults.REPRESENTATION_ID = :previous_representation_id
                AND defaults.IS_DEFAULT = TRUE
                AND defaults.STATUS = 'ACTIVE'
                AND EXISTS (
                  SELECT 1 FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS explicit
                  WHERE explicit.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
                    AND explicit.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
                    AND explicit.REPRESENTATION_ID = defaults.REPRESENTATION_ID
                    AND explicit.IS_DEFAULT = FALSE
                    AND explicit.STATUS = 'ACTIVE'
                )
            )
        ]], {entity_id = entity_id,
            previous_representation_id = previous_representation_id})
        local repair_validation = query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
            {model_name = model_name})
        for _, validation_row in ipairs(repair_validation or {}) do
            if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR" then
                error("SEMANTIC_ADMIN_048: stale default bindings were repaired, but model validation still fails: "
                    .. tostring(row_value(validation_row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR")
                    .. " " .. tostring(row_value(validation_row, "MESSAGE", 5) or "validation failed"))
            end
        end
    else
        local validation_rows = query([[
            SELECT VALIDATION_RUN_ID
            FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
              AND STATUS IN ('OK', 'WARNING') AND ERROR_COUNT = 0
            ORDER BY VALIDATION_RUN_ID DESC LIMIT 1
        ]], {model_id = model_id, version_id = version_id})
        if validation_rows == nil or #validation_rows == 0 then
            error("SEMANTIC_ADMIN_048: representations must pass VALIDATE_MODEL before promotion")
        end
    end
    query([[
        UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        SET REPRESENTATION_ROLE = 'ALTERNATE',
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE ENTITY_ID = :entity_id
          AND REPRESENTATION_ROLE = 'PRIMARY'
          AND STATUS = 'ACTIVE'
    ]], {entity_id = entity_id})
    query([[
        UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        SET REPRESENTATION_ROLE = 'PRIMARY',
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE REPRESENTATION_ID = :representation_id
    ]], {representation_id = representation_id})
    query([[
        UPDATE SYS_SEMANTIC.ENTITIES
        SET SOURCE_SCHEMA = :source_schema, SOURCE_OBJECT = :source_object,
            SOURCE_ALIAS = :source_alias
        WHERE ENTITY_ID = :entity_id
    ]], {entity_id = entity_id, source_schema = source_schema,
        source_object = source_object, source_alias = source_alias})
    query([[
        UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        SET REPRESENTATION_ID = :representation_id,
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE ATTRIBUTE_BINDING_ID IN (
          SELECT defaults.ATTRIBUTE_BINDING_ID
          FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS defaults
          WHERE defaults.ENTITY_ID = :entity_id
            AND defaults.REPRESENTATION_ID = :previous_representation_id
            AND defaults.IS_DEFAULT = TRUE
            AND defaults.STATUS = 'ACTIVE'
            AND NOT EXISTS (
              SELECT 1
              FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS explicit
              WHERE explicit.ATTRIBUTE_TYPE = defaults.ATTRIBUTE_TYPE
                AND explicit.ATTRIBUTE_ID = defaults.ATTRIBUTE_ID
                AND explicit.REPRESENTATION_ID = :representation_id
                AND explicit.IS_DEFAULT = FALSE
                AND explicit.STATUS = 'ACTIVE'
            )
          )
    ]], {entity_id = entity_id, representation_id = representation_id,
        previous_representation_id = previous_representation_id})
    query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
        {version_id = version_id})
    query([[
        UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS IN ('OK', 'WARNING')
    ]], {model_id = model_id, version_id = version_id})
end

exit({{representation_id, model_name, entity_name, previous_name,
    representation_name, source_schema, source_object, changed}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  PREVIOUS_PRIMARY VARCHAR(256),
  PRIMARY_REPRESENTATION VARCHAR(256),
  SOURCE_SCHEMA VARCHAR(256),
  SOURCE_OBJECT VARCHAR(256),
  CHANGED BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION(
  MODEL_NAME,
  ENTITY_NAME,
  REPRESENTATION_NAME
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value) return tostring(value):match("^%s*(.-)%s*$") end
local function normalize_name(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. name)
    end
    return name
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function scalar(sql_text, params)
    local scalar_rows = query(sql_text, params or {})
    if scalar_rows == nil or #scalar_rows == 0 then return nil end
    return scalar_rows[1][1]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, er.REPRESENTATION_ID,
           er.REPRESENTATION_ROLE
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
    representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_045: active representation not found: " .. representation_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 3)
if tostring(row_value(rows[1], "REPRESENTATION_ROLE", 4)) == "PRIMARY" then
    error("SEMANTIC_ADMIN_047: cannot remove the PRIMARY representation; promote another representation first")
end
local binding_count = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
    WHERE REPRESENTATION_ID = :representation_id AND STATUS = 'ACTIVE'
]], {representation_id = representation_id})
if tonumber(binding_count or 0) > 0 then
    error("SEMANTIC_ADMIN_048: cannot remove a representation with active attribute bindings; remove the bindings first")
end
local identity_binding_count = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.IDENTITY_BINDINGS
    WHERE REPRESENTATION_ID = :representation_id AND STATUS = 'ACTIVE'
]], {representation_id = representation_id})
if tonumber(identity_binding_count or 0) > 0 then
    error("SEMANTIC_ADMIN_057: cannot remove a representation with active identity bindings; remove mapping relations and identity bindings first")
end
query("DELETE FROM SYS_SEMANTIC.REPRESENTATION_AUTHORITIES WHERE REPRESENTATION_ID = :representation_id",
    {representation_id = representation_id})
query("DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS WHERE REPRESENTATION_ID = :representation_id",
    {representation_id = representation_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})

exit({{representation_id, model_name, entity_name, representation_name, "REMOVED"}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(
  MODEL_NAME,
  OBJECT_NAME,
  ROOT_ENTITY_NAME,
  DESCRIPTION
) AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function entity_id(model, entity_name)
    local id = scalar([[
        SELECT ENTITY_ID
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
    if id == nil then
        error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
    end
    return id
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")
local root_entity_name = normalize_name(ROOT_ENTITY_NAME, "ROOT_ENTITY_NAME")
local model = model_row(model_name)
local root_entity_id = entity_id(model, root_entity_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(OBJECT_NAME) = UPPER(:object_name)
]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_015: duplicate semantic object: " .. object_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.SEMANTIC_OBJECTS (
      MODEL_ID, VERSION_ID, OBJECT_NAME, ROOT_ENTITY_ID, DESCRIPTION, STATUS
    ) VALUES (
      :model_id, :version_id, :object_name, :root_entity_id, :description, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    object_name = object_name,
    root_entity_id = root_entity_id,
    description = optional_text(DESCRIPTION)
})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.CREATE_SEMANTIC_OBJECT(
  MODEL_NAME,
  OBJECT_NAME,
  ROOT_ENTITY_NAME,
  DESCRIPTION
) AS
query([[
    EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(
      :model_name, :object_name, :root_entity_name, :description
    )
]], {
    model_name = MODEL_NAME,
    object_name = OBJECT_NAME,
    root_entity_name = ROOT_ENTITY_NAME,
    description = DESCRIPTION
})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  MODEL_NAME,
  RELATIONSHIP_NAME,
  FROM_ENTITY_NAME,
  TO_ENTITY_NAME,
  JOIN_CONDITION,
  CARDINALITY,
  JOIN_TYPE,
  FANOUT_POLICY
) AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function entity_id(model, entity_name)
    local id = scalar([[
        SELECT ENTITY_ID
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
    if id == nil then
        error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
    end
    return id
end

if missing(JOIN_CONDITION) then
    error("SEMANTIC_ADMIN_001: JOIN_CONDITION is required")
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local relationship_name = normalize_name(RELATIONSHIP_NAME, "RELATIONSHIP_NAME")
local from_entity_name = normalize_name(FROM_ENTITY_NAME, "FROM_ENTITY_NAME")
local to_entity_name = normalize_name(TO_ENTITY_NAME, "TO_ENTITY_NAME")
local cardinality = normalize_choice(CARDINALITY, "CARDINALITY", {"ONE_TO_ONE", "ONE_TO_MANY", "MANY_TO_ONE", "MANY_TO_MANY"})
local join_type = "LEFT"
if not missing(JOIN_TYPE) then
    join_type = normalize_choice(JOIN_TYPE, "JOIN_TYPE", {"INNER", "LEFT"})
end

local model = model_row(model_name)
local from_entity_id = entity_id(model, from_entity_name)
local to_entity_id = entity_id(model, to_entity_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.RELATIONSHIPS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(RELATIONSHIP_NAME) = UPPER(:relationship_name)
]], {model_id = model.model_id, version_id = model.version_id, relationship_name = relationship_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_016: duplicate relationship: " .. relationship_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.RELATIONSHIPS (
      MODEL_ID, VERSION_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
      JOIN_CONDITION, RELATIONSHIP_CARDINALITY, JOIN_TYPE, IS_REQUIRED, FANOUT_POLICY,
      PATH_PRIORITY, STATUS
    ) VALUES (
      :model_id, :version_id, :relationship_name, :from_entity_id, :to_entity_id,
      :join_condition, :cardinality, :join_type, FALSE, :fanout_policy,
      100, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    relationship_name = relationship_name,
    from_entity_id = from_entity_id,
    to_entity_id = to_entity_id,
    join_condition = tostring(JOIN_CONDITION),
    cardinality = cardinality,
    join_type = join_type,
    fanout_policy = optional_text(FANOUT_POLICY)
})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING(
  MODEL_NAME,
  RELATIONSHIP_NAME,
  FROM_COLUMN_NAME,
  FROM_EXPRESSION,
  TO_COLUMN_NAME,
  TO_EXPRESSION,
  ORDINAL_POSITION
) AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return trim(value)
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return row_value(rows[1], "VALUE", 1) or rows[1][1]
end

if missing(MODEL_NAME) or missing(RELATIONSHIP_NAME) then
    error("SEMANTIC_ADMIN_001: MODEL_NAME and RELATIONSHIP_NAME are required")
end
local ordinal = tonumber(ORDINAL_POSITION)
if ordinal == nil or ordinal < 1 or ordinal % 1 ~= 0 then
    error("SEMANTIC_ADMIN_003: ORDINAL_POSITION must be a positive integer")
end
local from_column = optional_text(FROM_COLUMN_NAME)
local from_expression = optional_text(FROM_EXPRESSION)
local to_column = optional_text(TO_COLUMN_NAME)
local to_expression = optional_text(TO_EXPRESSION)
if (from_column == null) == (from_expression == null) then
    error("SEMANTIC_ADMIN_003: exactly one of FROM_COLUMN_NAME and FROM_EXPRESSION is required")
end
if (to_column == null) == (to_expression == null) then
    error("SEMANTIC_ADMIN_003: exactly one of TO_COLUMN_NAME and TO_EXPRESSION is required")
end
if from_expression ~= null or to_expression ~= null then
    error("SEMANTIC_ADMIN_043: expression relationship key mappings are not supported by typed grain proofs; normalize the expression into a source view and map a column")
end
if from_column ~= null and not string.match(from_column, "^[A-Za-z_][A-Za-z0-9_]*$") then
    error("SEMANTIC_ADMIN_002: invalid FROM_COLUMN_NAME: " .. from_column)
end
if to_column ~= null and not string.match(to_column, "^[A-Za-z_][A-Za-z0-9_]*$") then
    error("SEMANTIC_ADMIN_002: invalid TO_COLUMN_NAME: " .. to_column)
end

local relationship_id = scalar([[
    SELECT r.RELATIONSHIP_ID
    FROM SYS_SEMANTIC.RELATIONSHIPS r
    JOIN SYS_SEMANTIC.MODELS m
      ON m.MODEL_ID = r.MODEL_ID
     AND m.ACTIVE_VERSION_ID = r.VERSION_ID
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
      AND UPPER(r.RELATIONSHIP_NAME) = UPPER(:relationship_name)
      AND r.STATUS = 'ACTIVE'
]], {
    model_name = trim(MODEL_NAME),
    relationship_name = trim(RELATIONSHIP_NAME),
})
if relationship_id == nil then
    error("SEMANTIC_ADMIN_016: relationship not found: " .. trim(RELATIONSHIP_NAME))
end

local existing = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
    WHERE RELATIONSHIP_ID = :relationship_id
      AND ORDINAL_POSITION = :ordinal_position
]], {relationship_id = relationship_id, ordinal_position = ordinal})
if tonumber(existing or 0) > 0 then
    query([[
        UPDATE SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
        SET FROM_COLUMN_NAME = :from_column_name,
            FROM_EXPRESSION = :from_expression,
            TO_COLUMN_NAME = :to_column_name,
            TO_EXPRESSION = :to_expression
        WHERE RELATIONSHIP_ID = :relationship_id
          AND ORDINAL_POSITION = :ordinal_position
    ]], {
        relationship_id = relationship_id,
        ordinal_position = ordinal,
        from_column_name = from_column,
        from_expression = from_expression,
        to_column_name = to_column,
        to_expression = to_expression,
    })
else
    query([[
        INSERT INTO SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS (
          RELATIONSHIP_ID, ORDINAL_POSITION, FROM_COLUMN_NAME, FROM_EXPRESSION,
          TO_COLUMN_NAME, TO_EXPRESSION
        ) VALUES (
          :relationship_id, :ordinal_position, :from_column_name, :from_expression,
          :to_column_name, :to_expression
        )
    ]], {
        relationship_id = relationship_id,
        ordinal_position = ordinal,
        from_column_name = from_column,
        from_expression = from_expression,
        to_column_name = to_column,
        to_expression = to_expression,
    })
end
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = (
        SELECT VERSION_ID FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE RELATIONSHIP_ID = :relationship_id
    )
]], {relationship_id = relationship_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS
    SET STATUS = 'STALE'
    WHERE VERSION_ID = (
        SELECT VERSION_ID FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE RELATIONSHIP_ID = :relationship_id
    )
      AND STATUS IN ('OK', 'WARNING')
]], {relationship_id = relationship_id})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  MODEL_NAME,
  OBJECT_NAME,
  ENTITY_NAME,
  DIMENSION_NAME,
  EXPRESSION,
  DATA_TYPE,
  DISPLAY_NAME,
  DESCRIPTION,
  FORMAT_HINT,
  IS_CERTIFIED
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function bool_value(value, default_value)
    if missing(value) then
        return default_value
    end
    local text = string.lower(tostring(value))
    return value == true or text == "true" or text == "1"
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function entity_id(model, entity_name)
    local id = scalar([[
        SELECT ENTITY_ID
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
    if id == nil then
        error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
    end
    return id
end

local function object_id(model, object_name)
    local id = scalar([[
        SELECT OBJECT_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if id == nil then
        error("SEMANTIC_ADMIN_017: semantic object not found: " .. object_name)
    end
    return id
end

local function add_object_column(object_id_value, kind, ref_id, column_name)
    local duplicate = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND UPPER(COLUMN_NAME) = UPPER(:column_name)
    ]], {object_id = object_id_value, column_name = column_name})
    if tonumber(duplicate or 0) > 0 then
        error("SEMANTIC_ADMIN_018: duplicate object column: " .. column_name)
    end
    local ordinal = scalar([[
        SELECT COALESCE(MAX(ORDINAL_POSITION), 0) + 1
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
    ]], {object_id = object_id_value})
    query([[
        INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
          OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
        ) VALUES (
          :object_id, :kind, :ref_id, :column_name, :ordinal, TRUE
        )
    ]], {
        object_id = object_id_value,
        kind = kind,
        ref_id = ref_id,
        column_name = column_name,
        ordinal = ordinal
    })
end

local function ensure_object_column_available(object_id_value, column_name)
    local duplicate = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND UPPER(COLUMN_NAME) = UPPER(:column_name)
    ]], {object_id = object_id_value, column_name = column_name})
    if tonumber(duplicate or 0) > 0 then
        error("SEMANTIC_ADMIN_018: duplicate object column: " .. column_name)
    end
end

local function validation_error_summary(validation_rows)
    for _, row in ipairs(validation_rows or {}) do
        if row_value(row, "SEVERITY", 1) == "ERROR" then
            local object_type = row_value(row, "OBJECT_TYPE", 2) or "OBJECT"
            local object_name = row_value(row, "OBJECT_NAME", 3) or "unknown"
            local rule_code = row_value(row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR"
            local message = row_value(row, "MESSAGE", 5) or "model validation failed"
            return tostring(object_type) .. " " .. tostring(object_name) .. " " .. tostring(rule_code) .. ": " .. tostring(message)
        end
    end
    return nil
end

local function rollback_dimension(model_name, dimension_id_value, object_id_value)
    query([[
        DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND COLUMN_KIND = 'DIMENSION'
          AND OBJECT_REF_ID = :dimension_id
    ]], {object_id = object_id_value, dimension_id = dimension_id_value})
    query([[
        DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE ATTRIBUTE_TYPE = 'DIMENSION' AND ATTRIBUTE_ID = :dimension_id
    ]], {dimension_id = dimension_id_value})
    query([[
        DELETE FROM SYS_SEMANTIC.DIMENSIONS
        WHERE DIMENSION_ID = :dimension_id
    ]], {dimension_id = dimension_id_value})
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
end

if missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_001: EXPRESSION is required")
end
if missing(DATA_TYPE) then
    error("SEMANTIC_ADMIN_001: DATA_TYPE is required")
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local dimension_name = normalize_name(DIMENSION_NAME, "DIMENSION_NAME")
local model = model_row(model_name)
local entity_id_value = entity_id(model, entity_name)
local object_id_value = object_id(model, object_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.DIMENSIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(DIMENSION_NAME) = UPPER(:dimension_name)
]], {model_id = model.model_id, version_id = model.version_id, dimension_name = dimension_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_019: duplicate dimension: " .. dimension_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.DIMENSIONS (
      MODEL_ID, VERSION_ID, ENTITY_ID, DIMENSION_NAME, EXPRESSION, DATA_TYPE,
      DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, IS_HIDDEN, IS_CERTIFIED, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :dimension_name, :expression, :data_type,
      :display_name, :description, :format_hint, FALSE, :is_certified, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id_value,
    dimension_name = dimension_name,
    expression = tostring(EXPRESSION),
    data_type = tostring(DATA_TYPE),
    display_name = optional_text(DISPLAY_NAME),
    description = optional_text(DESCRIPTION),
    format_hint = optional_text(FORMAT_HINT),
    is_certified = bool_value(IS_CERTIFIED, false)
})

local dimension_id = scalar([[
    SELECT DIMENSION_ID
    FROM SYS_SEMANTIC.DIMENSIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(DIMENSION_NAME) = UPPER(:dimension_name)
]], {model_id = model.model_id, version_id = model.version_id, dimension_name = dimension_name})
local primary_representation_id = scalar([[
    SELECT REPRESENTATION_ID
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND REPRESENTATION_ROLE = 'PRIMARY'
      AND STATUS = 'ACTIVE'
]], {entity_id = entity_id_value})
query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY, IS_DEFAULT, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, 'DIMENSION', :attribute_id,
      :representation_id, :expression, 'PREFER', 1, TRUE, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id_value,
    attribute_id = dimension_id,
    representation_id = primary_representation_id,
    expression = tostring(EXPRESSION),
})
add_object_column(object_id_value, "DIMENSION", dimension_id, dimension_name)
local validation_rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
local validation_error = validation_error_summary(validation_rows)
if validation_error ~= nil then
    rollback_dimension(model_name, dimension_id, object_id_value)
    error("SEMANTIC_ADMIN_091: dimension rejected; validation failed: " .. validation_error)
end
exit({{dimension_id, model_name, object_name, dimension_name, false, bool_value(IS_CERTIFIED, false), true}}, [[
  DIMENSION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  DIMENSION_NAME VARCHAR(256),
  WAS_UPDATE BOOLEAN,
  IS_CERTIFIED BOOLEAN,
  OBJECT_COLUMN_REGISTERED BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_OR_REPLACE_DIMENSION(
  MODEL_NAME,
  OBJECT_NAME,
  ENTITY_NAME,
  DIMENSION_NAME,
  EXPRESSION,
  DATA_TYPE,
  DISPLAY_NAME,
  DESCRIPTION,
  FORMAT_HINT,
  IS_CERTIFIED
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function bool_value(value, default_value)
    if missing(value) then
        return default_value
    end
    local text = string.lower(tostring(value))
    return value == true or text == "true" or text == "1"
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function entity_id(model, entity_name)
    local id = scalar([[
        SELECT ENTITY_ID
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
    if id == nil then
        error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
    end
    return id
end

local function object_id(model, object_name)
    local id = scalar([[
        SELECT OBJECT_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if id == nil then
        error("SEMANTIC_ADMIN_017: semantic object not found: " .. object_name)
    end
    return id
end

local function validation_error_summary(validation_rows)
    for _, row in ipairs(validation_rows or {}) do
        if row_value(row, "SEVERITY", 1) == "ERROR" then
            local object_type = row_value(row, "OBJECT_TYPE", 2) or "OBJECT"
            local object_name = row_value(row, "OBJECT_NAME", 3) or "unknown"
            local rule_code = row_value(row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR"
            local message = row_value(row, "MESSAGE", 5) or "model validation failed"
            return tostring(object_type) .. " " .. tostring(object_name) .. " " .. tostring(rule_code) .. ": " .. tostring(message)
        end
    end
    return nil
end

if missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_001: EXPRESSION is required")
end
if missing(DATA_TYPE) then
    error("SEMANTIC_ADMIN_001: DATA_TYPE is required")
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local dimension_name = normalize_name(DIMENSION_NAME, "DIMENSION_NAME")
local model = model_row(model_name)
local entity_id_value = entity_id(model, entity_name)
local object_id_value = object_id(model, object_name)

local existing_id = scalar([[
    SELECT DIMENSION_ID
    FROM SYS_SEMANTIC.DIMENSIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(DIMENSION_NAME) = UPPER(:dimension_name)
]], {model_id = model.model_id, version_id = model.version_id, dimension_name = dimension_name})

local was_update = existing_id ~= nil
local dimension_id

if was_update then
    query([[
        UPDATE SYS_SEMANTIC.DIMENSIONS
           SET ENTITY_ID    = :entity_id,
               EXPRESSION   = :expression,
               DATA_TYPE    = :data_type,
               DISPLAY_NAME = :display_name,
               DESCRIPTION  = :description,
               FORMAT_HINT  = :format_hint,
               IS_CERTIFIED = :is_certified
         WHERE DIMENSION_ID = :dimension_id
    ]], {
        entity_id    = entity_id_value,
        expression   = tostring(EXPRESSION),
        data_type    = tostring(DATA_TYPE),
        display_name = optional_text(DISPLAY_NAME),
        description  = optional_text(DESCRIPTION),
        format_hint  = optional_text(FORMAT_HINT),
        is_certified = bool_value(IS_CERTIFIED, false),
        dimension_id = existing_id,
    })
    dimension_id = existing_id
else
    query([[
        INSERT INTO SYS_SEMANTIC.DIMENSIONS (
          MODEL_ID, VERSION_ID, ENTITY_ID, DIMENSION_NAME, EXPRESSION, DATA_TYPE,
          DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, IS_HIDDEN, IS_CERTIFIED, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :dimension_name, :expression, :data_type,
          :display_name, :description, :format_hint, FALSE, :is_certified, 'ACTIVE'
        )
    ]], {
        model_id     = model.model_id,
        version_id   = model.version_id,
        entity_id    = entity_id_value,
        dimension_name = dimension_name,
        expression   = tostring(EXPRESSION),
        data_type    = tostring(DATA_TYPE),
        display_name = optional_text(DISPLAY_NAME),
        description  = optional_text(DESCRIPTION),
        format_hint  = optional_text(FORMAT_HINT),
        is_certified = bool_value(IS_CERTIFIED, false)
    })
    dimension_id = scalar([[
        SELECT DIMENSION_ID
        FROM SYS_SEMANTIC.DIMENSIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(DIMENSION_NAME) = UPPER(:dimension_name)
    ]], {model_id = model.model_id, version_id = model.version_id, dimension_name = dimension_name})
    local ordinal = scalar([[
        SELECT COALESCE(MAX(ORDINAL_POSITION), 0) + 1
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
    ]], {object_id = object_id_value})
    query([[
        INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
          OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
        ) VALUES (
          :object_id, 'DIMENSION', :dimension_id, :column_name, :ordinal, TRUE
        )
    ]], {
        object_id    = object_id_value,
        dimension_id = dimension_id,
        column_name  = dimension_name,
        ordinal      = ordinal,
    })
end

local default_binding_id = scalar([[
    SELECT ATTRIBUTE_BINDING_ID
    FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
    WHERE ATTRIBUTE_TYPE = 'DIMENSION'
      AND ATTRIBUTE_ID = :dimension_id
      AND IS_DEFAULT = TRUE
      AND STATUS = 'ACTIVE'
]], {dimension_id = dimension_id})
local primary_representation_id = scalar([[
    SELECT REPRESENTATION_ID
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND REPRESENTATION_ROLE = 'PRIMARY'
      AND STATUS = 'ACTIVE'
]], {entity_id = entity_id_value})
if default_binding_id == nil then
    query([[
        INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
          MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
          REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
          BINDING_PRIORITY, IS_DEFAULT, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, 'DIMENSION', :dimension_id,
          :representation_id, :expression, 'PREFER', 1, TRUE, 'ACTIVE'
        )
    ]], {model_id = model.model_id, version_id = model.version_id,
        entity_id = entity_id_value, dimension_id = dimension_id,
        representation_id = primary_representation_id, expression = tostring(EXPRESSION)})
else
    query([[
        UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        SET ENTITY_ID = :entity_id, REPRESENTATION_ID = :representation_id,
            SOURCE_EXPRESSION = :expression,
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE ATTRIBUTE_BINDING_ID = :binding_id
    ]], {entity_id = entity_id_value, representation_id = primary_representation_id,
        expression = tostring(EXPRESSION), binding_id = default_binding_id})
end

local validation_rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
local validation_error = validation_error_summary(validation_rows)
if validation_error ~= nil then
    if not was_update then
        query([[DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE OBJECT_ID = :object_id AND COLUMN_KIND = 'DIMENSION' AND OBJECT_REF_ID = :dimension_id]], {object_id = object_id_value, dimension_id = dimension_id})
        query([[DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE ATTRIBUTE_TYPE = 'DIMENSION' AND ATTRIBUTE_ID = :dimension_id]], {dimension_id = dimension_id})
        query([[DELETE FROM SYS_SEMANTIC.DIMENSIONS WHERE DIMENSION_ID = :dimension_id]], {dimension_id = dimension_id})
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
    end
    error("SEMANTIC_ADMIN_091: dimension rejected; validation failed: " .. validation_error)
end
exit({{dimension_id, model_name, object_name, dimension_name, was_update, bool_value(IS_CERTIFIED, false), not was_update}}, [[
  DIMENSION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  DIMENSION_NAME VARCHAR(256),
  WAS_UPDATE BOOLEAN,
  IS_CERTIFIED BOOLEAN,
  OBJECT_COLUMN_REGISTERED BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_DIMENSION(
  MODEL_NAME,
  OBJECT_NAME,
  DIMENSION_NAME
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function object_id(model, object_name)
    local id = scalar([[
        SELECT OBJECT_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if id == nil then
        error("SEMANTIC_ADMIN_017: semantic object not found: " .. object_name)
    end
    return id
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")
local dimension_name = normalize_name(DIMENSION_NAME, "DIMENSION_NAME")
local model = model_row(model_name)
local object_id_value = object_id(model, object_name)

local dimension_id = scalar([[
    SELECT DIMENSION_ID
    FROM SYS_SEMANTIC.DIMENSIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(DIMENSION_NAME) = UPPER(:dimension_name)
]], {model_id = model.model_id, version_id = model.version_id, dimension_name = dimension_name})

if dimension_id == nil then
    error("SEMANTIC_ADMIN_015: dimension not found: " .. dimension_name)
end

query([[
    DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
     WHERE OBJECT_ID = :object_id
       AND COLUMN_KIND = 'DIMENSION'
       AND OBJECT_REF_ID = :dimension_id
]], {object_id = object_id_value, dimension_id = dimension_id})

query([[
    DELETE FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
     WHERE ATTRIBUTE_TYPE = 'DIMENSION'
       AND ATTRIBUTE_ID = :dimension_id
]], {dimension_id = dimension_id})

query([[
    DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
     WHERE ATTRIBUTE_TYPE = 'DIMENSION'
       AND ATTRIBUTE_ID = :dimension_id
]], {dimension_id = dimension_id})

query([[
    DELETE FROM SYS_SEMANTIC.DIMENSIONS
     WHERE DIMENSION_ID = :dimension_id
]], {dimension_id = dimension_id})

query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})

exit({{"OK", model_name, object_name, dimension_name}}, [[
  STATUS VARCHAR(32),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  DIMENSION_NAME VARCHAR(256)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  MODEL_NAME,
  ENTITY_NAME,
  FACT_NAME,
  EXPRESSION,
  DATA_TYPE,
  ADDITIVE_POLICY,
  DISPLAY_NAME,
  DESCRIPTION,
  IS_PRIVATE,
  IS_CERTIFIED
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function bool_value(value, default_value)
    if missing(value) then
        return default_value
    end
    local text = string.lower(tostring(value))
    return value == true or text == "true" or text == "1"
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function entity_id(model, entity_name)
    local id = scalar([[
        SELECT ENTITY_ID
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
    if id == nil then
        error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
    end
    return id
end

local function validation_error_summary(validation_rows)
    for _, row in ipairs(validation_rows or {}) do
        if row_value(row, "SEVERITY", 1) == "ERROR" then
            local object_type = row_value(row, "OBJECT_TYPE", 2) or "OBJECT"
            local object_name = row_value(row, "OBJECT_NAME", 3) or "unknown"
            local rule_code = row_value(row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR"
            local message = row_value(row, "MESSAGE", 5) or "model validation failed"
            return tostring(object_type) .. " " .. tostring(object_name) .. " " .. tostring(rule_code) .. ": " .. tostring(message)
        end
    end
    return nil
end

local function rollback_fact(model_name, fact_id_value)
    query([[
        DELETE FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
        WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID = :fact_id
    ]], {fact_id = fact_id_value})
    query([[
        DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID = :fact_id
    ]], {fact_id = fact_id_value})
    query([[
        DELETE FROM SYS_SEMANTIC.FACTS
        WHERE FACT_ID = :fact_id
    ]], {fact_id = fact_id_value})
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
end

if missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_001: EXPRESSION is required")
end
if missing(DATA_TYPE) then
    error("SEMANTIC_ADMIN_001: DATA_TYPE is required")
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local fact_name = normalize_name(FACT_NAME, "FACT_NAME")
local additive_policy = normalize_choice(ADDITIVE_POLICY, "ADDITIVE_POLICY", {"ADDITIVE", "SEMI_ADDITIVE", "NON_ADDITIVE"})
local model = model_row(model_name)
local entity_id_value = entity_id(model, entity_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.FACTS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(FACT_NAME) = UPPER(:fact_name)
]], {model_id = model.model_id, version_id = model.version_id, fact_name = fact_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_020: duplicate fact: " .. fact_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.FACTS (
      MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
      ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, IS_PRIVATE, IS_CERTIFIED, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :fact_name, :expression, :data_type,
      :additive_policy, :display_name, :description, :is_private, :is_certified, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id_value,
    fact_name = fact_name,
    expression = tostring(EXPRESSION),
    data_type = tostring(DATA_TYPE),
    additive_policy = additive_policy,
    display_name = optional_text(DISPLAY_NAME),
    description = optional_text(DESCRIPTION),
    is_private = bool_value(IS_PRIVATE, false),
    is_certified = bool_value(IS_CERTIFIED, false)
})
local fact_id = scalar([[
    SELECT FACT_ID
    FROM SYS_SEMANTIC.FACTS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(FACT_NAME) = UPPER(:fact_name)
]], {model_id = model.model_id, version_id = model.version_id, fact_name = fact_name})
local primary_representation_id = scalar([[
    SELECT REPRESENTATION_ID
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND REPRESENTATION_ROLE = 'PRIMARY'
      AND STATUS = 'ACTIVE'
]], {entity_id = entity_id_value})
query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY, IS_DEFAULT, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, 'FACT', :attribute_id,
      :representation_id, :expression, 'PREFER', 1, TRUE, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id_value,
    attribute_id = fact_id,
    representation_id = primary_representation_id,
    expression = tostring(EXPRESSION),
})
local validation_rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
local validation_error = validation_error_summary(validation_rows)
if validation_error ~= nil then
    rollback_fact(model_name, fact_id)
    error("SEMANTIC_ADMIN_092: fact rejected; validation failed: " .. validation_error)
end
exit({{fact_id, model_name, entity_name, fact_name, false, bool_value(IS_PRIVATE, false), bool_value(IS_CERTIFIED, false)}}, [[
  FACT_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  FACT_NAME VARCHAR(256),
  WAS_UPDATE BOOLEAN,
  IS_PRIVATE BOOLEAN,
  IS_CERTIFIED BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING(
  MODEL_NAME,
  ATTRIBUTE_TYPE,
  ATTRIBUTE_NAME,
  REPRESENTATION_NAME,
  SOURCE_EXPRESSION,
  BINDING_ROLE,
  BINDING_PRIORITY
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or string.match(tostring(value), "^%s*$") ~= nil
end
local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
end
local function normalized(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    return string.match(tostring(value), "^%s*(.-)%s*$")
end
local function choice(value, label, allowed)
    local result = string.upper(normalized(value, label))
    if not allowed[result] then
        error("SEMANTIC_ADMIN_001: unsupported " .. label .. ": " .. tostring(value))
    end
    return result
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function validation_error_signatures(rows)
    local signatures = {}
    for _, validation_row in ipairs(rows or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR" then
            local signature = table.concat({
                tostring(row_value(validation_row, "OBJECT_TYPE", 2) or ""),
                tostring(row_value(validation_row, "OBJECT_NAME", 3) or ""),
                tostring(row_value(validation_row, "RULE_CODE", 4) or ""),
                tostring(row_value(validation_row, "MESSAGE", 5) or ""),
            }, "\31")
            signatures[signature] = true
        end
    end
    return signatures
end

local model_name = normalized(MODEL_NAME, "MODEL_NAME")
local attribute_type = choice(ATTRIBUTE_TYPE, "ATTRIBUTE_TYPE", {DIMENSION = true, FACT = true})
local attribute_name = normalized(ATTRIBUTE_NAME, "ATTRIBUTE_NAME")
local representation_name = normalized(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local source_expression = normalized(SOURCE_EXPRESSION, "SOURCE_EXPRESSION")
local binding_role = choice(BINDING_ROLE, "BINDING_ROLE", {PREFER = true, FALLBACK = true})
local priority = tonumber(BINDING_PRIORITY)
if priority == nil or priority < 1 or priority % 1 ~= 0 then
    error("SEMANTIC_ADMIN_001: BINDING_PRIORITY must be a positive integer")
end

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID
    FROM SYS_SEMANTIC.MODELS m
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if rows == nil or #rows == 0 then error("SEMANTIC_ADMIN_011: model not found: " .. model_name) end
local model_id = rows[1][1]
local version_id = rows[1][2]
local table_name = attribute_type == "DIMENSION" and "DIMENSIONS" or "FACTS"
local id_column = attribute_type == "DIMENSION" and "DIMENSION_ID" or "FACT_ID"
local name_column = attribute_type == "DIMENSION" and "DIMENSION_NAME" or "FACT_NAME"
local attribute_rows = query(
    "SELECT " .. id_column .. ", ENTITY_ID FROM SYS_SEMANTIC." .. table_name
      .. " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id"
      .. " AND UPPER(" .. name_column .. ") = UPPER(:attribute_name) AND STATUS = 'ACTIVE'",
    {model_id = model_id, version_id = version_id, attribute_name = attribute_name})
if attribute_rows == nil or #attribute_rows == 0 then
    error("SEMANTIC_ADMIN_021: " .. attribute_type .. " not found: " .. attribute_name)
end
local attribute_id = attribute_rows[1][1]
local entity_id = attribute_rows[1][2]
local representation_id = scalar([[
    SELECT REPRESENTATION_ID
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      representation_name = representation_name})
if representation_id == nil then
    error("SEMANTIC_ADMIN_015: representation not found for attribute entity: " .. representation_name)
end
local duplicate = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
    WHERE ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
      AND REPRESENTATION_ID = :representation_id AND STATUS = 'ACTIVE'
]], {attribute_type = attribute_type, attribute_id = attribute_id,
      representation_id = representation_id})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_024: duplicate attribute binding: " .. attribute_name
        .. " -> " .. representation_name)
end

-- Binding authoring is a repair operation: an alternate with renamed columns
-- can be invalid until all of its bindings exist. Preserve the pre-application
-- errors and reject only errors introduced by this candidate binding.
local baseline_validation_rows = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
    {model_name = model_name})
local baseline_errors = validation_error_signatures(baseline_validation_rows)

query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :attribute_type, :attribute_id,
      :representation_id, :source_expression, :binding_role, :priority, 'ACTIVE'
    )
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      attribute_type = attribute_type, attribute_id = attribute_id,
      representation_id = representation_id, source_expression = source_expression,
      binding_role = binding_role, priority = priority})
local binding_id = scalar([[
    SELECT ATTRIBUTE_BINDING_ID FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
    WHERE ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
      AND REPRESENTATION_ID = :representation_id AND STATUS = 'ACTIVE'
]], {attribute_type = attribute_type, attribute_id = attribute_id,
      representation_id = representation_id})
local validation_rows = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
    {model_name = model_name})
for _, validation_row in ipairs(validation_rows or {}) do
    local severity = row_value(validation_row, "SEVERITY", 1)
    if tostring(severity) == "ERROR" then
        local signature = table.concat({
            tostring(row_value(validation_row, "OBJECT_TYPE", 2) or ""),
            tostring(row_value(validation_row, "OBJECT_NAME", 3) or ""),
            tostring(row_value(validation_row, "RULE_CODE", 4) or ""),
            tostring(row_value(validation_row, "MESSAGE", 5) or ""),
        }, "\31")
        if not baseline_errors[signature] then
            local rule_code = row_value(validation_row, "RULE_CODE", 4)
                or "SEMANTIC_MODEL_ERROR"
            local message = row_value(validation_row, "MESSAGE", 5)
                or "model validation failed"
            query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE ATTRIBUTE_BINDING_ID = :binding_id",
                {binding_id = binding_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_093: attribute binding rejected; candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
exit({{binding_id, model_name, attribute_type, attribute_name, representation_name,
    binding_role, priority}}, [[
  ATTRIBUTE_BINDING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32), ATTRIBUTE_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256), BINDING_ROLE VARCHAR(32),
  BINDING_PRIORITY DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_ATTRIBUTE_BINDING(
  MODEL_NAME,
  ATTRIBUTE_TYPE,
  ATTRIBUTE_NAME,
  REPRESENTATION_NAME
)
RETURNS TABLE AS
local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
end
local model_name = string.match(tostring(MODEL_NAME or ""), "^%s*(.-)%s*$")
local attribute_type = string.upper(string.match(tostring(ATTRIBUTE_TYPE or ""), "^%s*(.-)%s*$"))
local attribute_name = string.match(tostring(ATTRIBUTE_NAME or ""), "^%s*(.-)%s*$")
local representation_name = string.match(tostring(REPRESENTATION_NAME or ""), "^%s*(.-)%s*$")
if attribute_type ~= "DIMENSION" and attribute_type ~= "FACT" then
    error("SEMANTIC_ADMIN_001: ATTRIBUTE_TYPE must be DIMENSION or FACT")
end
local table_name = attribute_type == "DIMENSION" and "DIMENSIONS" or "FACTS"
local id_column = attribute_type == "DIMENSION" and "DIMENSION_ID" or "FACT_ID"
local name_column = attribute_type == "DIMENSION" and "DIMENSION_NAME" or "FACT_NAME"
local binding_rows = query(
    "SELECT ab.ATTRIBUTE_BINDING_ID, ab.MODEL_ID, ab.VERSION_ID FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS ab"
      .. " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = ab.MODEL_ID"
      .. " JOIN SYS_SEMANTIC." .. table_name .. " a ON a." .. id_column .. " = ab.ATTRIBUTE_ID"
      .. " JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er ON er.REPRESENTATION_ID = ab.REPRESENTATION_ID"
      .. " WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)"
      .. " AND ab.ATTRIBUTE_TYPE = :attribute_type"
      .. " AND UPPER(a." .. name_column .. ") = UPPER(:attribute_name)"
      .. " AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)"
      .. " AND ab.STATUS = 'ACTIVE'",
    {model_name = model_name, attribute_type = attribute_type,
     attribute_name = attribute_name, representation_name = representation_name})
if binding_rows == nil or #binding_rows == 0 then
    error("SEMANTIC_ADMIN_025: attribute binding not found")
end
local binding_id = binding_rows[1][1]
local model_id = binding_rows[1][2]
local version_id = binding_rows[1][3]
query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE ATTRIBUTE_BINDING_ID = :binding_id",
    {binding_id = binding_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})
exit({{binding_id, model_name, attribute_type, attribute_name, representation_name, "REMOVED"}}, [[
  ATTRIBUTE_BINDING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32), ATTRIBUTE_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(
  MODEL_NAME,
  OBJECT_NAME,
  METRIC_NAME,
  EXPRESSION,
  FILTER_EXPR,
  METRIC_TYPE,
  BASE_ENTITY_NAME,
  DATA_TYPE,
  DISPLAY_NAME,
  DESCRIPTION,
  FORMAT_HINT,
  IS_PRIVATE,
  IS_CERTIFIED
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function bool_value(value, default_value)
    if missing(value) then
        return default_value
    end
    local text = string.lower(tostring(value))
    return value == true or text == "true" or text == "1"
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function entity_id(model, entity_name)
    local id = scalar([[
        SELECT ENTITY_ID
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
    if id == nil then
        error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
    end
    return id
end

local function object_id(model, object_name)
    local id = scalar([[
        SELECT OBJECT_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if id == nil then
        error("SEMANTIC_ADMIN_017: semantic object not found: " .. object_name)
    end
    return id
end

local function add_object_column(object_id_value, kind, ref_id, column_name)
    local duplicate = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND UPPER(COLUMN_NAME) = UPPER(:column_name)
    ]], {object_id = object_id_value, column_name = column_name})
    if tonumber(duplicate or 0) > 0 then
        error("SEMANTIC_ADMIN_018: duplicate object column: " .. column_name)
    end
    local ordinal = scalar([[
        SELECT COALESCE(MAX(ORDINAL_POSITION), 0) + 1
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
    ]], {object_id = object_id_value})
    query([[
        INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
          OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
        ) VALUES (
          :object_id, :kind, :ref_id, :column_name, :ordinal, TRUE
        )
    ]], {
        object_id = object_id_value,
        kind = kind,
        ref_id = ref_id,
        column_name = column_name,
        ordinal = ordinal
    })
end

local function ensure_metric_object_column_available(object_id_value, column_name)
    local duplicate = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND UPPER(COLUMN_NAME) = UPPER(:column_name)
    ]], {object_id = object_id_value, column_name = column_name})
    if tonumber(duplicate or 0) > 0 then
        error("SEMANTIC_ADMIN_018: duplicate object column: " .. column_name)
    end
end

local function validation_error_summary(validation_rows)
    for _, row in ipairs(validation_rows or {}) do
        if row_value(row, "SEVERITY", 1) == "ERROR" then
            local rule_code = row_value(row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR"
            local message = row_value(row, "MESSAGE", 5) or "model validation failed"
            return tostring(rule_code) .. ": " .. tostring(message)
        end
    end
    return nil
end

local function rollback_metric(model_name, metric_id_value, object_id_value)
    query([[
        DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND COLUMN_KIND = 'METRIC'
          AND OBJECT_REF_ID = :metric_id
    ]], {object_id = object_id_value, metric_id = metric_id_value})
    query([[
        DELETE FROM SYS_SEMANTIC.METRICS
        WHERE METRIC_ID = :metric_id
    ]], {metric_id = metric_id_value})
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
end

if missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_001: EXPRESSION is required")
end
if missing(DATA_TYPE) then
    error("SEMANTIC_ADMIN_001: DATA_TYPE is required")
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")
local metric_name = normalize_name(METRIC_NAME, "METRIC_NAME")
local base_entity_name = normalize_name(BASE_ENTITY_NAME, "BASE_ENTITY_NAME")
local metric_type = normalize_choice(METRIC_TYPE, "METRIC_TYPE", {"ADDITIVE", "RATIO", "DISTINCT", "SEMI_ADDITIVE", "WINDOW", "DERIVED"})
local model = model_row(model_name)
local object_id_value = object_id(model, object_name)
local base_entity_id = entity_id(model, base_entity_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.METRICS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(METRIC_NAME) = UPPER(:metric_name)
]], {model_id = model.model_id, version_id = model.version_id, metric_name = metric_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_021: duplicate metric: " .. metric_name)
end
ensure_metric_object_column_available(object_id_value, metric_name)

query([[
    INSERT INTO SYS_SEMANTIC.METRICS (
      MODEL_ID, VERSION_ID, METRIC_NAME, EXPRESSION, FILTER_EXPR, METRIC_TYPE,
      BASE_ENTITY_ID, DATA_TYPE, DISPLAY_NAME, DESCRIPTION, FORMAT_HINT,
      IS_PRIVATE, IS_CERTIFIED, STATUS
    ) VALUES (
      :model_id, :version_id, :metric_name, :expression, :filter_expr, :metric_type,
      :base_entity_id, :data_type, :display_name, :description, :format_hint,
      :is_private, :is_certified, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    metric_name = metric_name,
    expression = tostring(EXPRESSION),
    filter_expr = optional_text(FILTER_EXPR),
    metric_type = metric_type,
    base_entity_id = base_entity_id,
    data_type = tostring(DATA_TYPE),
    display_name = optional_text(DISPLAY_NAME),
    description = optional_text(DESCRIPTION),
    format_hint = optional_text(FORMAT_HINT),
    is_private = bool_value(IS_PRIVATE, false),
    is_certified = bool_value(IS_CERTIFIED, false)
})

local metric_id = scalar([[
    SELECT METRIC_ID
    FROM SYS_SEMANTIC.METRICS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(METRIC_NAME) = UPPER(:metric_name)
]], {model_id = model.model_id, version_id = model.version_id, metric_name = metric_name})
add_object_column(object_id_value, "METRIC", metric_id, metric_name)
local validation_rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
local validation_error = validation_error_summary(validation_rows)
if validation_error ~= nil then
    rollback_metric(model_name, metric_id, object_id_value)
    error("SEMANTIC_ADMIN_090: metric rejected; validation failed: " .. validation_error)
end
exit({{metric_id, model_name, object_name, metric_name, false, bool_value(IS_PRIVATE, false), bool_value(IS_CERTIFIED, false), true}}, [[
  METRIC_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  METRIC_NAME VARCHAR(256),
  WAS_UPDATE BOOLEAN,
  IS_PRIVATE BOOLEAN,
  IS_CERTIFIED BOOLEAN,
  OBJECT_COLUMN_REGISTERED BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION(
  MODEL_NAME,
  SCOPE_TYPE,
  SCOPE_NAME,
  VENDOR_NAME,
  DATA_JSON,
  SOURCE_FORMAT,
  EXTENSION_NAME
)
RETURNS TABLE AS
local JSON_NULL = {}

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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function json_decode(text)
    if missing(text) then
        error("empty JSON payload")
    end
    text = tostring(text)
    local pos = 1

    local function peek()
        return string.sub(text, pos, pos)
    end

    local function skip_ws()
        while pos <= #text do
            local c = peek()
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                return
            end
        end
    end

    local function parse_string()
        if peek() ~= '"' then
            error("expected string at byte " .. tostring(pos))
        end
        pos = pos + 1
        while pos <= #text do
            local c = peek()
            if c == '"' then
                pos = pos + 1
                return true
            elseif c == "\\" then
                local e = string.sub(text, pos + 1, pos + 1)
                if e == '"' or e == "\\" or e == "/" or e == "b" or e == "f"
                    or e == "n" or e == "r" or e == "t" then
                    pos = pos + 2
                elseif e == "u" then
                    pos = pos + 6
                else
                    error("invalid escape at byte " .. tostring(pos))
                end
            else
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local parse_value

    local function parse_number()
        local start_pos = pos
        if peek() == "-" then
            pos = pos + 1
        end
        while string.match(peek(), "%d") do
            pos = pos + 1
        end
        if peek() == "." then
            pos = pos + 1
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        local c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then
                pos = pos + 1
            end
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        if tonumber(string.sub(text, start_pos, pos - 1)) == nil then
            error("invalid number at byte " .. tostring(start_pos))
        end
        return true
    end

    local function parse_array()
        pos = pos + 1
        skip_ws()
        if peek() == "]" then
            pos = pos + 1
            return true
        end
        while true do
            parse_value()
            skip_ws()
            local c = peek()
            if c == "]" then
                pos = pos + 1
                return true
            elseif c == "," then
                pos = pos + 1
            else
                error("expected array comma or close at byte " .. tostring(pos))
            end
        end
    end

    local function parse_object()
        pos = pos + 1
        skip_ws()
        if peek() == "}" then
            pos = pos + 1
            return true
        end
        while true do
            skip_ws()
            parse_string()
            skip_ws()
            if peek() ~= ":" then
                error("expected object colon at byte " .. tostring(pos))
            end
            pos = pos + 1
            parse_value()
            skip_ws()
            local c = peek()
            if c == "}" then
                pos = pos + 1
                return true
            elseif c == "," then
                pos = pos + 1
            else
                error("expected object comma or close at byte " .. tostring(pos))
            end
        end
    end

    function parse_value()
        skip_ws()
        local c = peek()
        if c == '"' then
            return parse_string()
        elseif c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == "-" or string.match(c, "%d") then
            return parse_number()
        elseif string.sub(text, pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif string.sub(text, pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif string.sub(text, pos, pos + 3) == "null" then
            pos = pos + 4
            return JSON_NULL
        end
        error("unexpected JSON token at byte " .. tostring(pos))
    end

    parse_value()
    skip_ws()
    if pos <= #text then
        error("unexpected trailing JSON at byte " .. tostring(pos))
    end
end

local function scoped_object_id(model, scope_type, scope_name)
    if scope_type == "MODEL" then
        return model.model_id
    end
    if missing(scope_name) then
        error("SEMANTIC_ADMIN_001: SCOPE_NAME is required for " .. scope_type)
    end
    local table_name
    local id_column
    local name_column
    if scope_type == "SEMANTIC_OBJECT" then
        table_name = "SYS_SEMANTIC.SEMANTIC_OBJECTS"
        id_column = "OBJECT_ID"
        name_column = "OBJECT_NAME"
    elseif scope_type == "ENTITY" then
        table_name = "SYS_SEMANTIC.ENTITIES"
        id_column = "ENTITY_ID"
        name_column = "ENTITY_NAME"
    elseif scope_type == "RELATIONSHIP" then
        table_name = "SYS_SEMANTIC.RELATIONSHIPS"
        id_column = "RELATIONSHIP_ID"
        name_column = "RELATIONSHIP_NAME"
    elseif scope_type == "DIMENSION" then
        table_name = "SYS_SEMANTIC.DIMENSIONS"
        id_column = "DIMENSION_ID"
        name_column = "DIMENSION_NAME"
    elseif scope_type == "FACT" then
        table_name = "SYS_SEMANTIC.FACTS"
        id_column = "FACT_ID"
        name_column = "FACT_NAME"
    elseif scope_type == "METRIC" then
        table_name = "SYS_SEMANTIC.METRICS"
        id_column = "METRIC_ID"
        name_column = "METRIC_NAME"
    else
        error("SEMANTIC_ADMIN_003: invalid SCOPE_TYPE: " .. tostring(scope_type))
    end
    local sql_text = "SELECT " .. id_column .. " FROM " .. table_name ..
        " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(" .. name_column .. ") = UPPER(:scope_name)"
    local id = scalar(sql_text, {model_id = model.model_id, version_id = model.version_id, scope_name = scope_name})
    if id == nil then
        error("SEMANTIC_ADMIN_022: " .. scope_type .. " not found: " .. tostring(scope_name))
    end
    return id
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local scope_type = normalize_choice(SCOPE_TYPE, "SCOPE_TYPE", {"MODEL", "SEMANTIC_OBJECT", "ENTITY", "RELATIONSHIP", "DIMENSION", "FACT", "METRIC"})
if missing(VENDOR_NAME) then
    error("SEMANTIC_ADMIN_001: VENDOR_NAME is required")
end
if missing(DATA_JSON) then
    error("SEMANTIC_ADMIN_001: DATA_JSON is required")
end
local ok, json_error = pcall(json_decode, DATA_JSON)
if not ok then
    error("SEMANTIC_ADMIN_040: DATA_JSON must be valid JSON: " .. tostring(json_error))
end
local vendor_name = trim(VENDOR_NAME)
local source_format = missing(SOURCE_FORMAT) and "OSI" or upper(trim(SOURCE_FORMAT))
local extension_name = missing(EXTENSION_NAME) and "default" or trim(EXTENSION_NAME)
local scope_name = missing(SCOPE_NAME) and null or trim(SCOPE_NAME)
local model = model_row(model_name)
local scope_id = scoped_object_id(model, scope_type, scope_name)

local existing_id = scalar([[
    SELECT CUSTOM_EXTENSION_ID
    FROM SYS_SEMANTIC.CUSTOM_EXTENSIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND SCOPE_TYPE = :scope_type
      AND SCOPE_ID = :scope_id
      AND UPPER(VENDOR_NAME) = UPPER(:vendor_name)
      AND UPPER(SOURCE_FORMAT) = UPPER(:source_format)
      AND UPPER(EXTENSION_NAME) = UPPER(:extension_name)
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    scope_type = scope_type,
    scope_id = scope_id,
    vendor_name = vendor_name,
    source_format = source_format,
    extension_name = extension_name,
})

local was_update = false
if existing_id ~= nil then
    was_update = true
    query([[
        UPDATE SYS_SEMANTIC.CUSTOM_EXTENSIONS
        SET DATA_JSON = :data_json,
            UPDATED_AT = CURRENT_TIMESTAMP,
            UPDATED_BY = CURRENT_USER
        WHERE CUSTOM_EXTENSION_ID = :custom_extension_id
    ]], {custom_extension_id = existing_id, data_json = tostring(DATA_JSON)})
else
    query([[
        INSERT INTO SYS_SEMANTIC.CUSTOM_EXTENSIONS (
          MODEL_ID, VERSION_ID, SCOPE_TYPE, SCOPE_ID, VENDOR_NAME,
          EXTENSION_NAME, SOURCE_FORMAT, DATA_JSON
        ) VALUES (
          :model_id, :version_id, :scope_type, :scope_id, :vendor_name,
          :extension_name, :source_format, :data_json
        )
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        scope_type = scope_type,
        scope_id = scope_id,
        vendor_name = vendor_name,
        extension_name = extension_name,
        source_format = source_format,
        data_json = tostring(DATA_JSON),
    })
    existing_id = scalar([[
        SELECT MAX(CUSTOM_EXTENSION_ID)
        FROM SYS_SEMANTIC.CUSTOM_EXTENSIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND SCOPE_TYPE = :scope_type
          AND SCOPE_ID = :scope_id
          AND UPPER(VENDOR_NAME) = UPPER(:vendor_name)
          AND UPPER(SOURCE_FORMAT) = UPPER(:source_format)
          AND UPPER(EXTENSION_NAME) = UPPER(:extension_name)
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        scope_type = scope_type,
        scope_id = scope_id,
        vendor_name = vendor_name,
        source_format = source_format,
        extension_name = extension_name,
    })
end

exit({{existing_id, model_name, scope_type, scope_name, vendor_name, extension_name, source_format, was_update}}, [[
  CUSTOM_EXTENSION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  SCOPE_TYPE VARCHAR(64),
  SCOPE_NAME VARCHAR(512),
  VENDOR_NAME VARCHAR(256),
  EXTENSION_NAME VARCHAR(256),
  SOURCE_FORMAT VARCHAR(64),
  WAS_UPDATE BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.GET_CUSTOM_EXTENSIONS(
  MODEL_NAME,
  SCOPE_TYPE,
  SCOPE_NAME,
  VENDOR_NAME
)
RETURNS TABLE AS
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        return null
    end
    local choice = upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function scoped_object_id(model, scope_type, scope_name)
    if missing(scope_type) then
        return null
    end
    if scope_type == "MODEL" then
        return model.model_id
    end
    if missing(scope_name) then
        error("SEMANTIC_ADMIN_001: SCOPE_NAME is required for " .. scope_type)
    end
    local table_name
    local id_column
    local name_column
    if scope_type == "SEMANTIC_OBJECT" then
        table_name = "SYS_SEMANTIC.SEMANTIC_OBJECTS"
        id_column = "OBJECT_ID"
        name_column = "OBJECT_NAME"
    elseif scope_type == "ENTITY" then
        table_name = "SYS_SEMANTIC.ENTITIES"
        id_column = "ENTITY_ID"
        name_column = "ENTITY_NAME"
    elseif scope_type == "RELATIONSHIP" then
        table_name = "SYS_SEMANTIC.RELATIONSHIPS"
        id_column = "RELATIONSHIP_ID"
        name_column = "RELATIONSHIP_NAME"
    elseif scope_type == "DIMENSION" then
        table_name = "SYS_SEMANTIC.DIMENSIONS"
        id_column = "DIMENSION_ID"
        name_column = "DIMENSION_NAME"
    elseif scope_type == "FACT" then
        table_name = "SYS_SEMANTIC.FACTS"
        id_column = "FACT_ID"
        name_column = "FACT_NAME"
    elseif scope_type == "METRIC" then
        table_name = "SYS_SEMANTIC.METRICS"
        id_column = "METRIC_ID"
        name_column = "METRIC_NAME"
    else
        error("SEMANTIC_ADMIN_003: invalid SCOPE_TYPE: " .. tostring(scope_type))
    end
    local id = scalar("SELECT " .. id_column .. " FROM " .. table_name ..
        " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(" .. name_column .. ") = UPPER(:scope_name)",
        {model_id = model.model_id, version_id = model.version_id, scope_name = scope_name})
    if id == nil then
        error("SEMANTIC_ADMIN_022: " .. scope_type .. " not found: " .. tostring(scope_name))
    end
    return id
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local scope_type = normalize_choice(SCOPE_TYPE, "SCOPE_TYPE", {"MODEL", "SEMANTIC_OBJECT", "ENTITY", "RELATIONSHIP", "DIMENSION", "FACT", "METRIC"})
local vendor_name = missing(VENDOR_NAME) and null or trim(VENDOR_NAME)
local model = model_row(model_name)
local scope_id = scoped_object_id(model, scope_type, SCOPE_NAME)

local rows = query([[
    SELECT CUSTOM_EXTENSION_ID, SCOPE_TYPE, SCOPE_ID, SCOPE_NAME, VENDOR_NAME,
           EXTENSION_NAME, SOURCE_FORMAT, DATA_JSON
    FROM SEMANTIC_CATALOG.CUSTOM_EXTENSIONS
    WHERE MODEL_NAME = :model_name
      AND (:scope_type IS NULL OR SCOPE_TYPE = :scope_type)
      AND (:scope_id IS NULL OR SCOPE_ID = :scope_id)
      AND (:vendor_name IS NULL OR UPPER(VENDOR_NAME) = UPPER(:vendor_name))
    ORDER BY SCOPE_TYPE, SCOPE_NAME, VENDOR_NAME, EXTENSION_NAME, CUSTOM_EXTENSION_ID
]], {model_name = model_name, scope_type = scope_type, scope_id = scope_id, vendor_name = vendor_name})

local result = {}
for _, row in ipairs(rows or {}) do
    table.insert(result, {
        row_value(row, "CUSTOM_EXTENSION_ID", 1),
        row_value(row, "SCOPE_TYPE", 2),
        row_value(row, "SCOPE_ID", 3),
        row_value(row, "SCOPE_NAME", 4),
        row_value(row, "VENDOR_NAME", 5),
        row_value(row, "EXTENSION_NAME", 6),
        row_value(row, "SOURCE_FORMAT", 7),
        row_value(row, "DATA_JSON", 8),
    })
end

exit(result, [[
  CUSTOM_EXTENSION_ID DECIMAL(18,0),
  SCOPE_TYPE VARCHAR(64),
  SCOPE_ID DECIMAL(18,0),
  SCOPE_NAME VARCHAR(512),
  VENDOR_NAME VARCHAR(256),
  EXTENSION_NAME VARCHAR(256),
  SOURCE_FORMAT VARCHAR(64),
  DATA_JSON VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY(
  MODEL_NAME,
  ENTITY_NAME,
  KEY_NAME,
  KEY_KIND,
  DESCRIPTION,
  SOURCE_FORMAT
)
RETURNS TABLE AS
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local key_name = normalize_name(KEY_NAME, "KEY_NAME")
local key_kind = missing(KEY_KIND) and "UNIQUE" or normalize_choice(KEY_KIND, "KEY_KIND", {"PRIMARY", "UNIQUE", "ALTERNATE"})
local source_format = missing(SOURCE_FORMAT) and "OSI" or upper(trim(SOURCE_FORMAT))
local model = model_row(model_name)
local entity_id = scalar([[
    SELECT ENTITY_ID
    FROM SYS_SEMANTIC.ENTITIES
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
if entity_id == nil then
    error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
end

local unique_key_id = scalar([[
    SELECT UNIQUE_KEY_ID
    FROM SYS_SEMANTIC.UNIQUE_KEYS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id
      AND UPPER(KEY_NAME) = UPPER(:key_name)
]], {model_id = model.model_id, version_id = model.version_id, entity_id = entity_id, key_name = key_name})
local was_update = false
if unique_key_id ~= nil then
    was_update = true
    query([[
        UPDATE SYS_SEMANTIC.UNIQUE_KEYS
        SET KEY_KIND = :key_kind,
            DESCRIPTION = :description,
            SOURCE_FORMAT = :source_format,
            UPDATED_AT = CURRENT_TIMESTAMP,
            UPDATED_BY = CURRENT_USER
        WHERE UNIQUE_KEY_ID = :unique_key_id
    ]], {unique_key_id = unique_key_id, key_kind = key_kind, description = optional_text(DESCRIPTION), source_format = source_format})
else
    query([[
        INSERT INTO SYS_SEMANTIC.UNIQUE_KEYS (
          MODEL_ID, VERSION_ID, ENTITY_ID, KEY_NAME, KEY_KIND, DESCRIPTION, SOURCE_FORMAT
        ) VALUES (
          :model_id, :version_id, :entity_id, :key_name, :key_kind, :description, :source_format
        )
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        entity_id = entity_id,
        key_name = key_name,
        key_kind = key_kind,
        description = optional_text(DESCRIPTION),
        source_format = source_format,
    })
    unique_key_id = scalar([[
        SELECT UNIQUE_KEY_ID
        FROM SYS_SEMANTIC.UNIQUE_KEYS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND ENTITY_ID = :entity_id
          AND UPPER(KEY_NAME) = UPPER(:key_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_id = entity_id, key_name = key_name})
end

query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS
    SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model.model_id, version_id = model.version_id})

exit({{unique_key_id, model_name, entity_name, key_name, key_kind, source_format, was_update}}, [[
  UNIQUE_KEY_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  KEY_NAME VARCHAR(256),
  KEY_KIND VARCHAR(64),
  SOURCE_FORMAT VARCHAR(64),
  WAS_UPDATE BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN(
  MODEL_NAME,
  ENTITY_NAME,
  KEY_NAME,
  COLUMN_NAME,
  EXPRESSION,
  ORDINAL_POSITION
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local key_name = normalize_name(KEY_NAME, "KEY_NAME")
if missing(COLUMN_NAME) and missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_001: COLUMN_NAME or EXPRESSION is required")
end
if not missing(COLUMN_NAME) and not missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_041: specify either COLUMN_NAME or EXPRESSION, not both")
end
local column_name = missing(COLUMN_NAME) and null or trim(COLUMN_NAME)
if column_name ~= null and not string.match(column_name, "^[A-Za-z_][A-Za-z0-9_]*$") then
    error("SEMANTIC_ADMIN_002: invalid COLUMN_NAME: " .. column_name)
end
local expression = optional_text(EXPRESSION)
local model = model_row(model_name)
local unique_key_id = scalar([[
    SELECT uk.UNIQUE_KEY_ID
    FROM SYS_SEMANTIC.UNIQUE_KEYS uk
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.ENTITY_ID = uk.ENTITY_ID
    WHERE uk.MODEL_ID = :model_id
      AND uk.VERSION_ID = :version_id
      AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
      AND UPPER(uk.KEY_NAME) = UPPER(:key_name)
]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name, key_name = key_name})
if unique_key_id == nil then
    error("SEMANTIC_ADMIN_042: unique key not found: " .. key_name)
end
local ordinal = ORDINAL_POSITION
if missing(ordinal) then
    ordinal = scalar([[
        SELECT COALESCE(MAX(ORDINAL_POSITION), 0) + 1
        FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
        WHERE UNIQUE_KEY_ID = :unique_key_id
    ]], {unique_key_id = unique_key_id})
end

local existing = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
    WHERE UNIQUE_KEY_ID = :unique_key_id
      AND ORDINAL_POSITION = :ordinal
]], {unique_key_id = unique_key_id, ordinal = ordinal})
local was_update = tonumber(existing or 0) > 0
if was_update then
    query([[
        UPDATE SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
        SET COLUMN_NAME = :column_name,
            EXPRESSION = :expression
        WHERE UNIQUE_KEY_ID = :unique_key_id
          AND ORDINAL_POSITION = :ordinal
    ]], {unique_key_id = unique_key_id, ordinal = ordinal, column_name = column_name, expression = expression})
else
    query([[
        INSERT INTO SYS_SEMANTIC.UNIQUE_KEY_COLUMNS (
          UNIQUE_KEY_ID, ORDINAL_POSITION, COLUMN_NAME, EXPRESSION
        ) VALUES (
          :unique_key_id, :ordinal, :column_name, :expression
        )
    ]], {unique_key_id = unique_key_id, ordinal = ordinal, column_name = column_name, expression = expression})
end

query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS
    SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model.model_id, version_id = model.version_id})

exit({{unique_key_id, model_name, entity_name, key_name, ordinal, column_name, expression, was_update}}, [[
  UNIQUE_KEY_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  KEY_NAME VARCHAR(256),
  ORDINAL_POSITION DECIMAL(18,0),
  COLUMN_NAME VARCHAR(256),
  EXPRESSION VARCHAR(2000000),
  WAS_UPDATE BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  MODEL_NAME,
  OBJECT_TYPE,
  OBJECT_NAME,
  SYNONYM,
  SOURCE
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function semantic_object_id(model, object_type, object_name)
    local table_name
    local id_column
    local name_column
    if object_type == "SEMANTIC_OBJECT" then
        table_name = "SYS_SEMANTIC.SEMANTIC_OBJECTS"
        id_column = "OBJECT_ID"
        name_column = "OBJECT_NAME"
    elseif object_type == "ENTITY" then
        table_name = "SYS_SEMANTIC.ENTITIES"
        id_column = "ENTITY_ID"
        name_column = "ENTITY_NAME"
    elseif object_type == "DIMENSION" then
        table_name = "SYS_SEMANTIC.DIMENSIONS"
        id_column = "DIMENSION_ID"
        name_column = "DIMENSION_NAME"
    elseif object_type == "FACT" then
        table_name = "SYS_SEMANTIC.FACTS"
        id_column = "FACT_ID"
        name_column = "FACT_NAME"
    elseif object_type == "METRIC" then
        table_name = "SYS_SEMANTIC.METRICS"
        id_column = "METRIC_ID"
        name_column = "METRIC_NAME"
    else
        error("SEMANTIC_ADMIN_003: invalid OBJECT_TYPE: " .. object_type)
    end

    local sql_text = "SELECT " .. id_column .. " FROM " .. table_name ..
        " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(" .. name_column .. ") = UPPER(:object_name)"
    local id = scalar(sql_text, {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if id == nil then
        error("SEMANTIC_ADMIN_022: " .. object_type .. " not found: " .. object_name)
    end
    return id
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local object_type = normalize_choice(OBJECT_TYPE, "OBJECT_TYPE", {"SEMANTIC_OBJECT", "ENTITY", "DIMENSION", "FACT", "METRIC"})
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")
if missing(SYNONYM) then
    error("SEMANTIC_ADMIN_001: SYNONYM is required")
end
local synonym = trim(SYNONYM)
local source = "MANUAL"
if not missing(SOURCE) then
    source = string.upper(trim(SOURCE))
end

local model = model_row(model_name)
local object_id = semantic_object_id(model, object_type, object_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.SYNONYMS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND OBJECT_TYPE = :object_type
      AND OBJECT_ID = :object_id
      AND UPPER(SYNONYM) = UPPER(:synonym)
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    object_type = object_type,
    object_id = object_id,
    synonym = synonym
})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_023: duplicate synonym for object: " .. synonym)
end

query([[
    INSERT INTO SYS_SEMANTIC.SYNONYMS (
      MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE
    ) VALUES (
      :model_id, :version_id, :object_type, :object_id, :synonym, :source
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    object_type = object_type,
    object_id = object_id,
    synonym = synonym,
    source = source
})
exit({{model_name, object_type, object_name, synonym, source, true}}, [[
  MODEL_NAME VARCHAR(256),
  OBJECT_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(256),
  SYNONYM VARCHAR(512),
  SYNONYM_SOURCE VARCHAR(64),
  WAS_INSERTED BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REGISTER_MATERIALIZATION(
  MODEL_NAME,
  MATERIALIZATION_NAME,
  PHYSICAL_SCHEMA,
  PHYSICAL_OBJECT,
  MATERIALIZATION_TYPE,
  FRESHNESS_POLICY
) AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function optional_text(value)
    if missing(value) then
        return null
    end
    return tostring(value)
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function source_object_exists(schema_name, object_name)
    local count = scalar([[
        SELECT COUNT(*)
        FROM (
          SELECT TABLE_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_TABLES
          WHERE TABLE_SCHEMA = UPPER(:schema_name)
            AND TABLE_NAME = UPPER(:object_name)
          UNION ALL
          SELECT VIEW_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_VIEWS
          WHERE VIEW_SCHEMA = UPPER(:schema_name)
            AND VIEW_NAME = UPPER(:object_name)
        ) visible_objects
    ]], {schema_name = schema_name, object_name = object_name})
    return tonumber(count or 0) > 0
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local materialization_name = normalize_name(MATERIALIZATION_NAME, "MATERIALIZATION_NAME")
local physical_schema = normalize_name(PHYSICAL_SCHEMA, "PHYSICAL_SCHEMA")
local physical_object = normalize_name(PHYSICAL_OBJECT, "PHYSICAL_OBJECT")
local materialization_type = normalize_choice(MATERIALIZATION_TYPE, "MATERIALIZATION_TYPE", {"AGGREGATE"})
local model = model_row(model_name)

if not source_object_exists(physical_schema, physical_object) then
    error("SEMANTIC_ADMIN_030: materialization physical object not found: " .. physical_schema .. "." .. physical_object)
end

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.MATERIALIZATIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(MATERIALIZATION_NAME) = UPPER(:materialization_name)
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    materialization_name = materialization_name
})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_031: duplicate materialization: " .. materialization_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.MATERIALIZATIONS (
      MODEL_ID, VERSION_ID, MATERIALIZATION_NAME, PHYSICAL_SCHEMA,
      PHYSICAL_OBJECT, MATERIALIZATION_TYPE, FRESHNESS_POLICY, STATUS
    ) VALUES (
      :model_id, :version_id, :materialization_name, :physical_schema,
      :physical_object, :materialization_type, :freshness_policy, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    materialization_name = materialization_name,
    physical_schema = physical_schema,
    physical_object = physical_object,
    materialization_type = materialization_type,
    freshness_policy = optional_text(FRESHNESS_POLICY)
})
-- A new materialization expands the set of candidate plans, so drop cached
-- compile results for this model version (BUG-D-002 cache coherence).
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_MATERIALIZATION_COLUMN(
  MODEL_NAME,
  MATERIALIZATION_NAME,
  OBJECT_TYPE,
  OBJECT_NAME,
  PHYSICAL_COLUMN,
  ROLLUP_POLICY
) AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function optional_choice(value, allowed, default_value)
    if missing(value) then
        return default_value
    end
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid ROLLUP_POLICY: " .. tostring(value))
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local function materialization_id(model, materialization_name)
    local id = scalar([[
        SELECT MATERIALIZATION_ID
        FROM SYS_SEMANTIC.MATERIALIZATIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(MATERIALIZATION_NAME) = UPPER(:materialization_name)
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        materialization_name = materialization_name
    })
    if id == nil then
        error("SEMANTIC_ADMIN_032: materialization not found: " .. materialization_name)
    end
    return id
end

local function semantic_object_id(model, object_type, object_name)
    local table_name
    local id_column
    local name_column
    if object_type == "DIMENSION" then
        table_name = "SYS_SEMANTIC.DIMENSIONS"
        id_column = "DIMENSION_ID"
        name_column = "DIMENSION_NAME"
    elseif object_type == "METRIC" then
        table_name = "SYS_SEMANTIC.METRICS"
        id_column = "METRIC_ID"
        name_column = "METRIC_NAME"
    else
        error("SEMANTIC_ADMIN_003: invalid OBJECT_TYPE: " .. object_type)
    end

    local sql_text = "SELECT " .. id_column .. " FROM " .. table_name ..
        " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(" .. name_column .. ") = UPPER(:object_name)"
    local id = scalar(sql_text, {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if id == nil then
        error("SEMANTIC_ADMIN_022: " .. object_type .. " not found: " .. object_name)
    end
    return id
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local materialization_name = normalize_name(MATERIALIZATION_NAME, "MATERIALIZATION_NAME")
local object_type = normalize_choice(OBJECT_TYPE, "OBJECT_TYPE", {"DIMENSION", "METRIC"})
local object_name = normalize_name(OBJECT_NAME, "OBJECT_NAME")
local physical_column = normalize_name(PHYSICAL_COLUMN, "PHYSICAL_COLUMN")
local rollup_policy = optional_choice(ROLLUP_POLICY, {"DIRECT", "NONE", "SUM", "MIN", "MAX", "COUNT"}, object_type == "DIMENSION" and "DIRECT" or "DIRECT")
local model = model_row(model_name)
local mat_id = materialization_id(model, materialization_name)
local object_id = semantic_object_id(model, object_type, object_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.MATERIALIZATION_COLUMNS
    WHERE MATERIALIZATION_ID = :materialization_id
      AND OBJECT_TYPE = :object_type
      AND OBJECT_ID = :object_id
]], {
    materialization_id = mat_id,
    object_type = object_type,
    object_id = object_id
})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_033: duplicate materialization column: " .. object_type .. " " .. object_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.MATERIALIZATION_COLUMNS (
      MATERIALIZATION_ID, OBJECT_TYPE, OBJECT_ID, PHYSICAL_COLUMN, ROLLUP_POLICY
    ) VALUES (
      :materialization_id, :object_type, :object_id, :physical_column, :rollup_policy
    )
]], {
    materialization_id = mat_id,
    object_type = object_type,
    object_id = object_id,
    physical_column = physical_column,
    rollup_policy = rollup_policy
})
-- New materialization column means selection of this materialization may now
-- apply to additional requests, so drop cached compile results for this model
-- version (BUG-D-002 cache coherence).
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_MATERIALIZATION_STATUS(
  MODEL_NAME,
  MATERIALIZATION_NAME,
  STATUS
) AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
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

local function normalize_choice(value, label, allowed)
    if missing(value) then
        error("SEMANTIC_ADMIN_001: " .. label .. " is required")
    end
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return rows[1][1]
end

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2)
    }
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local materialization_name = normalize_name(MATERIALIZATION_NAME, "MATERIALIZATION_NAME")
local status = normalize_choice(STATUS, "STATUS", {"ACTIVE", "INACTIVE", "STALE"})
local model = model_row(model_name)
local affected = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.MATERIALIZATIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(MATERIALIZATION_NAME) = UPPER(:materialization_name)
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    materialization_name = materialization_name
})
if tonumber(affected or 0) == 0 then
    error("SEMANTIC_ADMIN_032: materialization not found: " .. materialization_name)
end

query([[
    UPDATE SYS_SEMANTIC.MATERIALIZATIONS
    SET STATUS = :status
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(MATERIALIZATION_NAME) = UPPER(:materialization_name)
]], {
    status = status,
    model_id = model.model_id,
    version_id = model.version_id,
    materialization_name = materialization_name
})
-- Materialization status changes affect materialization selection, so drop
-- cached compile results for this model version (BUG-D-002 cache coherence).
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE(
    MODEL_NAME,
    ROLE_NAME
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end
local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_ADMIN_200: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_201: invalid " .. label .. ": " .. name)
    end
    return string.upper(name)
end
local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end
local function quote_ident(name)
    return '"' .. string.gsub(tostring(name), '"', '""') .. '"'
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local role_name = normalize_name(ROLE_NAME, "ROLE_NAME")

local model_rows = query([[
    SELECT MODEL_ID, MODEL_NAME, PUBLISHED_SCHEMA
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if model_rows == nil or #model_rows == 0 then
    error("SEMANTIC_ADMIN_202: model not found: " .. model_name)
end
local model_id = row_value(model_rows[1], "MODEL_ID", 1)
local model_name_actual = row_value(model_rows[1], "MODEL_NAME", 2)
local published_schema = row_value(model_rows[1], "PUBLISHED_SCHEMA", 3)

local dup_rows = query([[
    SELECT GRANT_ID FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS
    WHERE MODEL_ID = :model_id AND UPPER(ROLE_NAME) = UPPER(:role_name) AND STATUS = 'ACTIVE'
    LIMIT 1
]], {model_id = model_id, role_name = role_name})
local grant_status = 'GRANTED'
if dup_rows ~= nil and #dup_rows > 0 then
    grant_status = 'ALREADY_GRANTED'
else
    query([[
        INSERT INTO SYS_SEMANTIC.MODEL_ROLE_GRANTS (MODEL_ID, MODEL_NAME, ROLE_NAME, PUBLISHED_SCHEMA)
        VALUES (:model_id, :model_name, :role_name, :published_schema)
    ]], {model_id = model_id, model_name = model_name_actual, role_name = role_name, published_schema = published_schema})
end

if published_schema ~= nil and tostring(published_schema) ~= "" then
    query("GRANT SELECT ON SCHEMA " .. quote_ident(published_schema) .. " TO " .. quote_ident(role_name))
end

exit({{ model_name_actual, role_name, published_schema, grant_status }}, [[
    MODEL_NAME VARCHAR(256),
    ROLE_NAME VARCHAR(256),
    PUBLISHED_SCHEMA VARCHAR(256),
    STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REVOKE_MODEL_ROLE(
    MODEL_NAME,
    ROLE_NAME
)
RETURNS TABLE AS
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end
local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_ADMIN_210: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_211: invalid " .. label .. ": " .. name)
    end
    return string.upper(name)
end
local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end
local function quote_ident(name)
    return '"' .. string.gsub(tostring(name), '"', '""') .. '"'
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local role_name = normalize_name(ROLE_NAME, "ROLE_NAME")

local model_rows = query([[
    SELECT MODEL_ID, MODEL_NAME, PUBLISHED_SCHEMA
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if model_rows == nil or #model_rows == 0 then
    error("SEMANTIC_ADMIN_212: model not found: " .. model_name)
end
local model_id = row_value(model_rows[1], "MODEL_ID", 1)
local model_name_actual = row_value(model_rows[1], "MODEL_NAME", 2)
local published_schema = row_value(model_rows[1], "PUBLISHED_SCHEMA", 3)

query([[
    UPDATE SYS_SEMANTIC.MODEL_ROLE_GRANTS
    SET STATUS = 'REVOKED'
    WHERE MODEL_ID = :model_id AND UPPER(ROLE_NAME) = UPPER(:role_name) AND STATUS = 'ACTIVE'
]], {model_id = model_id, role_name = role_name})

if published_schema ~= nil and tostring(published_schema) ~= "" then
    query("REVOKE SELECT ON SCHEMA " .. quote_ident(published_schema) .. " FROM " .. quote_ident(role_name))
end

exit({{ model_name_actual, role_name, published_schema, 'REVOKED' }}, [[
    MODEL_NAME VARCHAR(256),
    ROLE_NAME VARCHAR(256),
    PUBLISHED_SCHEMA VARCHAR(256),
    STATUS VARCHAR(32)
]])
/

-- BEGIN GENERATED VALIDATOR_RUNTIME
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.VALIDATOR_RUNTIME AS
-- Canonical relationship graph and path-proof implementation shared by the
-- validator and compiler runtimes. The packaging step embeds this source into
-- both Exasol scripts so the installed runtime has no external dependency.

local M = {}

local function key(value)
    return tostring(value)
end

local function upper(value)
    return string.upper(tostring(value or ""))
end

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function copy_list(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        out[#out + 1] = value
    end
    return out
end

local function edge_order(left, right)
    local left_priority = tonumber(left.path_priority) or 100
    local right_priority = tonumber(right.path_priority) or 100
    if left_priority ~= right_priority then
        return left_priority < right_priority
    end
    local left_id = tonumber(left.relationship and left.relationship.id) or math.huge
    local right_id = tonumber(right.relationship and right.relationship.id) or math.huge
    if left_id ~= right_id then
        return left_id < right_id
    end
    if tostring(left.name) ~= tostring(right.name) then
        return tostring(left.name) < tostring(right.name)
    end
    return key(left.to_id) < key(right.to_id)
end

local function add_edge(target, from_id, to_id, relationship, safe, reason)
    local from_key = key(from_id)
    target[from_key] = target[from_key] or {}
    target[from_key][#target[from_key] + 1] = {
        from_id = from_id,
        to_id = to_id,
        name = relationship.name,
        relationship = relationship,
        safe = safe,
        reason = reason,
        path_priority = relationship.path_priority,
    }
end

-- Build both the cardinality-preserving graph and the complete relationship
-- graph. A declared fanout policy remains compatible with the legacy planner.
-- Phase C can pass allow_many_to_many=false for the stricter multi-fact proof.
function M.build_edges(relationships, options)
    options = options or {}
    local allow_many_to_many = options.allow_many_to_many
    if allow_many_to_many == nil then
        allow_many_to_many = true
    end
    local safe_edges = {}
    local all_edges = {}

    for _, relationship in ipairs(relationships or {}) do
        local cardinality = upper(relationship.cardinality)
        local function add(from_id, to_id, safe, reason)
            add_edge(all_edges, from_id, to_id, relationship, safe, reason)
            if safe then
                add_edge(safe_edges, from_id, to_id, relationship, true, "OK")
            end
        end

        if cardinality == "ONE_TO_ONE" then
            add(relationship.from_entity_id, relationship.to_entity_id, true, "OK")
            add(relationship.to_entity_id, relationship.from_entity_id, true, "OK")
        elseif cardinality == "MANY_TO_ONE" then
            add(relationship.from_entity_id, relationship.to_entity_id, true, "OK")
            add(relationship.to_entity_id, relationship.from_entity_id, false,
                "FANOUT_REQUIRES_POLICY")
        elseif cardinality == "ONE_TO_MANY" then
            add(relationship.to_entity_id, relationship.from_entity_id, true, "OK")
            add(relationship.from_entity_id, relationship.to_entity_id, false,
                "FANOUT_REQUIRES_POLICY")
        elseif cardinality == "MANY_TO_MANY" then
            local safe = allow_many_to_many and not missing(relationship.fanout_policy)
            local reason = safe and "OK" or "MANY_TO_MANY_REQUIRES_FANOUT"
            add(relationship.from_entity_id, relationship.to_entity_id, safe, reason)
            add(relationship.to_entity_id, relationship.from_entity_id, safe, reason)
        end
    end

    for _, edge_map in ipairs({safe_edges, all_edges}) do
        for _, edges in pairs(edge_map) do
            table.sort(edges, edge_order)
        end
    end
    return safe_edges, all_edges
end

local function path_signature(path)
    local parts = {}
    for _, edge in ipairs(path) do
        parts[#parts + 1] = tostring(edge.name) .. ":" .. key(edge.to_id)
    end
    return table.concat(parts, ">")
end

local function path_text(path)
    local names = {}
    for _, edge in ipairs(path or {}) do
        names[#names + 1] = edge.name
    end
    return #names == 0 and "SELF" or table.concat(names, " > ")
end

-- Return a proof object instead of only a path. All shortest safe paths are
-- retained so semantic ambiguity cannot be hidden by relationship ordering or
-- PATH_PRIORITY.
function M.prove_path(edge_map, from_id, to_id, options)
    options = options or {}
    if missing(from_id) or missing(to_id) then
        return {ok = false, reason = "MISSING_ENTITY", candidates = {}}
    end
    if key(from_id) == key(to_id) then
        return {
            ok = true,
            reason = "OK",
            edges = {},
            path = "SELF",
            candidates = {{}},
            ambiguous = false,
        }
    end

    local queue = {{id = from_id, path = {}, visited = {[key(from_id)] = true}}}
    local best_depth_by_node = {[key(from_id)] = 0}
    local candidates = {}
    local candidate_seen = {}
    local shortest = nil
    local first_blocked_reason = nil
    local index = 1

    local max_depth = tonumber(options.max_depth) or 64
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        local depth = #current.path
        if depth < max_depth
            and (shortest == nil or depth < shortest or options.reject_any_ambiguity) then
            for _, edge in ipairs(edge_map[key(current.id)] or {}) do
                if options.require_safe and not edge.safe then
                    first_blocked_reason = first_blocked_reason or edge.reason
                else
                    local next_key = key(edge.to_id)
                    if not current.visited[next_key] then
                        local next_path = copy_list(current.path)
                        next_path[#next_path + 1] = edge
                        local next_depth = #next_path
                        if next_key == key(to_id) then
                            shortest = shortest or next_depth
                            if next_depth == shortest or options.reject_any_ambiguity then
                                local signature = path_signature(next_path)
                                if not candidate_seen[signature] then
                                    candidate_seen[signature] = true
                                    candidates[#candidates + 1] = next_path
                                end
                            end
                        elseif (shortest == nil or options.reject_any_ambiguity)
                            and (options.reject_any_ambiguity
                                or best_depth_by_node[next_key] == nil
                                or next_depth <= best_depth_by_node[next_key]) then
                            best_depth_by_node[next_key] = next_depth
                            local visited = {}
                            for entity_key, seen in pairs(current.visited) do
                                visited[entity_key] = seen
                            end
                            visited[next_key] = true
                            queue[#queue + 1] = {
                                id = edge.to_id,
                                path = next_path,
                                visited = visited,
                            }
                        end
                    end
                end
            end
        end
    end

    if #candidates == 0 then
        return {
            ok = false,
            reason = first_blocked_reason or "NO_RELATIONSHIP_PATH",
            candidates = {},
            ambiguous = false,
        }
    end

    table.sort(candidates, function(left, right)
        if #left ~= #right then return #left < #right end
        return path_signature(left) < path_signature(right)
    end)
    local ambiguous = #candidates > 1
    if ambiguous and options.reject_ambiguous then
        local descriptions = {}
        for _, candidate in ipairs(candidates) do
            descriptions[#descriptions + 1] = path_text(candidate)
        end
        return {
            ok = false,
            reason = "AMBIGUOUS_RELATIONSHIP_PATH",
            candidates = candidates,
            candidate_paths = descriptions,
            ambiguous = true,
        }
    end

    return {
        ok = true,
        reason = "OK",
        edges = candidates[1],
        path = path_text(candidates[1]),
        candidates = candidates,
        ambiguous = ambiguous,
    }
end

function M.path_text(path)
    return path_text(path)
end

function M.canonical_key(unique_key)
    local columns = {}
    for _, column in ipairs((unique_key or {}).columns or {}) do
        local column_name = nil
        local expression = nil
        if not missing(column.column_name) then
            column_name = tostring(column.column_name)
        end
        if not missing(column.expression) then
            expression = tostring(column.expression)
        end
        columns[#columns + 1] = {
            ordinal_position = tonumber(column.ordinal_position),
            column_name = column_name,
            expression = expression,
        }
    end
    table.sort(columns, function(left, right)
        return (left.ordinal_position or math.huge) < (right.ordinal_position or math.huge)
    end)
    return {
        id = unique_key and unique_key.id or nil,
        entity_id = unique_key and unique_key.entity_id or nil,
        name = unique_key and unique_key.name or nil,
        kind = upper(unique_key and unique_key.kind or "UNIQUE"),
        columns = columns,
    }
end

function M.mapping_matches_key(mappings, side, unique_key)
    local columns = (unique_key or {}).columns or {}
    if #mappings == 0 or #mappings ~= #columns then
        return false
    end
    for index, mapping in ipairs(mappings) do
        local mapped_column = mapping[side .. "_column_name"]
        local mapped_expression = mapping[side .. "_expression"]
        local key_column = columns[index]
        if not missing(key_column.column_name) then
            if upper(mapped_column) ~= upper(key_column.column_name) then
                return false
            end
        elseif tostring(mapped_expression or "") ~= tostring(key_column.expression or "") then
            return false
        end
    end
    return true
end

local function direct_column_expression(expression, source_alias)
    local text = tostring(expression or ""):match("^%s*(.-)%s*$")
    local alias, column = string.match(text,
        "^([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*([A-Za-z_][A-Za-z0-9_]*)$")
    if alias ~= nil and upper(alias) == upper(source_alias) then
        return upper(column)
    end
    alias, column = string.match(text,
        '^([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*"([^"]+)"$')
    if alias ~= nil and upper(alias) == upper(source_alias) then
        return column
    end
    return nil
end

function M.scalar_mapping_key(unique_keys, mappings, side)
    if #(mappings or {}) ~= 1 then
        return nil, "COMPOSITE_RELATIONSHIP_KEY_UNSUPPORTED"
    end
    local mapping = mappings[1]
    if missing(mapping[side .. "_column_name"])
        or not missing(mapping[side .. "_expression"]) then
        return nil, "EXPRESSION_RELATIONSHIP_KEY_UNSUPPORTED"
    end
    for _, unique_key in ipairs(unique_keys or {}) do
        local columns = unique_key.columns or {}
        if #columns == 1 and not missing(columns[1].column_name)
            and missing(columns[1].expression)
            and M.mapping_matches_key(mappings, side, unique_key) then
            return unique_key, nil
        end
    end
    return nil, "RELATIONSHIP_ENDPOINT_IS_NOT_SCALAR_UNIQUE_KEY"
end

function M.direct_identity_remap(identity, primary_representation,
        target_representation, unique_key)
    if identity == nil or primary_representation == nil
        or target_representation == nil or unique_key == nil then
        return nil, "SEMANTIC_IDENTITY_REMAP_METADATA_MISSING"
    end
    local primary_binding = identity.binding_by_representation
        and identity.binding_by_representation[key(primary_representation.id)] or nil
    local target_binding = identity.binding_by_representation
        and identity.binding_by_representation[key(target_representation.id)] or nil
    if primary_binding == nil or upper(primary_binding.kind) ~= "DIRECT" then
        return nil, "PRIMARY_IDENTITY_BINDING_NOT_DIRECT"
    end
    if target_binding == nil or upper(target_binding.kind) ~= "DIRECT" then
        return nil, "REPRESENTATION_IDENTITY_BINDING_NOT_DIRECT"
    end
    local key_column = unique_key.columns and unique_key.columns[1]
        and unique_key.columns[1].column_name or nil
    local anchor_column = direct_column_expression(primary_binding.expression,
        primary_representation.alias)
    if missing(key_column) or anchor_column == nil
        or upper(anchor_column) ~= upper(key_column) then
        return nil, "SEMANTIC_IDENTITY_NOT_ANCHORED_TO_RELATIONSHIP_KEY"
    end
    return {
        identity = identity,
        unique_key = unique_key,
        primary_binding = primary_binding,
        binding = target_binding,
    }, nil
end

ESV_GRAIN_GRAPH = M

local M = {}
local grain_graph = assert(ESV_GRAIN_GRAPH, "shared grain graph runtime is required")

local VALID_CARDINALITIES = {
    ONE_TO_ONE = true,
    ONE_TO_MANY = true,
    MANY_TO_ONE = true,
    MANY_TO_MANY = true,
}

local VALID_JOIN_TYPES = {
    INNER = true,
    LEFT = true,
}

local VALID_AGENT_SCOPE_TYPES = {
    MODEL = true,
    SEMANTIC_OBJECT = true,
    ENTITY = true,
    DIMENSION = true,
    FACT = true,
    METRIC = true,
}

local VALID_AGENT_INSTRUCTION_KINDS = {
    AMBIGUITY = true,
    DEFINITION = true,
    GENERAL = true,
    POLICY = true,
    PREFERENCE = true,
    SAFETY = true,
    STYLE = true,
}

local VALID_EXTENSION_SCOPE_TYPES = {
    MODEL = true,
    SEMANTIC_OBJECT = true,
    ENTITY = true,
    RELATIONSHIP = true,
    DIMENSION = true,
    FACT = true,
    METRIC = true,
}

local VALID_UNIQUE_KEY_KINDS = {
    PRIMARY = true,
    UNIQUE = true,
    ALTERNATE = true,
}

local SQL_WORDS = {
    ABS = true,
    AND = true,
    AS = true,
    ASC = true,
    AVG = true,
    BETWEEN = true,
    BY = true,
    CASE = true,
    CAST = true,
    COALESCE = true,
    COUNT = true,
    DATE = true,
    DATE_TRUNC = true,
    DAY = true,
    DECIMAL = true,
    DESC = true,
    DISTINCT = true,
    DOUBLE = true,
    ELSE = true,
    END = true,
    EXTRACT = true,
    FALSE = true,
    FILTER = true,
    FLOAT = true,
    FROM = true,
    GROUP = true,
    HAVING = true,
    HOUR = true,
    IF = true,
    IN = true,
    INT = true,
    INTEGER = true,
    IS = true,
    LPAD = true,
    MAX = true,
    MIN = true,
    MINUTE = true,
    MONTH = true,
    NOT = true,
    NULL = true,
    NULLIF = true,
    NUMBER = true,
    ON = true,
    OR = true,
    ORDER = true,
    OVER = true,
    PARTITION = true,
    ROUND = true,
    SECOND = true,
    SELECT = true,
    SUM = true,
    THEN = true,
    TIMESTAMP = true,
    TRUE = true,
    TRUNC = true,
    VARCHAR = true,
    WHEN = true,
    WHERE = true,
    YEAR = true,
}

-- Exasol built-in functions only. QUARTER() does not exist in Exasol -- use CEIL(MONTH(date)/3.0)
local ALLOWED_FUNCTIONS = {
    ABS = true,
    AVG = true,
    CAST = true,
    CEIL = true,
    COALESCE = true,
    CONCAT = true,
    COUNT = true,
    DATE_TRUNC = true,
    DAY = true,
    EXTRACT = true,
    FLOOR = true,
    LPAD = true,
    MAX = true,
    MIN = true,
    MONTH = true,
    NULLIF = true,
    ROUND = true,
    SUM = true,
    TO_CHAR = true,
    TO_DATE = true,
    TRUNC = true,
    YEAR = true,
}

local CAST_TARGET_TYPES = {
    BIGINT = true,
    BOOLEAN = true,
    CHAR = true,
    DATE = true,
    DEC = true,
    DECIMAL = true,
    DOUBLE = true,
    FLOAT = true,
    GEOMETRY = true,
    HASHTYPE = true,
    INT = true,
    INTEGER = true,
    INTERVAL = true,
    NUMBER = true,
    NUMERIC = true,
    REAL = true,
    SMALLINT = true,
    TIMESTAMP = true,
    TINYINT = true,
    VARCHAR = true,
    VARCHAR2 = true,
}

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return row_value(rows[1], "VALUE", 1) or row_value(rows[1], "COUNT", 1) or row_value(rows[1], "MAX", 1) or rows[1][1]
end

local function count_query(sql_text, params)
    return tonumber(scalar(sql_text, params) or 0) or 0
end

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
end

local function nil_if_missing(value)
    if missing(value) then
        return nil
    end
    return value
end

local function null_if_missing(value)
    if missing(value) then
        return null
    end
    return value
end

local function parse_json_text(text)
    if missing(text) then
        error("empty JSON payload")
    end
    text = tostring(text)
    local pos = 1

    local function peek()
        return string.sub(text, pos, pos)
    end

    local function skip_ws()
        while pos <= #text do
            local c = peek()
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                return
            end
        end
    end

    local function is_digit(c)
        return string.match(c, "^%d$") ~= nil
    end

    local function is_hex(c)
        return string.match(c, "^[0-9A-Fa-f]$") ~= nil
    end

    local function read_digits()
        local count = 0
        while is_digit(peek()) do
            count = count + 1
            pos = pos + 1
        end
        return count
    end

    local function parse_string()
        if peek() ~= '"' then
            error("expected string at byte " .. tostring(pos))
        end
        pos = pos + 1
        while pos <= #text do
            local c = peek()
            if c == '"' then
                pos = pos + 1
                return true
            elseif c == "\\" then
                local e = string.sub(text, pos + 1, pos + 1)
                if e == '"' or e == "\\" or e == "/" or e == "b" or e == "f"
                    or e == "n" or e == "r" or e == "t" then
                    pos = pos + 2
                elseif e == "u" then
                    for offset = 2, 5 do
                        if not is_hex(string.sub(text, pos + offset, pos + offset)) then
                            error("invalid unicode escape at byte " .. tostring(pos))
                        end
                    end
                    pos = pos + 6
                else
                    error("invalid escape at byte " .. tostring(pos))
                end
            elseif c == "" or string.byte(c) < 32 then
                error("invalid control character in string at byte " .. tostring(pos))
            else
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local parse_value

    local function parse_number()
        local start_pos = pos
        if peek() == "-" then
            pos = pos + 1
        end
        if peek() == "0" then
            pos = pos + 1
        elseif string.match(peek(), "^[1-9]$") then
            read_digits()
        else
            error("invalid number at byte " .. tostring(start_pos))
        end
        if peek() == "." then
            pos = pos + 1
            if read_digits() == 0 then
                error("invalid number fraction at byte " .. tostring(pos))
            end
        end
        local c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then
                pos = pos + 1
            end
            if read_digits() == 0 then
                error("invalid number exponent at byte " .. tostring(pos))
            end
        end
        return true
    end

    local function parse_array()
        pos = pos + 1
        skip_ws()
        if peek() == "]" then
            pos = pos + 1
            return true
        end
        while true do
            parse_value()
            skip_ws()
            local c = peek()
            if c == "]" then
                pos = pos + 1
                return true
            elseif c == "," then
                pos = pos + 1
            else
                error("expected array comma or close at byte " .. tostring(pos))
            end
        end
    end

    local function parse_object()
        pos = pos + 1
        skip_ws()
        if peek() == "}" then
            pos = pos + 1
            return true
        end
        while true do
            skip_ws()
            parse_string()
            skip_ws()
            if peek() ~= ":" then
                error("expected object colon at byte " .. tostring(pos))
            end
            pos = pos + 1
            parse_value()
            skip_ws()
            local c = peek()
            if c == "}" then
                pos = pos + 1
                return true
            elseif c == "," then
                pos = pos + 1
            else
                error("expected object comma or close at byte " .. tostring(pos))
            end
        end
    end

    function parse_value()
        skip_ws()
        local c = peek()
        if c == '"' then
            return parse_string()
        elseif c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == "-" or is_digit(c) then
            return parse_number()
        elseif string.sub(text, pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif string.sub(text, pos, pos + 4) == "false" then
            pos = pos + 5
            return true
        elseif string.sub(text, pos, pos + 3) == "null" then
            pos = pos + 4
            return true
        end
        error("unexpected JSON token at byte " .. tostring(pos))
    end

    parse_value()
    skip_ws()
    if pos <= #text then
        error("unexpected trailing JSON at byte " .. tostring(pos))
    end
    return true
end

local function valid_json_text(text)
    local ok, _ = pcall(parse_json_text, text)
    return ok
end

local function start_validation_run(ctx)
    query([[
        INSERT INTO SYS_SEMANTIC.VALIDATION_RUNS (
          MODEL_ID, VERSION_ID, MODEL_NAME, STATUS
        ) VALUES (
          :model_id, :version_id, :model_name, 'RUNNING'
        )
    ]], {
        model_id = null_if_missing(ctx.model_id),
        version_id = null_if_missing(ctx.version_id),
        model_name = null_if_missing(ctx.model_name),
    })

    ctx.validation_run_id = scalar([[
        SELECT MAX(VALIDATION_RUN_ID)
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE COALESCE(MODEL_NAME, '') = COALESCE(:model_name, '')
    ]], {model_name = null_if_missing(ctx.model_name)})
end

local function add_issue(ctx, severity, object_type, object_name, rule_code, message)
    local dedupe_key = table.concat({
        tostring(severity),
        tostring(object_type),
        tostring(object_name),
        tostring(rule_code),
        tostring(message),
    }, "|")
    if ctx.issue_seen[dedupe_key] then
        return
    end
    ctx.issue_seen[dedupe_key] = true

    local issue = {
        severity = severity,
        object_type = object_type,
        object_name = object_name,
        rule_code = rule_code,
        message = message,
    }
    table.insert(ctx.issues, issue)

    if severity == "ERROR" then
        ctx.error_count = ctx.error_count + 1
    elseif severity == "WARNING" then
        ctx.warning_count = ctx.warning_count + 1
    end

    if not missing(ctx.validation_run_id) then
        query([[
            INSERT INTO SYS_SEMANTIC.VALIDATION_RESULTS (
              VALIDATION_RUN_ID, MODEL_ID, VERSION_ID, SEVERITY, OBJECT_TYPE,
              OBJECT_NAME, RULE_CODE, MESSAGE
            ) VALUES (
              :validation_run_id, :model_id, :version_id, :severity, :object_type,
              :object_name, :rule_code, :message
            )
        ]], {
            validation_run_id = ctx.validation_run_id,
            model_id = null_if_missing(ctx.model_id),
            version_id = null_if_missing(ctx.version_id),
            severity = severity,
            object_type = object_type,
            object_name = null_if_missing(object_name),
            rule_code = rule_code,
            message = message,
        })
    end
end

local function finish_validation_run(ctx)
    if missing(ctx.validation_run_id) then
        return
    end
    local status = "OK"
    if ctx.error_count > 0 then
        status = "ERROR"
    elseif ctx.warning_count > 0 then
        status = "WARNING"
    end
    query([[
        UPDATE SYS_SEMANTIC.VALIDATION_RUNS
        SET STATUS = :status,
            FINISHED_AT = CURRENT_TIMESTAMP,
            ISSUE_COUNT = :issue_count,
            ERROR_COUNT = :error_count,
            WARNING_COUNT = :warning_count
        WHERE VALIDATION_RUN_ID = :validation_run_id
    ]], {
        status = status,
        issue_count = #ctx.issues,
        error_count = ctx.error_count,
        warning_count = ctx.warning_count,
        validation_run_id = ctx.validation_run_id,
    })
end

local function source_object_exists(schema_name, object_name)
    return count_query([[
        SELECT COUNT(*)
        FROM (
          SELECT TABLE_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_TABLES
          WHERE (TABLE_SCHEMA = :schema_name OR TABLE_SCHEMA = UPPER(:schema_name))
            AND (TABLE_NAME = :object_name OR TABLE_NAME = UPPER(:object_name))
          UNION ALL
          SELECT VIEW_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_VIEWS
          WHERE (VIEW_SCHEMA = :schema_name OR VIEW_SCHEMA = UPPER(:schema_name))
            AND (VIEW_NAME = :object_name OR VIEW_NAME = UPPER(:object_name))
        ) visible_objects
    ]], {schema_name = schema_name, object_name = object_name}) > 0
end

local function source_column_exists(schema_name, object_name, column_name)
    return count_query([[
        SELECT COUNT(*)
        FROM SYS.EXA_ALL_COLUMNS
        WHERE (COLUMN_SCHEMA = :schema_name OR COLUMN_SCHEMA = UPPER(:schema_name))
          AND (COLUMN_TABLE = :object_name OR COLUMN_TABLE = UPPER(:object_name))
          AND (COLUMN_NAME = :column_name OR COLUMN_NAME = UPPER(:column_name))
    ]], {schema_name = schema_name, object_name = object_name, column_name = column_name}) > 0
end

local function quote_ident(value)
    return '"' .. string.gsub(tostring(value), '"', '""') .. '"'
end

local function quote_qualified(schema_name, object_name)
    return quote_ident(schema_name) .. "." .. quote_ident(object_name)
end

local function replace_qualified_alias(expression, source_alias, target_alias)
    local source = upper(source_alias)
    local text = tostring(expression)
    local out = {}
    local i = 1
    local in_quote = false
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            out[#out + 1] = c
            if in_quote and n == "'" then
                out[#out + 1] = n
                i = i + 2
            else
                in_quote = not in_quote
                i = i + 1
            end
        elseif not in_quote and string.match(c, "[A-Za-z_]") then
            local j = i + 1
            while j <= #text and string.match(string.sub(text, j, j), "[A-Za-z0-9_]") do
                j = j + 1
            end
            local cursor = j
            while string.match(string.sub(text, cursor, cursor), "%s") do cursor = cursor + 1 end
            local token = string.sub(text, i, j - 1)
            if upper(token) == source and string.sub(text, cursor, cursor) == "." then
                out[#out + 1] = target_alias
            else
                out[#out + 1] = token
            end
            i = j
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function strip_string_literals(text)
    local out = {}
    local in_quote = false
    local i = 1
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            if in_quote and n == "'" then
                out[#out + 1] = " "
                out[#out + 1] = " "
                i = i + 2
            else
                in_quote = not in_quote
                out[#out + 1] = " "
                i = i + 1
            end
        elseif in_quote then
            out[#out + 1] = " "
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function qualified_column_refs(expression)
    local refs = {}
    if missing(expression) then
        return refs
    end
    local text = strip_string_literals(tostring(expression))
    local pos = 1
    while pos <= #text do
        local start_pos, alias_end, alias = string.find(
            text, "([A-Za-z_][A-Za-z0-9_]*)", pos)
        if start_pos == nil then break end
        local cursor = alias_end + 1
        while string.match(string.sub(text, cursor, cursor), "%s") do
            cursor = cursor + 1
        end
        if string.sub(text, cursor, cursor) ~= "." then
            pos = alias_end + 1
        else
            cursor = cursor + 1
            while string.match(string.sub(text, cursor, cursor), "%s") do
                cursor = cursor + 1
            end
            local column_name = nil
            local quoted = false
            if string.sub(text, cursor, cursor) == '"' then
                quoted = true
                cursor = cursor + 1
                local parts = {}
                while cursor <= #text do
                    local char = string.sub(text, cursor, cursor)
                    local next_char = string.sub(text, cursor + 1, cursor + 1)
                    if char == '"' and next_char == '"' then
                        parts[#parts + 1] = '"'
                        cursor = cursor + 2
                    elseif char == '"' then
                        cursor = cursor + 1
                        column_name = table.concat(parts)
                        break
                    else
                        parts[#parts + 1] = char
                        cursor = cursor + 1
                    end
                end
            else
                local column_start, column_end
                column_start, column_end, column_name = string.find(
                    text, "([A-Za-z_][A-Za-z0-9_]*)", cursor)
                if column_start ~= cursor then
                    column_name = nil
                elseif column_end ~= nil then
                    cursor = column_end + 1
                end
            end
            local after = cursor
            while string.match(string.sub(text, after, after), "%s") do
                after = after + 1
            end
            if column_name ~= nil and string.sub(text, after, after) ~= "(" then
                refs[#refs + 1] = {
                    alias = upper(alias),
                    column_name = quoted and column_name or upper(column_name),
                }
            end
            pos = math.max(cursor, alias_end + 1)
        end
    end
    return refs
end

local function aliases_in_expression(expression)
    local aliases = {}
    for _, ref in ipairs(qualified_column_refs(expression)) do
        aliases[ref.alias] = true
    end
    return aliases
end

local function column_refs_in_expression(expression)
    return qualified_column_refs(expression)
end

local function schema_qualified_functions(expression)
    local functions = {}
    if missing(expression) then
        return functions
    end
    local text = strip_string_literals(tostring(expression))
    for schema_name, function_name in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*([A-Za-z_][A-Za-z0-9_]*)%s*%(") do
        functions[upper(schema_name) .. "." .. upper(function_name)] = true
    end
    return functions
end

local function unsupported_functions(expression)
    local found = {}
    if missing(expression) then
        return found
    end
    local text = strip_string_literals(tostring(expression))
    local pos = 1
    while true do
        local start_pos, end_pos, fn = string.find(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%(", pos)
        if start_pos == nil then
            break
        end
        local normalized = upper(fn)
        local prefix = string.sub(text, 1, start_pos - 1)
        local schema_qualified = string.match(prefix, "[A-Za-z_][A-Za-z0-9_]*%s*%.%s*$") ~= nil
        local previous_word = string.match(prefix, "([A-Za-z_][A-Za-z0-9_]*)%s*$")
        local cast_target = CAST_TARGET_TYPES[normalized] and upper(previous_word or "") == "AS"
        if not schema_qualified and not cast_target and not ALLOWED_FUNCTIONS[normalized] then
            found[normalized] = true
        end
        pos = end_pos + 1
    end
    return found
end

local function dependency_tokens(expression)
    local tokens = {}
    if missing(expression) then
        return tokens
    end
    local text = strip_string_literals(tostring(expression))
    text = string.gsub(text, "[A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*", " ")
    for token in string.gmatch(text, "[A-Za-z_][A-Za-z0-9_]*") do
        local normalized = upper(token)
        if not SQL_WORDS[normalized] then
            tokens[normalized] = token
        end
    end
    return tokens
end

local function extract_json_array_values(json_text, key_name)
    local values = {}
    if missing(json_text) then
        return values
    end
    local text = tostring(json_text)
    local lower_text = string.lower(text)
    local pattern = '"' .. string.lower(key_name) .. '"%s*:%s*%[(.-)%]'
    local start_pos, end_pos = string.find(lower_text, pattern)
    if start_pos == nil then
        return values
    end
    local raw = string.sub(text, start_pos, end_pos)
    for value in string.gmatch(raw, '"([^"]+)"') do
        if string.lower(value) ~= string.lower(key_name) then
            table.insert(values, value)
        end
    end
    return values
end

local function load_model(ctx, model_name_arg)
    if missing(model_name_arg) then
        ctx.model_name = nil
        start_validation_run(ctx)
        add_issue(ctx, "ERROR", "MODEL", nil, "SEMANTIC_MODEL_000", "MODEL_NAME is required.")
        return false
    end
    ctx.model_name = trim(model_name_arg)
    local rows = query([[
        SELECT
          m.MODEL_ID,
          m.ACTIVE_VERSION_ID AS VERSION_ID,
          mv.VERSION_NUMBER
        FROM SYS_SEMANTIC.MODELS m
        LEFT JOIN SYS_SEMANTIC.MODEL_VERSIONS mv
          ON mv.VERSION_ID = m.ACTIVE_VERSION_ID
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = ctx.model_name})
    if rows == nil or #rows == 0 then
        start_validation_run(ctx)
        add_issue(ctx, "ERROR", "MODEL", ctx.model_name, "SEMANTIC_MODEL_000", "Model not found: " .. ctx.model_name .. ".")
        return false
    end

    ctx.model_id = row_value(rows[1], "MODEL_ID", 1)
    ctx.version_id = row_value(rows[1], "VERSION_ID", 2)
    start_validation_run(ctx)

    if missing(ctx.version_id) then
        add_issue(ctx, "ERROR", "MODEL", ctx.model_name, "SEMANTIC_MODEL_002", "Model has no active version.")
        return false
    end
    return true
end

local function load_catalog(ctx)
    ctx.entities = {}
    ctx.representations = {}
    ctx.representations_by_entity = {}
    ctx.entity_by_id = {}
    ctx.entity_alias_by_id = {}
    ctx.entity_name_by_id = {}
    ctx.entity_id_by_name = {}
    local entity_rows = query([[
        SELECT e.ENTITY_ID, e.ENTITY_NAME,
               er.SOURCE_SCHEMA, er.SOURCE_OBJECT, er.SOURCE_ALIAS,
               e.PRIMARY_KEY_EXPR, e.GRAIN_DESCRIPTION,
               er.REPRESENTATION_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.REPRESENTATION_ROLE, er.PRIORITY
        FROM SYS_SEMANTIC.ENTITIES e
        LEFT JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        ORDER BY e.ENTITY_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local id = row_value(row, "ENTITY_ID", 1)
        local entity = {
            id = id,
            name = row_value(row, "ENTITY_NAME", 2),
            source_schema = row_value(row, "SOURCE_SCHEMA", 3),
            source_object = row_value(row, "SOURCE_OBJECT", 4),
            alias = row_value(row, "SOURCE_ALIAS", 5),
            primary_key_expr = row_value(row, "PRIMARY_KEY_EXPR", 6),
            grain_description = row_value(row, "GRAIN_DESCRIPTION", 7),
            primary_representation = {
                id = row_value(row, "REPRESENTATION_ID", 8),
                entity_id = row_value(row, "ENTITY_ID", 1),
                name = row_value(row, "REPRESENTATION_NAME", 9),
                source_kind = row_value(row, "SOURCE_KIND", 10),
                role = row_value(row, "REPRESENTATION_ROLE", 11),
                priority = row_value(row, "PRIORITY", 12),
                source_schema = row_value(row, "SOURCE_SCHEMA", 3),
                source_object = row_value(row, "SOURCE_OBJECT", 4),
                alias = row_value(row, "SOURCE_ALIAS", 5),
            },
        }
        table.insert(ctx.entities, entity)
        ctx.entity_by_id[key(id)] = entity
        ctx.entity_alias_by_id[key(id)] = upper(entity.alias)
        ctx.entity_name_by_id[key(id)] = tostring(entity.name)
        ctx.entity_id_by_name[upper(entity.name)] = id
    end

    local representation_rows = query([[
        SELECT er.REPRESENTATION_ID, er.ENTITY_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.SOURCE_SCHEMA, er.SOURCE_OBJECT,
               er.SOURCE_ALIAS, er.REPRESENTATION_ROLE, er.PRIORITY,
               er.FRESHNESS_POLICY, er.COVERAGE_PREDICATE, er.VALID_FROM,
               er.VALID_TO, COALESCE(ra.AUTHORITY_ROLE, 'PREFER') AS AUTHORITY_ROLE
        FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
        LEFT JOIN SYS_SEMANTIC.REPRESENTATION_AUTHORITIES ra
          ON ra.MODEL_ID = er.MODEL_ID AND ra.VERSION_ID = er.VERSION_ID
         AND ra.REPRESENTATION_ID = er.REPRESENTATION_ID AND ra.STATUS = 'ACTIVE'
        WHERE er.MODEL_ID = :model_id
          AND er.VERSION_ID = :version_id
          AND er.STATUS = 'ACTIVE'
        ORDER BY er.ENTITY_ID,
          CASE WHEN er.REPRESENTATION_ROLE = 'PRIMARY' THEN 0 ELSE 1 END,
          er.PRIORITY, er.REPRESENTATION_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(representation_rows or {}) do
        local representation = {
            id = row_value(row, "REPRESENTATION_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "REPRESENTATION_NAME", 3),
            source_kind = row_value(row, "SOURCE_KIND", 4),
            source_schema = row_value(row, "SOURCE_SCHEMA", 5),
            source_object = row_value(row, "SOURCE_OBJECT", 6),
            alias = row_value(row, "SOURCE_ALIAS", 7),
            role = row_value(row, "REPRESENTATION_ROLE", 8),
            priority = row_value(row, "PRIORITY", 9),
            freshness_policy = row_value(row, "FRESHNESS_POLICY", 10),
            coverage_predicate = row_value(row, "COVERAGE_PREDICATE", 11),
            valid_from = row_value(row, "VALID_FROM", 12),
            valid_to = row_value(row, "VALID_TO", 13),
            authority_role = row_value(row, "AUTHORITY_ROLE", 14) or "PREFER",
        }
        table.insert(ctx.representations, representation)
        local entity_key = key(representation.entity_id)
        ctx.representations_by_entity[entity_key] =
            ctx.representations_by_entity[entity_key] or {}
        table.insert(ctx.representations_by_entity[entity_key], representation)
        if upper(representation.role) == "PRIMARY" and ctx.entity_by_id[entity_key] ~= nil then
            ctx.entity_by_id[entity_key].primary_representation = representation
        end
    end

    ctx.dimensions = {}
    ctx.dimension_by_id = {}
    ctx.dimension_by_name = {}
    local dimension_rows = query([[
        SELECT DIMENSION_ID, DIMENSION_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE,
               DESCRIPTION, UNIT_HINT, FORMAT_HINT, IS_HIDDEN, IS_CERTIFIED
        FROM SYS_SEMANTIC.DIMENSIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY DIMENSION_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(dimension_rows or {}) do
        local id = row_value(row, "DIMENSION_ID", 1)
        local dimension = {
            id = id,
            name = row_value(row, "DIMENSION_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            description = row_value(row, "DESCRIPTION", 6),
            unit_hint = row_value(row, "UNIT_HINT", 7),
            format_hint = row_value(row, "FORMAT_HINT", 8),
            is_hidden = row_value(row, "IS_HIDDEN", 9),
            is_certified = row_value(row, "IS_CERTIFIED", 10),
        }
        table.insert(ctx.dimensions, dimension)
        ctx.dimension_by_id[key(id)] = dimension
        ctx.dimension_by_name[upper(dimension.name)] = dimension
    end

    ctx.facts = {}
    ctx.fact_by_id = {}
    ctx.fact_by_name = {}
    local fact_rows = query([[
        SELECT FACT_ID, FACT_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE, DESCRIPTION,
               UNIT_HINT, FORMAT_HINT, IS_PRIVATE, IS_CERTIFIED
        FROM SYS_SEMANTIC.FACTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY FACT_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(fact_rows or {}) do
        local id = row_value(row, "FACT_ID", 1)
        local fact = {
            id = id,
            name = row_value(row, "FACT_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            description = row_value(row, "DESCRIPTION", 6),
            unit_hint = row_value(row, "UNIT_HINT", 7),
            format_hint = row_value(row, "FORMAT_HINT", 8),
            is_private = row_value(row, "IS_PRIVATE", 9),
            is_certified = row_value(row, "IS_CERTIFIED", 10),
        }
        table.insert(ctx.facts, fact)
        ctx.fact_by_id[key(id)] = fact
        ctx.fact_by_name[upper(fact.name)] = fact
    end

    ctx.attribute_bindings = {}
    ctx.bindings_by_attribute = {}
    local binding_rows = query([[
        SELECT ATTRIBUTE_BINDING_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
               REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
               BINDING_PRIORITY, IS_DEFAULT
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_ID,
          CASE WHEN BINDING_ROLE = 'PREFER' THEN 0 ELSE 1 END,
          BINDING_PRIORITY, ATTRIBUTE_BINDING_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(binding_rows or {}) do
        local binding = {
            id = row_value(row, "ATTRIBUTE_BINDING_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 3),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 4),
            representation_id = row_value(row, "REPRESENTATION_ID", 5),
            expression = row_value(row, "SOURCE_EXPRESSION", 6),
            role = row_value(row, "BINDING_ROLE", 7),
            priority = row_value(row, "BINDING_PRIORITY", 8),
            is_default = row_value(row, "IS_DEFAULT", 9),
        }
        table.insert(ctx.attribute_bindings, binding)
        local attribute_key = upper(binding.attribute_type) .. ":" .. key(binding.attribute_id)
        ctx.bindings_by_attribute[attribute_key] =
            ctx.bindings_by_attribute[attribute_key] or {}
        table.insert(ctx.bindings_by_attribute[attribute_key], binding)
    end

    ctx.attribute_fusion_policies = {}
    ctx.fusion_policy_by_attribute = {}
    local fusion_policy_rows = query([[
        SELECT ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID, FUSION_STRATEGY
        FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(fusion_policy_rows or {}) do
        local policy = {
            entity_id = row_value(row, "ENTITY_ID", 1),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 2),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 3),
            strategy = row_value(row, "FUSION_STRATEGY", 4),
        }
        local attribute_key = upper(policy.attribute_type) .. ":" .. key(policy.attribute_id)
        ctx.attribute_fusion_policies[#ctx.attribute_fusion_policies + 1] = policy
        ctx.fusion_policy_by_attribute[attribute_key] = policy
    end

    ctx.semantic_identities = {}
    ctx.identity_by_id = {}
    ctx.identities_by_entity = {}
    local identity_rows = query([[
        SELECT IDENTITY_ID, ENTITY_ID, IDENTITY_NAME, IDENTITY_KIND, DATA_TYPE
        FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID, IDENTITY_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(identity_rows or {}) do
        local identity = {id = row_value(row, "IDENTITY_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "IDENTITY_NAME", 3),
            kind = row_value(row, "IDENTITY_KIND", 4),
            data_type = row_value(row, "DATA_TYPE", 5), bindings = {}}
        ctx.semantic_identities[#ctx.semantic_identities + 1] = identity
        ctx.identity_by_id[key(identity.id)] = identity
        ctx.identities_by_entity[key(identity.entity_id)] =
            ctx.identities_by_entity[key(identity.entity_id)] or {}
        table.insert(ctx.identities_by_entity[key(identity.entity_id)], identity)
    end
    ctx.identity_bindings = {}
    local identity_binding_rows = query([[
        SELECT ib.IDENTITY_BINDING_ID, ib.ENTITY_ID, ib.IDENTITY_ID,
               ib.REPRESENTATION_ID, ib.SOURCE_EXPRESSION, ib.BINDING_KIND,
               im.IDENTITY_MAPPING_ID, im.SOURCE_SCHEMA, im.SOURCE_OBJECT,
               im.SOURCE_LOCAL_COLUMN, im.SEMANTIC_KEY_COLUMN,
               im.CERTIFICATION_STATUS
        FROM SYS_SEMANTIC.IDENTITY_BINDINGS ib
        LEFT JOIN SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS im
          ON im.IDENTITY_BINDING_ID = ib.IDENTITY_BINDING_ID
         AND im.STATUS = 'ACTIVE'
        WHERE ib.MODEL_ID = :model_id AND ib.VERSION_ID = :version_id
          AND ib.STATUS = 'ACTIVE'
        ORDER BY ib.IDENTITY_ID, ib.IDENTITY_BINDING_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(identity_binding_rows or {}) do
        local binding = {id = row_value(row, "IDENTITY_BINDING_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            identity_id = row_value(row, "IDENTITY_ID", 3),
            representation_id = row_value(row, "REPRESENTATION_ID", 4),
            expression = row_value(row, "SOURCE_EXPRESSION", 5),
            kind = row_value(row, "BINDING_KIND", 6),
            mapping = not missing(row_value(row, "IDENTITY_MAPPING_ID", 7)) and {
                id = row_value(row, "IDENTITY_MAPPING_ID", 7),
                source_schema = row_value(row, "SOURCE_SCHEMA", 8),
                source_object = row_value(row, "SOURCE_OBJECT", 9),
                local_column = row_value(row, "SOURCE_LOCAL_COLUMN", 10),
                semantic_column = row_value(row, "SEMANTIC_KEY_COLUMN", 11),
                certification = row_value(row, "CERTIFICATION_STATUS", 12),
            } or nil}
        ctx.identity_bindings[#ctx.identity_bindings + 1] = binding
        local identity = ctx.identity_by_id[key(binding.identity_id)]
        if identity ~= nil then
            identity.bindings[#identity.bindings + 1] = binding
            identity.binding_by_representation = identity.binding_by_representation or {}
            identity.binding_by_representation[key(binding.representation_id)] = binding
        end
    end

    ctx.metrics = {}
    ctx.metric_by_id = {}
    ctx.metric_by_name = {}
    local metric_rows = query([[
        SELECT METRIC_ID, METRIC_NAME, BASE_ENTITY_ID, EXPRESSION, FILTER_EXPR,
               METRIC_TYPE, DATA_TYPE, DESCRIPTION, UNIT_HINT, FORMAT_HINT,
               IS_PRIVATE, IS_CERTIFIED
        FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY METRIC_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(metric_rows or {}) do
        local id = row_value(row, "METRIC_ID", 1)
        local metric = {
            id = id,
            name = row_value(row, "METRIC_NAME", 2),
            base_entity_id = row_value(row, "BASE_ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            filter_expr = row_value(row, "FILTER_EXPR", 5),
            metric_type = row_value(row, "METRIC_TYPE", 6),
            data_type = row_value(row, "DATA_TYPE", 7),
            description = row_value(row, "DESCRIPTION", 8),
            unit_hint = row_value(row, "UNIT_HINT", 9),
            format_hint = row_value(row, "FORMAT_HINT", 10),
            is_private = row_value(row, "IS_PRIVATE", 11),
            is_certified = row_value(row, "IS_CERTIFIED", 12),
        }
        table.insert(ctx.metrics, metric)
        ctx.metric_by_id[key(id)] = metric
        ctx.metric_by_name[upper(metric.name)] = metric
    end

    ctx.relationships = {}
    ctx.relationship_by_id = {}
    local relationship_rows = query([[
        SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
               JOIN_CONDITION, RELATIONSHIP_CARDINALITY, JOIN_TYPE, FANOUT_POLICY,
               PATH_PRIORITY
        FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY RELATIONSHIP_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(relationship_rows or {}) do
        local id = row_value(row, "RELATIONSHIP_ID", 1)
        local relationship = {
            id = id,
            name = row_value(row, "RELATIONSHIP_NAME", 2),
            from_entity_id = row_value(row, "FROM_ENTITY_ID", 3),
            to_entity_id = row_value(row, "TO_ENTITY_ID", 4),
            join_condition = row_value(row, "JOIN_CONDITION", 5),
            cardinality = row_value(row, "RELATIONSHIP_CARDINALITY", 6),
            join_type = row_value(row, "JOIN_TYPE", 7),
            fanout_policy = row_value(row, "FANOUT_POLICY", 8),
            path_priority = row_value(row, "PATH_PRIORITY", 9),
            key_mappings = {},
        }
        table.insert(ctx.relationships, relationship)
        ctx.relationship_by_id[key(id)] = relationship
    end

    local mapping_rows = query([[
        SELECT rkm.RELATIONSHIP_ID, rkm.ORDINAL_POSITION,
               rkm.FROM_COLUMN_NAME, rkm.FROM_EXPRESSION,
               rkm.TO_COLUMN_NAME, rkm.TO_EXPRESSION
        FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS rkm
        JOIN SYS_SEMANTIC.RELATIONSHIPS r
          ON r.RELATIONSHIP_ID = rkm.RELATIONSHIP_ID
        WHERE r.MODEL_ID = :model_id
          AND r.VERSION_ID = :version_id
          AND r.STATUS = 'ACTIVE'
        ORDER BY rkm.RELATIONSHIP_ID, rkm.ORDINAL_POSITION
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(mapping_rows or {}) do
        local relationship = ctx.relationship_by_id[key(row_value(row, "RELATIONSHIP_ID", 1))]
        if relationship ~= nil then
            relationship.key_mappings[#relationship.key_mappings + 1] = {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                from_column_name = row_value(row, "FROM_COLUMN_NAME", 3),
                from_expression = row_value(row, "FROM_EXPRESSION", 4),
                to_column_name = row_value(row, "TO_COLUMN_NAME", 5),
                to_expression = row_value(row, "TO_EXPRESSION", 6),
            }
        end
    end

    -- Semantic objects with root entity IDs - needed to validate that a metric
    -- base entity is reachable from the join-root when computing the valid-combinations matrix.
    ctx.semantic_objects = {}
    ctx.semantic_object_by_id = {}
    local object_rows = query([[
        SELECT OBJECT_ID, OBJECT_NAME, ROOT_ENTITY_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(object_rows or {}) do
        local id = row_value(row, "OBJECT_ID", 1)
        local object = {
            object_id = id,
            name = row_value(row, "OBJECT_NAME", 2),
            root_entity_id = row_value(row, "ROOT_ENTITY_ID", 3),
        }
        table.insert(ctx.semantic_objects, object)
        ctx.semantic_object_by_id[key(id)] = object
    end

    ctx.unique_keys = {}
    ctx.unique_key_by_id = {}
    local unique_key_rows = query([[
        SELECT UNIQUE_KEY_ID, ENTITY_ID, KEY_NAME, KEY_KIND, SOURCE_FORMAT
        FROM SYS_SEMANTIC.UNIQUE_KEYS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY UNIQUE_KEY_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(unique_key_rows or {}) do
        local id = row_value(row, "UNIQUE_KEY_ID", 1)
        local unique_key = {
            id = id,
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "KEY_NAME", 3),
            kind = row_value(row, "KEY_KIND", 4),
            source_format = row_value(row, "SOURCE_FORMAT", 5),
            columns = {},
        }
        table.insert(ctx.unique_keys, unique_key)
        ctx.unique_key_by_id[key(id)] = unique_key
    end

    local unique_key_column_rows = query([[
        SELECT ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION, ukc.COLUMN_NAME, ukc.EXPRESSION
        FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS ukc
        JOIN SYS_SEMANTIC.UNIQUE_KEYS uk
          ON uk.UNIQUE_KEY_ID = ukc.UNIQUE_KEY_ID
        WHERE uk.MODEL_ID = :model_id
          AND uk.VERSION_ID = :version_id
          AND uk.STATUS = 'ACTIVE'
        ORDER BY ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(unique_key_column_rows or {}) do
        local unique_key = ctx.unique_key_by_id[key(row_value(row, "UNIQUE_KEY_ID", 1))]
        if unique_key ~= nil then
            table.insert(unique_key.columns, {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                column_name = row_value(row, "COLUMN_NAME", 3),
                expression = row_value(row, "EXPRESSION", 4),
            })
        end
    end
    ctx.unique_keys_by_entity = {}
    for _, unique_key in ipairs(ctx.unique_keys) do
        local canonical = grain_graph.canonical_key(unique_key)
        unique_key.columns = canonical.columns
        unique_key.kind = canonical.kind
        local entity_key = key(unique_key.entity_id)
        ctx.unique_keys_by_entity[entity_key] = ctx.unique_keys_by_entity[entity_key] or {}
        ctx.unique_keys_by_entity[entity_key][#ctx.unique_keys_by_entity[entity_key] + 1] = unique_key
    end

    ctx.custom_extensions = {}
    local extension_rows = query([[
        SELECT CUSTOM_EXTENSION_ID, SCOPE_TYPE, SCOPE_ID, VENDOR_NAME,
               EXTENSION_NAME, SOURCE_FORMAT, DATA_JSON
        FROM SYS_SEMANTIC.CUSTOM_EXTENSIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
        ORDER BY CUSTOM_EXTENSION_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(extension_rows or {}) do
        table.insert(ctx.custom_extensions, {
            id = row_value(row, "CUSTOM_EXTENSION_ID", 1),
            scope_type = row_value(row, "SCOPE_TYPE", 2),
            scope_id = row_value(row, "SCOPE_ID", 3),
            vendor_name = row_value(row, "VENDOR_NAME", 4),
            extension_name = row_value(row, "EXTENSION_NAME", 5),
            source_format = row_value(row, "SOURCE_FORMAT", 6),
            data_json = row_value(row, "DATA_JSON", 7),
        })
    end
end

local function representations_for_entity(ctx, entity)
    if entity == nil then return {} end
    local representations = (ctx.representations_by_entity or {})[key(entity.id)] or {}
    if #representations == 0 and not missing(entity.source_schema)
        and not missing(entity.source_object) then
        return {{
            id = entity.primary_representation and entity.primary_representation.id or nil,
            entity_id = entity.id,
            name = entity.primary_representation and entity.primary_representation.name or "primary",
            source_kind = "RELATION",
            source_schema = entity.source_schema,
            source_object = entity.source_object,
            alias = entity.alias,
            role = "PRIMARY",
            priority = 1,
        }}
    end
    return representations
end

local function entity_uses_partition_fusion(ctx, entity)
    local representations = representations_for_entity(ctx, entity)
    if #representations < 2 then return false end
    for _, representation in ipairs(representations) do
        if missing(representation.coverage_predicate) then return false end
    end
    return true
end

local function trim_text(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalized_timestamp(value)
    if missing(value) then return nil end
    local text = trim_text(value):gsub("T", " ")
    local date, time, fraction = text:match(
        "^(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d:%d%d)(%.%d+)$")
    if date == nil then
        date, time = text:match("^(%d%d%d%d%-%d%d%-%d%d) (%d%d:%d%d:%d%d)$")
    end
    if date == nil then return nil end
    fraction = (fraction or ""):gsub("0+$", ""):gsub("%.$", "")
    return date .. " " .. time .. fraction
end

local function comparable_timestamp(value)
    return normalized_timestamp(value) or tostring(value or "")
end

local function partition_key_expression(value)
    local compact = trim_text(value):gsub("%s+", "")
    while compact:match("^%b()$") do compact = compact:sub(2, -2) end
    local alias, column = compact:match("^([%a_][%w_]*)%.([%a_][%w_]*)$")
    if alias == nil then
        alias, column = compact:match('^([%a_][%w_]*)%."([^"]+)"$')
    end
    if alias == nil then return nil end
    return upper(alias) .. "." .. tostring(column)
end

local function parse_partition_bound(clause)
    local expression, literal = trim_text(clause):match(
        "^(.-)%s*>=%s*[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]%s*'([^']+)'%s*$")
    local operator = ">="
    if expression == nil then
        expression, literal = trim_text(clause):match(
            "^(.-)%s*<%s*[Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]%s*'([^']+)'%s*$")
        operator = "<"
    end
    local key_expression = partition_key_expression(expression)
    local timestamp = normalized_timestamp(literal)
    if key_expression == nil or timestamp == nil then return nil end
    return {key_expression = key_expression, operator = operator, timestamp = timestamp}
end

local function parse_partition_predicate(predicate)
    local text = trim_text(predicate)
    while text:match("^%b()$") do text = trim_text(text:sub(2, -2)) end
    local upper_text = upper(text)
    local and_start, and_end = upper_text:find("%s+AND%s+")
    if and_start == nil then
        local bound = parse_partition_bound(text)
        return bound and {bound} or nil
    end
    if upper_text:find("%s+AND%s+", and_end + 1) ~= nil then return nil end
    local first = parse_partition_bound(text:sub(1, and_start - 1))
    local second = parse_partition_bound(text:sub(and_end + 1))
    if first == nil or second == nil
        or first.key_expression ~= second.key_expression then return nil end
    return {first, second}
end

local function predicate_matches_partition_interval(representation)
    local bounds = parse_partition_predicate(representation.coverage_predicate)
    if bounds == nil then return false, nil end
    local expected_from = normalized_timestamp(representation.valid_from)
    local expected_to = normalized_timestamp(representation.valid_to)
    local actual_from, actual_to, key_expression
    for _, bound in ipairs(bounds) do
        key_expression = key_expression or bound.key_expression
        if bound.key_expression ~= key_expression then return false, nil end
        if bound.operator == ">=" then
            if actual_from ~= nil then return false, nil end
            actual_from = bound.timestamp
        elseif bound.operator == "<" then
            if actual_to ~= nil then return false, nil end
            actual_to = bound.timestamp
        end
    end
    return actual_from == expected_from and actual_to == expected_to, key_expression
end

local function entity_has_base_metric(ctx, entity)
    for _, metric in ipairs(ctx.metrics or {}) do
        if key(metric.base_entity_id) == key(entity.id) then return true end
    end
    return false
end

local function validate_partition_coverage(ctx, entity)
    local representations = representations_for_entity(ctx, entity)
    local metadata_count = 0
    for _, representation in ipairs(representations) do
        if not missing(representation.coverage_predicate)
            or not missing(representation.valid_from)
            or not missing(representation.valid_to) then
            metadata_count = metadata_count + 1
        end
    end
    if metadata_count == 0 then return end

    local entity_name = tostring(entity.name)
    if #representations < 2 or metadata_count ~= #representations then
        add_issue(ctx, "ERROR", "ENTITY", entity_name, "SEMANTIC_MODEL_042",
            "UNION fusion requires coverage metadata on every active representation.")
        return
    end
    -- Admin authoring scripts validate after each mutation. An empty model must
    -- be able to add its first metric and satisfy this rule in that operation.
    if #(ctx.metrics or {}) > 0 and not entity_has_base_metric(ctx, entity) then
        add_issue(ctx, "ERROR", "ENTITY", entity_name, "SEMANTIC_MODEL_043",
            "Partitioned entity '" .. entity_name
                .. "' is the base entity of no active metric. F3 UNION fusion applies only "
                .. "to metric-leaf entities; partitioned joined dimensions are unsupported. "
                .. "Remove the coverage declarations or define a metric based on this entity.")
    end

    local ordered = {}
    for _, representation in ipairs(representations) do
        local object_name = entity_name .. "." .. tostring(representation.name)
        if missing(representation.coverage_predicate) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "UNION partition requires a coverage predicate.")
        end
        if missing(representation.valid_from) and missing(representation.valid_to) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "UNION partition requires VALID_FROM or VALID_TO.")
        end
        if not missing(representation.valid_from)
            and not missing(representation.valid_to)
            and comparable_timestamp(representation.valid_from)
                >= comparable_timestamp(representation.valid_to) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "VALID_FROM must be earlier than VALID_TO.")
        end
        local predicate = tostring(representation.coverage_predicate or "")
        local predicate_matches, partition_key =
            predicate_matches_partition_interval(representation)
        if not predicate_matches then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042",
                "Coverage predicate must be canonical half-open SQL over one qualified column: "
                    .. ">= VALID_FROM and < VALID_TO, omitting comparisons for NULL bounds. "
                    .. "Predicate timestamp literals must exactly match the declared interval.")
        elseif partition_key == nil then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "Coverage predicate has no certifiable partition key.")
        end
        for alias, _ in pairs(aliases_in_expression(predicate)) do
            if alias ~= upper(representation.alias) then
                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                    "SEMANTIC_MODEL_042", "Coverage predicate references alias outside its representation: "
                        .. tostring(alias) .. ".")
            end
        end
        for function_name, _ in pairs(unsupported_functions(predicate)) do
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_042", "Coverage predicate uses unsupported function: "
                    .. tostring(function_name) .. ".")
        end
        for _, ref in ipairs(column_refs_in_expression(predicate)) do
            if ref.alias == upper(representation.alias)
                and not source_column_exists(representation.source_schema,
                    representation.source_object, ref.column_name) then
                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                    "SEMANTIC_MODEL_042", "Coverage predicate references unknown source column: "
                        .. tostring(ref.column_name) .. ".")
            end
        end
        ordered[#ordered + 1] = representation
    end
    table.sort(ordered, function(left, right)
        if missing(left.valid_from) ~= missing(right.valid_from) then
            return missing(left.valid_from)
        end
        return comparable_timestamp(left.valid_from)
            < comparable_timestamp(right.valid_from)
    end)
    if not missing(ordered[1].valid_from)
        or not missing(ordered[#ordered].valid_to) then
        add_issue(ctx, "ERROR", "ENTITY", entity_name, "SEMANTIC_MODEL_042",
            "UNION coverage must be open-ended before the first and after the last partition.")
    end
    for index = 2, #ordered do
        local previous = ordered[index - 1]
        local current = ordered[index]
        if missing(previous.valid_to) or missing(current.valid_from)
            or comparable_timestamp(previous.valid_to)
                ~= comparable_timestamp(current.valid_from) then
            add_issue(ctx, "ERROR", "ENTITY", entity_name, "SEMANTIC_MODEL_042",
                "UNION partition intervals must be contiguous and non-overlapping; boundary mismatch between "
                    .. tostring(previous.name) .. " and " .. tostring(current.name) .. ".")
        end
    end
end

local function missing_representation_columns(ctx, entity, column_name)
    local names = {}
    for _, representation in ipairs(representations_for_entity(ctx, entity)) do
        if not source_column_exists(representation.source_schema,
            representation.source_object, column_name) then
            names[#names + 1] = tostring(representation.name)
        end
    end
    table.sort(names)
    return names
end

local function complete_semantic_identity(ctx, entity)
    local representations = representations_for_entity(ctx, entity)
    for _, identity in ipairs((ctx.identities_by_entity or {})[key(entity.id)] or {}) do
        local complete = #representations > 0
        for _, representation in ipairs(representations) do
            local binding = identity.binding_by_representation
                and identity.binding_by_representation[key(representation.id)] or nil
            if binding == nil or (upper(binding.kind) == "MAPPED"
                and (binding.mapping == nil
                    or upper(binding.mapping.certification) ~= "CERTIFIED")) then
                complete = false
                break
            end
        end
        if complete then return identity end
    end
    return nil
end

local function missing_unique_key_columns(ctx, entity, column_name)
    local identity = complete_semantic_identity(ctx, entity)
    if identity == nil then
        return missing_representation_columns(ctx, entity, column_name)
    end
    local primary = entity.primary_representation
    if primary ~= nil and not source_column_exists(primary.source_schema,
        primary.source_object, column_name) then
        return {tostring(primary.name)}
    end
    return {}
end

local function representation_suffix(names)
    if names == nil or #names == 0 then return "" end
    return " in representation(s): " .. table.concat(names, ", ")
end

local function identity_binding_remedy()
    return " F2 attribute bindings do not remap identity or joins. Use a certified F5 semantic identity for representation-local entity keys; relationship join columns still require canonical source views."
end

local function validate_structural_rules(ctx)
    local invalid_representation_rows = query([[
        SELECT e.ENTITY_NAME, COUNT(er.REPRESENTATION_ID) AS PRIMARY_COUNT
        FROM SYS_SEMANTIC.ENTITIES e
        LEFT JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        GROUP BY e.ENTITY_ID, e.ENTITY_NAME
        HAVING COUNT(er.REPRESENTATION_ID) <> 1
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(invalid_representation_rows or {}) do
        add_issue(ctx, "ERROR", "ENTITY", row_value(row, "ENTITY_NAME", 1),
            "SEMANTIC_MODEL_035",
            "Entity must have exactly one active PRIMARY representation; found "
                .. tostring(row_value(row, "PRIMARY_COUNT", 2)) .. ".")
    end
    local representation_names = {}
    for _, representation in ipairs(ctx.representations or {}) do
        local entity = ctx.entity_by_id[key(representation.entity_id)]
        local entity_name = entity and entity.name or tostring(representation.entity_id)
        local object_name = entity_name .. "." .. tostring(representation.name)
        local entity_key = key(representation.entity_id)
        representation_names[entity_key] = representation_names[entity_key] or {}
        local name_key = upper(representation.name)
        if representation_names[entity_key][name_key] then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Representation name is not unique within the entity.")
        end
        representation_names[entity_key][name_key] = true
        if entity == nil then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Representation references a missing entity.")
        elseif upper(representation.alias) ~= upper(entity.alias) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "F1 representations must use the entity's stable source alias: "
                    .. tostring(entity.alias) .. ".")
        end
        local source_kind = upper(representation.source_kind)
        if source_kind ~= "RELATION" and source_kind ~= "VIRTUAL_SCHEMA" then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Unsupported F1 source kind: "
                    .. tostring(representation.source_kind) .. ".")
        end
        local role = upper(representation.role)
        if role ~= "PRIMARY" and role ~= "ALTERNATE" then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Unsupported F1 representation role: "
                    .. tostring(representation.role) .. ".")
        end
        local priority = tonumber(representation.priority)
        if priority == nil or priority < 1 or priority % 1 ~= 0 then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_036", "Representation priority must be a positive integer.")
        end
        if not source_object_exists(representation.source_schema,
            representation.source_object) then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", object_name,
                "SEMANTIC_MODEL_001", "Source object is not visible: "
                    .. tostring(representation.source_schema) .. "."
                    .. tostring(representation.source_object) .. ".")
        end
    end
    for _, entity in ipairs(ctx.entities) do validate_partition_coverage(ctx, entity) end
    for _, entity in ipairs(ctx.entities) do
        if not missing(entity.primary_key_expr) then
            local owning_alias = upper(entity.alias)
            for alias, _ in pairs(aliases_in_expression(entity.primary_key_expr)) do
                if alias ~= owning_alias then
                    add_issue(ctx, "ERROR", "ENTITY", entity.name,
                        "SEMANTIC_MODEL_036", "Legacy primary-key expression references alias outside the entity: "
                            .. tostring(alias) .. ".")
                end
            end
            for _, ref in ipairs(column_refs_in_expression(entity.primary_key_expr)) do
                local missing_representations =
                    missing_unique_key_columns(ctx, entity, ref.column_name)
                if ref.alias == owning_alias and #missing_representations > 0 then
                    add_issue(ctx, "ERROR", "ENTITY", entity.name,
                        "SEMANTIC_MODEL_036", "Legacy primary-key expression references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name
                            .. representation_suffix(missing_representations) .. "."
                            .. identity_binding_remedy())
                end
            end
        end
    end

    local duplicate_alias_rows = query([[
        SELECT UPPER(er.SOURCE_ALIAS) AS SOURCE_ALIAS, COUNT(*) AS ALIAS_COUNT
        FROM SYS_SEMANTIC.ENTITIES e
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        GROUP BY UPPER(er.SOURCE_ALIAS)
        HAVING COUNT(*) > 1
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(duplicate_alias_rows or {}) do
        add_issue(ctx, "ERROR", "ENTITY", row_value(row, "SOURCE_ALIAS", 1), "SEMANTIC_MODEL_003",
            "Entity alias is not unique within the model version.")
    end

    local reserved_alias_rows = query([[
        SELECT e.ENTITY_NAME, er.SOURCE_ALIAS
        FROM SYS_SEMANTIC.ENTITIES e
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        JOIN SYS.EXA_SQL_KEYWORDS k
          ON UPPER(k.KEYWORD) = UPPER(er.SOURCE_ALIAS)
         AND k.RESERVED = TRUE
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(reserved_alias_rows or {}) do
        local alias = row_value(row, "SOURCE_ALIAS", 2)
        add_issue(ctx, "ERROR", "ENTITY", row_value(row, "ENTITY_NAME", 1), "SEMANTIC_MODEL_034",
            "Entity alias '" .. tostring(alias) .. "' is an Exasol reserved word; choose another alias.")
    end

    local missing_roots = query([[
        SELECT so.OBJECT_NAME
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so
        LEFT JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = so.ROOT_ENTITY_ID
         AND e.MODEL_ID = so.MODEL_ID
         AND e.VERSION_ID = so.VERSION_ID
        WHERE so.MODEL_ID = :model_id
          AND so.VERSION_ID = :version_id
          AND so.STATUS = 'ACTIVE'
          AND e.ENTITY_ID IS NULL
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(missing_roots or {}) do
        add_issue(ctx, "ERROR", "SEMANTIC_OBJECT", row_value(row, "OBJECT_NAME", 1), "SEMANTIC_MODEL_004",
            "Semantic object root entity does not exist in this model version.")
    end

    local invalid_columns = query([[
        SELECT so.OBJECT_NAME, oc.COLUMN_KIND, oc.COLUMN_NAME
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON so.OBJECT_ID = oc.OBJECT_ID
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON oc.COLUMN_KIND = 'DIMENSION'
         AND d.DIMENSION_ID = oc.OBJECT_REF_ID
         AND d.MODEL_ID = so.MODEL_ID
         AND d.VERSION_ID = so.VERSION_ID
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON oc.COLUMN_KIND = 'FACT'
         AND f.FACT_ID = oc.OBJECT_REF_ID
         AND f.MODEL_ID = so.MODEL_ID
         AND f.VERSION_ID = so.VERSION_ID
        LEFT JOIN SYS_SEMANTIC.METRICS mt
          ON oc.COLUMN_KIND = 'METRIC'
         AND mt.METRIC_ID = oc.OBJECT_REF_ID
         AND mt.MODEL_ID = so.MODEL_ID
         AND mt.VERSION_ID = so.VERSION_ID
        WHERE so.MODEL_ID = :model_id
          AND so.VERSION_ID = :version_id
          AND (
            oc.COLUMN_KIND NOT IN ('DIMENSION', 'FACT', 'METRIC')
            OR (oc.COLUMN_KIND = 'DIMENSION' AND d.DIMENSION_ID IS NULL)
            OR (oc.COLUMN_KIND = 'FACT' AND f.FACT_ID IS NULL)
            OR (oc.COLUMN_KIND = 'METRIC' AND mt.METRIC_ID IS NULL)
          )
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(invalid_columns or {}) do
        add_issue(ctx, "ERROR", "OBJECT_COLUMN", row_value(row, "OBJECT_NAME", 1) .. "." .. row_value(row, "COLUMN_NAME", 3),
            "SEMANTIC_MODEL_005", "Semantic object column references a missing or unsupported catalog object.")
    end
end

local function custom_extension_scope_exists(ctx, scope_type, scope_id)
    if missing(scope_type) or missing(scope_id) then
        return false
    end
    if scope_type == "MODEL" then
        return key(scope_id) == key(ctx.model_id)
    elseif scope_type == "SEMANTIC_OBJECT" then
        return ctx.semantic_object_by_id[key(scope_id)] ~= nil
    elseif scope_type == "ENTITY" then
        return ctx.entity_by_id[key(scope_id)] ~= nil
    elseif scope_type == "RELATIONSHIP" then
        return ctx.relationship_by_id[key(scope_id)] ~= nil
    elseif scope_type == "DIMENSION" then
        return ctx.dimension_by_id[key(scope_id)] ~= nil
    elseif scope_type == "FACT" then
        return ctx.fact_by_id[key(scope_id)] ~= nil
    elseif scope_type == "METRIC" then
        return ctx.metric_by_id[key(scope_id)] ~= nil
    end
    return false
end

local function extension_object_name(extension)
    return tostring(extension.vendor_name)
        .. "."
        .. tostring(extension.extension_name)
        .. "#"
        .. tostring(extension.id)
end

local function validate_custom_extensions(ctx)
    for _, extension in ipairs(ctx.custom_extensions) do
        local scope_type = upper(extension.scope_type)
        local object_name = extension_object_name(extension)
        if not VALID_EXTENSION_SCOPE_TYPES[scope_type] then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_026",
                "Custom extension has unsupported scope type: " .. tostring(extension.scope_type) .. ".")
        elseif not custom_extension_scope_exists(ctx, scope_type, extension.scope_id) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_026",
                "Custom extension scope does not exist in this model version: "
                .. scope_type .. "#" .. tostring(extension.scope_id) .. ".")
        end

        if missing(extension.vendor_name) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_027",
                "Custom extension vendor_name is required.")
        end
        if missing(extension.extension_name) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_027",
                "Custom extension extension_name is required.")
        end
        if missing(extension.source_format) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_027",
                "Custom extension source_format is required.")
        end
        if not valid_json_text(extension.data_json) then
            add_issue(ctx, "ERROR", "CUSTOM_EXTENSION", object_name, "SEMANTIC_MODEL_027",
                "Custom extension DATA_JSON must be valid JSON.")
        end
    end
end

local function unique_key_object_name(ctx, unique_key)
    local entity_name = ctx.entity_name_by_id[key(unique_key.entity_id)] or tostring(unique_key.entity_id)
    return entity_name .. "." .. tostring(unique_key.name)
end

local function validate_unique_key_expression(ctx, unique_key, column, entity, owning_alias, object_name)
    for alias, _ in pairs(aliases_in_expression(column.expression)) do
        if alias ~= owning_alias then
            add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", object_name, "SEMANTIC_MODEL_029",
                "Unique key expression references alias outside the owning entity: " .. alias .. ".")
        end
    end
    for fn, _ in pairs(unsupported_functions(column.expression)) do
        add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", object_name, "SEMANTIC_MODEL_029",
            "Unique key expression uses unsupported function: " .. fn .. ".")
    end
    for _, ref in ipairs(column_refs_in_expression(column.expression)) do
        local missing_representations = missing_unique_key_columns(ctx, entity, ref.column_name)
        if ref.alias == owning_alias and #missing_representations > 0 then
            add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", object_name, "SEMANTIC_MODEL_029",
            "Unique key expression references unknown source column: " .. ref.alias .. "."
                    .. ref.column_name .. representation_suffix(missing_representations) .. "."
                    .. identity_binding_remedy())
        end
    end
end

local function validate_unique_keys(ctx)
    for _, unique_key in ipairs(ctx.unique_keys) do
        local object_name = unique_key_object_name(ctx, unique_key)
        local entity = ctx.entity_by_id[key(unique_key.entity_id)]
        if entity == nil then
            add_issue(ctx, "ERROR", "UNIQUE_KEY", object_name, "SEMANTIC_MODEL_028",
                "Unique key owning entity does not exist in this model version.")
        end

        local key_kind = upper(unique_key.kind)
        if not VALID_UNIQUE_KEY_KINDS[key_kind] then
            add_issue(ctx, "ERROR", "UNIQUE_KEY", object_name, "SEMANTIC_MODEL_028",
                "Unsupported unique key kind: " .. tostring(unique_key.kind) .. ".")
        end

        if missing(unique_key.name) then
            add_issue(ctx, "ERROR", "UNIQUE_KEY", object_name, "SEMANTIC_MODEL_028",
                "Unique key name is required.")
        end
        if #unique_key.columns == 0 then
            add_issue(ctx, "ERROR", "UNIQUE_KEY", object_name, "SEMANTIC_MODEL_028",
                "Unique key must contain at least one column or expression.")
        end

        if entity ~= nil then
            local owning_alias = upper(entity.alias)
            for _, column in ipairs(unique_key.columns) do
                local column_name = column.column_name
                local expression = column.expression
                local column_object_name = object_name .. "[" .. tostring(column.ordinal_position) .. "]"
                if missing(column.ordinal_position) then
                    add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                        "Unique key column ordinal position is required.")
                end
                if missing(column_name) and missing(expression) then
                    add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                        "Unique key column must define either COLUMN_NAME or EXPRESSION.")
                elseif not missing(column_name) and not missing(expression) then
                    add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                        "Unique key column must not define both COLUMN_NAME and EXPRESSION.")
                elseif not missing(column_name) then
                    local missing_representations =
                        missing_unique_key_columns(ctx, entity, column_name)
                    if #missing_representations > 0 then
                        add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                            "Unique key column references unknown source column: "
                                .. tostring(column_name)
                                .. representation_suffix(missing_representations) .. "."
                                .. identity_binding_remedy())
                    end
                else
                    validate_unique_key_expression(ctx, unique_key, column, entity, owning_alias, column_object_name)
                end
            end
        end
    end
end

local function resolved_source_column_name(representation, column_name)
    local ok, rows = pcall(query, [[
        SELECT COLUMN_NAME
        FROM SYS.EXA_ALL_COLUMNS
        WHERE (COLUMN_SCHEMA = :schema_name OR COLUMN_SCHEMA = UPPER(:schema_name))
          AND (COLUMN_TABLE = :object_name OR COLUMN_TABLE = UPPER(:object_name))
          AND (COLUMN_NAME = :column_name OR COLUMN_NAME = UPPER(:column_name))
        ORDER BY CASE WHEN COLUMN_NAME = :column_name THEN 0 ELSE 1 END
        LIMIT 1
    ]], {
        schema_name = representation.source_schema,
        object_name = representation.source_object,
        column_name = column_name,
    })
    if not ok then return nil, tostring(rows) end
    if rows == nil or #rows == 0 then
        return nil, "source column is not visible: " .. tostring(column_name)
    end
    return row_value(rows[1], "COLUMN_NAME", 1), nil
end

local function representation_key_query(representation, unique_key)
    local expressions = {}
    for _, column in ipairs(unique_key.columns or {}) do
        if not missing(column.column_name) then
            local physical_name, resolution_error = resolved_source_column_name(
                representation, column.column_name)
            if physical_name == nil then return nil, resolution_error end
            expressions[#expressions + 1] = tostring(representation.alias)
                .. "." .. quote_ident(physical_name)
        elseif not missing(column.expression) then
            expressions[#expressions + 1] = tostring(column.expression)
        end
    end
    if #expressions == 0 then return nil, "declared key has no executable columns" end
    local source = quote_qualified(representation.source_schema,
        representation.source_object) .. " " .. tostring(representation.alias)
    return "SELECT " .. table.concat(expressions, ", ")
        .. " FROM " .. source
        .. " GROUP BY " .. table.concat(expressions, ", "), nil
end

local function probe_count(sql_text)
    local ok, rows = pcall(query, sql_text)
    if not ok then return nil, tostring(rows) end
    if rows == nil or #rows == 0 then return nil, "probe returned no rows" end
    return tonumber(row_value(rows[1], "PROBE_COUNT", 1) or 0), nil
end

local function validate_semantic_identities(ctx)
    local representation_by_id = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
    end
    local names = {}
    local identity_counts = {}
    for _, identity in ipairs(ctx.semantic_identities or {}) do
        local entity = ctx.entity_by_id[key(identity.entity_id)]
        local object_name = (entity and entity.name or tostring(identity.entity_id))
            .. "." .. tostring(identity.name)
        local name_key = upper(identity.name)
        if names[name_key] then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "Semantic identity names must be unique within a model.")
        end
        names[name_key] = true
        identity_counts[key(identity.entity_id)] = (identity_counts[key(identity.entity_id)] or 0) + 1
        if identity_counts[key(identity.entity_id)] > 1 then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "An entity may have only one active semantic identity.")
        end
        if entity == nil then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "Semantic identity references an unknown entity.")
        end
        local kind = upper(identity.kind)
        if kind ~= "BUSINESS" and kind ~= "GLOBAL" then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "Identity kind must be BUSINESS or GLOBAL.")
        end
        if missing(identity.data_type) then
            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                "SEMANTIC_MODEL_047", "Semantic identity data type is required.")
        end
        if entity ~= nil then
            for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                if not missing(representation.coverage_predicate)
                    or not missing(representation.valid_from)
                    or not missing(representation.valid_to) then
                    add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                        "SEMANTIC_MODEL_047", "F5 semantic identity cannot be combined with F3 representation coverage on the same entity.")
                    break
                end
            end
        end
        local seen_representations = {}
        for _, binding in ipairs(identity.bindings or {}) do
            local representation = representation_by_id[key(binding.representation_id)]
            local binding_name = object_name .. "@"
                .. tostring(representation and representation.name or binding.representation_id)
            if missing(binding.expression) then
                add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                    "SEMANTIC_MODEL_047", "Source-local identity expression is required.")
            end
            if seen_representations[key(binding.representation_id)] then
                add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                    "SEMANTIC_MODEL_047", "Duplicate identity binding for representation.")
            end
            seen_representations[key(binding.representation_id)] = true
            if representation == nil or key(representation.entity_id) ~= key(identity.entity_id)
                or key(binding.entity_id) ~= key(identity.entity_id) then
                add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                    "SEMANTIC_MODEL_047", "Identity binding representation or entity is inconsistent.")
            else
                for fn, _ in pairs(unsupported_functions(binding.expression)) do
                    add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                        "SEMANTIC_MODEL_047", "Unsupported function in source-local identity expression: "
                            .. fn .. ".")
                end
                for alias, _ in pairs(aliases_in_expression(binding.expression)) do
                    if alias ~= upper(representation.alias) then
                        add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                            "SEMANTIC_MODEL_047", "Source-local identity expression references alias outside its representation: " .. alias .. ".")
                    end
                end
                for _, ref in ipairs(column_refs_in_expression(binding.expression)) do
                    if ref.alias == upper(representation.alias)
                        and not source_column_exists(representation.source_schema,
                            representation.source_object, ref.column_name) then
                        add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                            "SEMANTIC_MODEL_047", "Source-local identity expression references unknown column: " .. ref.column_name .. ".")
                    end
                end
            end
            local binding_kind = upper(binding.kind)
            if binding_kind ~= "DIRECT" and binding_kind ~= "MAPPED" then
                add_issue(ctx, "ERROR", "IDENTITY_BINDING", binding_name,
                    "SEMANTIC_MODEL_047", "Identity binding kind must be DIRECT or MAPPED.")
            elseif binding_kind == "DIRECT" and binding.mapping ~= nil then
                add_issue(ctx, "ERROR", "IDENTITY_MAPPING", binding_name,
                    "SEMANTIC_MODEL_048", "DIRECT identity binding must not have a mapping relation.")
            elseif binding_kind == "MAPPED" then
                local mapping = binding.mapping
                if mapping == nil or upper(mapping.certification) ~= "CERTIFIED" then
                    add_issue(ctx, "ERROR", "IDENTITY_MAPPING", binding_name,
                        "SEMANTIC_MODEL_048", "MAPPED identity binding requires one CERTIFIED mapping relation.")
                elseif not source_object_exists(mapping.source_schema, mapping.source_object)
                    or not source_column_exists(mapping.source_schema,
                        mapping.source_object, mapping.local_column)
                    or not source_column_exists(mapping.source_schema,
                        mapping.source_object, mapping.semantic_column) then
                    add_issue(ctx, "ERROR", "IDENTITY_MAPPING", binding_name,
                        "SEMANTIC_MODEL_048", "Certified mapping relation or key columns are not visible.")
                end
            end
        end
        if entity ~= nil and #representations_for_entity(ctx, entity) > 1 then
            for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                if not seen_representations[key(representation.id)] then
                    add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY", object_name,
                        "SEMANTIC_MODEL_047", "Semantic identity has no binding for active representation: "
                            .. tostring(representation.name) .. ".")
                end
            end
        end
    end
end

local function identity_grouped_key_query(representation, binding)
    local semantic_expression
    local from_sql = quote_qualified(representation.source_schema,
        representation.source_object) .. " " .. tostring(representation.alias)
    if upper(binding.kind) == "DIRECT" then
        semantic_expression = tostring(binding.expression)
    else
        local mapping = binding.mapping
        local map_alias = "f5_map_" .. tostring(binding.id)
        semantic_expression = map_alias .. "." .. quote_ident(mapping.semantic_column)
        from_sql = from_sql .. " JOIN "
            .. quote_qualified(mapping.source_schema, mapping.source_object)
            .. " " .. map_alias .. " ON " .. tostring(binding.expression)
            .. " = " .. map_alias .. "." .. quote_ident(mapping.local_column)
    end
    return "SELECT " .. semantic_expression .. " FROM " .. from_sql
        .. " WHERE " .. semantic_expression .. " IS NOT NULL GROUP BY "
        .. semantic_expression
end

local function validate_semantic_identity_data(ctx)
    if (ctx.error_count or 0) > 0 then return end
    for _, identity in ipairs(ctx.semantic_identities or {}) do
        local entity = ctx.entity_by_id[key(identity.entity_id)]
        if entity ~= nil and complete_semantic_identity(ctx, entity) == identity then
            local grouped = {}
            local primary_query = nil
            for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                local binding = identity.binding_by_representation[key(representation.id)]
                local object_name = tostring(entity.name) .. "." .. tostring(identity.name)
                    .. "@" .. tostring(representation.name)
                local total, total_error = probe_count("SELECT COUNT(*) AS PROBE_COUNT FROM "
                    .. quote_qualified(representation.source_schema,
                        representation.source_object))
                local local_distinct, local_error = probe_count(
                    "SELECT COUNT(*) AS PROBE_COUNT FROM (SELECT "
                    .. tostring(binding.expression) .. " FROM "
                    .. quote_qualified(representation.source_schema,
                        representation.source_object) .. " " .. tostring(representation.alias)
                    .. " WHERE " .. tostring(binding.expression) .. " IS NOT NULL GROUP BY "
                    .. tostring(binding.expression) .. ") f5_local_keys")
                if total_error ~= nil or local_error ~= nil then
                    add_issue(ctx, "ERROR", "IDENTITY_BINDING", object_name,
                        "SEMANTIC_MODEL_049", "Could not prove source-local identity uniqueness: "
                            .. tostring(total_error or local_error) .. ".")
                elseif total ~= local_distinct then
                    add_issue(ctx, "ERROR", "IDENTITY_BINDING", object_name,
                        "SEMANTIC_MODEL_049", "Source-local identity is null or non-unique: row_count="
                            .. tostring(total) .. ", distinct_key_count=" .. tostring(local_distinct) .. ".")
                end
                if upper(binding.kind) == "MAPPED" then
                    local mapping = binding.mapping
                    local map_source = quote_qualified(mapping.source_schema, mapping.source_object)
                    local map_total, map_total_error = probe_count(
                        "SELECT COUNT(*) AS PROBE_COUNT FROM " .. map_source)
                    local map_local, map_local_error = probe_count(
                        "SELECT COUNT(*) AS PROBE_COUNT FROM (SELECT "
                        .. quote_ident(mapping.local_column) .. " FROM " .. map_source
                        .. " WHERE " .. quote_ident(mapping.local_column) .. " IS NOT NULL"
                        .. " AND " .. quote_ident(mapping.semantic_column) .. " IS NOT NULL"
                        .. " GROUP BY " .. quote_ident(mapping.local_column) .. ") f5_map_local")
                    local map_semantic, map_semantic_error = probe_count(
                        "SELECT COUNT(*) AS PROBE_COUNT FROM (SELECT "
                        .. quote_ident(mapping.semantic_column) .. " FROM " .. map_source
                        .. " WHERE " .. quote_ident(mapping.local_column) .. " IS NOT NULL"
                        .. " AND " .. quote_ident(mapping.semantic_column) .. " IS NOT NULL"
                        .. " GROUP BY " .. quote_ident(mapping.semantic_column) .. ") f5_map_semantic")
                    local mapped_local, mapped_local_error = probe_count(
                        "SELECT COUNT(*) AS PROBE_COUNT FROM (SELECT "
                        .. tostring(binding.expression) .. " FROM "
                        .. quote_qualified(representation.source_schema,
                            representation.source_object) .. " " .. tostring(representation.alias)
                        .. " JOIN " .. map_source .. " f5_total_map ON "
                        .. tostring(binding.expression) .. " = f5_total_map."
                        .. quote_ident(mapping.local_column) .. " GROUP BY "
                        .. tostring(binding.expression) .. ") f5_mapped_local_keys")
                    if map_total_error ~= nil or map_local_error ~= nil
                        or map_semantic_error ~= nil or mapped_local_error ~= nil then
                        add_issue(ctx, "ERROR", "IDENTITY_MAPPING", object_name,
                            "SEMANTIC_MODEL_049", "Could not probe certified identity mapping: "
                                .. tostring(map_total_error or map_local_error
                                    or map_semantic_error or mapped_local_error) .. ".")
                    elseif map_total ~= map_local or map_total ~= map_semantic then
                        add_issue(ctx, "ERROR", "IDENTITY_MAPPING", object_name,
                            "SEMANTIC_MODEL_049", "Certified identity mapping must be one-to-one: rows="
                                .. tostring(map_total) .. ", local_keys=" .. tostring(map_local)
                                .. ", semantic_keys=" .. tostring(map_semantic) .. ".")
                    elseif mapped_local ~= total then
                        add_issue(ctx, "ERROR", "IDENTITY_MAPPING", object_name,
                            "SEMANTIC_MODEL_049", "Certified identity mapping is not total for the representation: source_keys="
                                .. tostring(total) .. ", mapped_source_keys="
                                .. tostring(mapped_local) .. ".")
                    end
                end
                local grouped_query = identity_grouped_key_query(representation, binding)
                grouped[key(representation.id)] = grouped_query
                if upper(representation.role) == "PRIMARY" then
                    primary_query = grouped_query
                end
            end
            if primary_query ~= nil then
                for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                    if upper(representation.role) ~= "PRIMARY" then
                        local alternate_query = grouped[key(representation.id)]
                        local forward, forward_error = probe_count(
                            "SELECT COUNT(*) AS PROBE_COUNT FROM (" .. primary_query
                                .. " MINUS " .. alternate_query .. ") f5_key_difference")
                        local reverse, reverse_error = probe_count(
                            "SELECT COUNT(*) AS PROBE_COUNT FROM (" .. alternate_query
                                .. " MINUS " .. primary_query .. ") f5_key_difference")
                        if forward_error ~= nil or reverse_error ~= nil then
                            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY",
                                tostring(entity.name) .. "." .. tostring(identity.name),
                                "SEMANTIC_MODEL_049", "Could not compare canonical semantic key sets: "
                                    .. tostring(forward_error or reverse_error) .. ".")
                        elseif forward ~= 0 or reverse ~= 0 then
                            add_issue(ctx, "ERROR", "SEMANTIC_IDENTITY",
                                tostring(entity.name) .. "." .. tostring(identity.name),
                                "SEMANTIC_MODEL_049", "Canonical semantic key set differs for representation "
                                    .. tostring(representation.name) .. ": missing_in_alternate="
                                    .. tostring(forward) .. ", missing_in_primary=" .. tostring(reverse) .. ".")
                        end
                    end
                end
            end
        end
    end
end

local function relationship_side_identity_remap(ctx, relationship, side,
        entity, representation)
    if entity == nil or representation == nil then
        return nil, "RELATIONSHIP_ENDPOINT_MISSING"
    end
    local unique_key, key_error = grain_graph.scalar_mapping_key(
        ctx.unique_keys_by_entity[key(entity.id)] or {},
        relationship.key_mappings or {}, side)
    if unique_key == nil then return nil, key_error end
    local identity = complete_semantic_identity(ctx, entity)
    if identity == nil then return nil, "COMPLETE_SEMANTIC_IDENTITY_MISSING" end
    return grain_graph.direct_identity_remap(identity,
        entity.primary_representation, representation, unique_key)
end

local function relationship_mapping_side(relationship, entity, ref)
    if entity == nil or upper(entity.alias) ~= ref.alias then return nil end
    local side = key(entity.id) == key(relationship.from_entity_id) and "from"
        or key(entity.id) == key(relationship.to_entity_id) and "to" or nil
    if side == nil then return nil end
    for _, mapping in ipairs(relationship.key_mappings or {}) do
        local column_name = mapping[side .. "_column_name"]
        if not missing(column_name) and upper(column_name) == upper(ref.column_name) then
            return side
        end
    end
    return nil
end

local MAX_REPRESENTATION_PROBE_TIMEOUT_SECONDS = 60

local function validate_representation_probe_timeout(ctx)
    local has_multi_representation_probe = false
    for _, entity in ipairs(ctx.entities or {}) do
        if #representations_for_entity(ctx, entity) > 1 then
            has_multi_representation_probe = true
            break
        end
    end
    if not has_multi_representation_probe then return true end

    local ok, rows = pcall(query, [[
        SELECT SESSION_VALUE
        FROM EXA_PARAMETERS
        WHERE PARAMETER_NAME = 'QUERY_TIMEOUT'
    ]])
    local timeout = ok and rows ~= nil and #rows > 0
        and tonumber(row_value(rows[1], "SESSION_VALUE", 1)) or nil
    if timeout == nil or timeout < 1
        or timeout > MAX_REPRESENTATION_PROBE_TIMEOUT_SECONDS then
        add_issue(ctx, "ERROR", "MODEL", ctx.model_name,
            "SEMANTIC_MODEL_041",
            "Multi-representation key probes require session QUERY_TIMEOUT between 1 and "
                .. tostring(MAX_REPRESENTATION_PROBE_TIMEOUT_SECONDS)
                .. " seconds; current value is " .. tostring(timeout or "unavailable")
                .. ". Run ALTER SESSION SET QUERY_TIMEOUT="
                .. tostring(MAX_REPRESENTATION_PROBE_TIMEOUT_SECONDS)
                .. " before EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL."
                .. " Exasol applies the timeout to the complete script.")
        return false
    end
    return true
end

local function validate_representation_data_equivalence(ctx)
    if (ctx.error_count or 0) > 0 then return end
    for _, entity in ipairs(ctx.entities or {}) do
        local representations = representations_for_entity(ctx, entity)
        if #representations > 1 and complete_semantic_identity(ctx, entity) == nil then
            local unique_keys = ctx.unique_keys_by_entity[key(entity.id)] or {}
            if #unique_keys == 0 then
                add_issue(ctx, "ERROR", "ENTITY", entity.name,
                    "SEMANTIC_MODEL_037",
                    "Multiple F1 representations require at least one declared unique key to prove grain and identity equivalence.")
            end
            local primary = entity.primary_representation
            local partitioned = entity_uses_partition_fusion(ctx, entity)
            for _, unique_key in ipairs(unique_keys) do
                local object_name = unique_key_object_name(ctx, unique_key)
                local probes = {}
                for _, representation in ipairs(representations) do
                    local grouped_keys, build_error =
                        representation_key_query(representation, unique_key)
                    local representation_name = tostring(entity.name) .. "."
                        .. tostring(representation.name)
                    local probe = {
                        grouped_keys = grouped_keys,
                        build_error = build_error,
                        representation_name = representation_name,
                    }
                    probes[key(representation.id)] = probe
                    if build_error ~= nil then
                        add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                            representation_name,
                            "SEMANTIC_MODEL_037", "Could not construct declared key probe "
                                .. object_name .. ": " .. tostring(build_error) .. ".")
                    end
                    if grouped_keys ~= nil then
                        local total_sql = "SELECT COUNT(*) AS PROBE_COUNT FROM "
                            .. quote_qualified(representation.source_schema,
                                representation.source_object)
                            .. " " .. tostring(representation.alias)
                        local distinct_sql = "SELECT COUNT(*) AS PROBE_COUNT FROM ("
                            .. grouped_keys .. ") representation_keys"
                        probe.total_count, probe.total_error = probe_count(total_sql)
                        probe.distinct_count, probe.distinct_error = probe_count(distinct_sql)
                        local total_count = probe.total_count
                        local total_error = probe.total_error
                        local distinct_count = probe.distinct_count
                        local distinct_error = probe.distinct_error
                        if total_error ~= nil or distinct_error ~= nil then
                            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                representation_name, "SEMANTIC_MODEL_037",
                                "Could not prove declared key " .. object_name .. ": "
                                    .. tostring(total_error or distinct_error) .. ".")
                        elseif total_count ~= distinct_count then
                            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                representation_name, "SEMANTIC_MODEL_037",
                                "Declared key " .. object_name
                                    .. " does not preserve grain: row_count="
                                    .. tostring(total_count) .. ", distinct_key_count="
                                    .. tostring(distinct_count) .. ".")
                        end

                    end
                end

                local primary_probe = primary ~= nil and probes[key(primary.id)] or nil
                for _, representation in ipairs(partitioned and {} or representations) do
                    if primary ~= nil and key(representation.id) ~= key(primary.id) then
                        local probe = probes[key(representation.id)] or {}
                        local representation_name = probe.representation_name
                            or tostring(entity.name) .. "." .. tostring(representation.name)
                        if primary_probe == nil or primary_probe.build_error ~= nil then
                            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                representation_name, "SEMANTIC_MODEL_038",
                                "Could not construct PRIMARY key probe " .. object_name
                                    .. ": " .. tostring(primary_probe and primary_probe.build_error
                                        or "primary representation is unavailable") .. ".")
                        elseif primary_probe.distinct_error ~= nil
                            or probe.distinct_error ~= nil then
                                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                    representation_name, "SEMANTIC_MODEL_038",
                                    "Could not compare declared key " .. object_name
                                        .. " with PRIMARY representation: "
                                        .. tostring(primary_probe.distinct_error
                                            or probe.distinct_error) .. ".")
                        elseif primary_probe.distinct_count ~= probe.distinct_count then
                            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                representation_name, "SEMANTIC_MODEL_038",
                                "Declared key cardinality differs from PRIMARY for "
                                    .. object_name .. ": primary="
                                    .. tostring(primary_probe.distinct_count)
                                    .. ", alternate=" .. tostring(probe.distinct_count) .. ".")
                        elseif primary_probe.grouped_keys ~= nil
                            and probe.grouped_keys ~= nil then
                            local missing_from_alternate, forward_error = probe_count(
                                "SELECT COUNT(*) AS PROBE_COUNT FROM ("
                                    .. primary_probe.grouped_keys .. " MINUS "
                                    .. probe.grouped_keys
                                    .. ") representation_key_difference")
                            local missing_from_primary, reverse_error = probe_count(
                                "SELECT COUNT(*) AS PROBE_COUNT FROM ("
                                    .. probe.grouped_keys .. " MINUS "
                                    .. primary_probe.grouped_keys
                                    .. ") representation_key_difference")
                            if forward_error ~= nil or reverse_error ~= nil then
                                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                    representation_name, "SEMANTIC_MODEL_038",
                                    "Could not compare declared key set " .. object_name
                                        .. " with PRIMARY representation: "
                                        .. tostring(forward_error or reverse_error) .. ".")
                            elseif missing_from_alternate ~= 0
                                or missing_from_primary ~= 0 then
                                add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION",
                                    representation_name, "SEMANTIC_MODEL_038",
                                    "Declared key set differs from PRIMARY for "
                                        .. object_name .. ": missing_in_alternate="
                                        .. tostring(missing_from_alternate)
                                        .. ", missing_in_primary="
                                        .. tostring(missing_from_primary) .. ".")
                            end
                        end
                    end
                end
            end
        end
    end
end

local function validate_relationship_key_mappings(ctx)
    local function validate_side(relationship, mapping, side, entity)
        local column_name = mapping[side .. "_column_name"]
        local expression = mapping[side .. "_expression"]
        local has_column = not missing(column_name)
        local has_expression = not missing(expression)
        if has_column == has_expression then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_032",
                "Relationship key mapping " .. tostring(mapping.ordinal_position)
                    .. " must define exactly one " .. side .. " column or expression.")
            return
        end
        if has_expression then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_032",
                "Expression relationship key mappings are not supported by typed grain proofs; "
                    .. "normalize the expression into a source view and map a column.")
            return
        end
        local unavailable = {}
        local available_count = 0
        if has_column and entity ~= nil then
            for _, representation in ipairs(representations_for_entity(ctx, entity)) do
                if source_column_exists(representation.source_schema,
                    representation.source_object, column_name) then
                    available_count = available_count + 1
                else
                    local remap = relationship_side_identity_remap(ctx,
                        relationship, side, entity, representation)
                    if remap ~= nil then
                        available_count = available_count + 1
                    else
                        unavailable[#unavailable + 1] = tostring(representation.name)
                    end
                end
            end
        end
        table.sort(unavailable)
        if has_column and entity ~= nil and available_count == 0 then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_032", "No active representation can provide or safely remap the "
                    .. side .. " relationship key column: " .. tostring(column_name)
                    .. "." .. identity_binding_remedy())
        elseif #unavailable > 0 then
            add_issue(ctx, "WARNING", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_050", "Relationship candidate excludes " .. side
                    .. " representation(s): " .. table.concat(unavailable, ", ")
                    .. "; the endpoint key is absent and no anchored DIRECT F5 identity remap is available.")
        end
    end

    local function side_matches_unique_key(relationship, side, entity_id)
        for _, unique_key in ipairs(ctx.unique_keys_by_entity[key(entity_id)] or {}) do
            if grain_graph.mapping_matches_key(
                relationship.key_mappings, side, unique_key
            ) then
                return true
            end
        end
        return false
    end

    for _, relationship in ipairs(ctx.relationships) do
        local mappings = relationship.key_mappings or {}
        if #mappings == 0 then
            add_issue(ctx, "WARNING", "RELATIONSHIP", relationship.name,
                "SEMANTIC_MODEL_031",
                "Relationship has no structured endpoint key mappings; legacy "
                    .. "single-branch compilation remains available. For grain "
                    .. "proofs, declare a unique key and its ordered columns first, "
                    .. "then add ordered relationship key mappings.")
        else
            local from_entity = ctx.entity_by_id[key(relationship.from_entity_id)]
            local to_entity = ctx.entity_by_id[key(relationship.to_entity_id)]
            for index, mapping in ipairs(mappings) do
                if tonumber(mapping.ordinal_position) ~= index then
                    add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                        "SEMANTIC_MODEL_032",
                        "Relationship key mapping ordinals must be contiguous from 1.")
                end
                validate_side(relationship, mapping, "from", from_entity)
                validate_side(relationship, mapping, "to", to_entity)
            end

            local cardinality = upper(relationship.cardinality)
            local from_unique = side_matches_unique_key(
                relationship, "from", relationship.from_entity_id
            )
            local to_unique = side_matches_unique_key(
                relationship, "to", relationship.to_entity_id
            )
            local uniqueness_ok = true
            if cardinality == "MANY_TO_ONE" then
                uniqueness_ok = to_unique
            elseif cardinality == "ONE_TO_MANY" then
                uniqueness_ok = from_unique
            elseif cardinality == "ONE_TO_ONE" then
                uniqueness_ok = from_unique and to_unique
            end
            if not uniqueness_ok then
                add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                    "SEMANTIC_MODEL_033",
                    "Relationship endpoint mappings do not match the declared "
                        .. "unique key required by cardinality "
                        .. tostring(relationship.cardinality) .. ".")
            end
        end
    end
end

local function relationship_edges(ctx)
    for _, relationship in ipairs(ctx.relationships) do
        local from_exists = ctx.entity_name_by_id[key(relationship.from_entity_id)] ~= nil
        local to_exists = ctx.entity_name_by_id[key(relationship.to_entity_id)] ~= nil
        if not from_exists or not to_exists then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_006",
                "Relationship endpoint does not exist in this model version.")
        end

        local cardinality = upper(relationship.cardinality)
        if not VALID_CARDINALITIES[cardinality] then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_008",
                "Unsupported relationship cardinality: " .. tostring(relationship.cardinality) .. ".")
        end

        local join_type = upper(relationship.join_type)
        if not VALID_JOIN_TYPES[join_type] then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_009",
                "Unsupported relationship join type: " .. tostring(relationship.join_type) .. ".")
        end

        if cardinality == "MANY_TO_MANY" and missing(relationship.fanout_policy) then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_010",
                "Many-to-many relationship requires an explicit fanout policy.")
        end

        local allowed_aliases = {}
        if from_exists then
            allowed_aliases[ctx.entity_alias_by_id[key(relationship.from_entity_id)]] = true
        end
        if to_exists then
            allowed_aliases[ctx.entity_alias_by_id[key(relationship.to_entity_id)]] = true
        end
        local aliases = aliases_in_expression(relationship.join_condition)
        local alias_count = 0
        for alias, _ in pairs(aliases) do
            alias_count = alias_count + 1
            if not allowed_aliases[alias] then
                add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_007",
                    "Join condition references unknown or out-of-scope alias: " .. alias .. ".")
            end
        end
        if alias_count == 0 then
            add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name, "SEMANTIC_MODEL_007",
                "Join condition must reference the relationship endpoint aliases.")
        end

        for _, ref in ipairs(column_refs_in_expression(relationship.join_condition)) do
            local source_entity = nil
            for _, entity in ipairs(ctx.entities or {}) do
                if upper(entity.alias) == ref.alias then
                    source_entity = entity
                    break
                end
            end
            local missing_representations = source_entity ~= nil
                and missing_representation_columns(ctx, source_entity, ref.column_name) or {}
            local mapped_side = relationship_mapping_side(relationship,
                source_entity, ref)
            if source_entity ~= nil and #missing_representations > 0
                and mapped_side == nil then
                add_issue(ctx, "ERROR", "RELATIONSHIP", relationship.name,
                    "SEMANTIC_MODEL_017", "Relationship join condition references unknown source column: "
                        .. ref.alias .. "." .. ref.column_name
                        .. representation_suffix(missing_representations) .. "."
                        .. identity_binding_remedy())
            end
        end

    end

    return grain_graph.build_edges(ctx.relationships)
end

local function find_path(edge_map, from_id, to_id, require_safe)
    local proof = grain_graph.prove_path(edge_map, from_id, to_id, {
        require_safe = require_safe,
        reject_ambiguous = true,
    })
    return proof.ok, proof.reason, proof.path, proof
end

local function reachable_aliases(ctx, base_entity_id, safe_edges)
    local aliases = {}
    if missing(base_entity_id) then
        return aliases
    end
    local queue = {base_entity_id}
    local seen = {[key(base_entity_id)] = true}
    local index = 1
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        local alias = ctx.entity_alias_by_id[key(current)]
        if alias ~= nil then
            aliases[alias] = true
        end
        for _, edge in ipairs(safe_edges[key(current)] or {}) do
            local next_key = key(edge.to_id)
            if not seen[next_key] then
                seen[next_key] = true
                table.insert(queue, edge.to_id)
            end
        end
    end
    return aliases
end

local function validate_expressions(ctx, safe_edges)
    for _, dimension in ipairs(ctx.dimensions) do
        if ctx.entity_name_by_id[key(dimension.entity_id)] == nil then
            add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_004",
                "Dimension owning entity does not exist in this model version.")
        end
        local owning_alias = ctx.entity_alias_by_id[key(dimension.entity_id)]
        for alias, _ in pairs(aliases_in_expression(dimension.expression)) do
            if alias ~= owning_alias then
                add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_013",
                    "Dimension expression references alias outside the owning entity: " .. alias .. ".")
            end
        end
        for fn, _ in pairs(unsupported_functions(dimension.expression)) do
            add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_016",
                "Unsupported function in dimension expression: " .. fn .. ".")
        end
        local entity = ctx.entity_by_id[key(dimension.entity_id)]
        local bindings = (ctx.bindings_by_attribute or {})["DIMENSION:" .. key(dimension.id)] or {}
        local explicit_binding = false
        for _, binding in ipairs(bindings) do
            if binding.is_default ~= true then explicit_binding = true end
        end
        if entity ~= nil and not explicit_binding then
            for _, ref in ipairs(column_refs_in_expression(dimension.expression)) do
                local missing_representations =
                    missing_representation_columns(ctx, entity, ref.column_name)
                if ref.alias == owning_alias and #missing_representations > 0 then
                    add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_017",
                        "Dimension expression references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name
                            .. representation_suffix(missing_representations) .. ".")
                end
            end
        end
    end

    for _, fact in ipairs(ctx.facts) do
        if ctx.entity_name_by_id[key(fact.entity_id)] == nil then
            add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_004",
                "Fact owning entity does not exist in this model version.")
        end
        local owning_alias = ctx.entity_alias_by_id[key(fact.entity_id)]
        for alias, _ in pairs(aliases_in_expression(fact.expression)) do
            if alias ~= owning_alias then
                add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_013",
                    "Fact expression references alias outside the owning entity: " .. alias .. ".")
            end
        end
        for fn, _ in pairs(unsupported_functions(fact.expression)) do
            add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_016",
                "Unsupported function in fact expression: " .. fn .. ".")
        end
        local entity = ctx.entity_by_id[key(fact.entity_id)]
        local bindings = (ctx.bindings_by_attribute or {})["FACT:" .. key(fact.id)] or {}
        local explicit_binding = false
        for _, binding in ipairs(bindings) do
            if binding.is_default ~= true then explicit_binding = true end
        end
        if entity ~= nil and not explicit_binding then
            for _, ref in ipairs(column_refs_in_expression(fact.expression)) do
                local missing_representations =
                    missing_representation_columns(ctx, entity, ref.column_name)
                if ref.alias == owning_alias and #missing_representations > 0 then
                    add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_017",
                        "Fact expression references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name
                            .. representation_suffix(missing_representations) .. ".")
                end
            end
        end
    end

    local representation_by_id = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
    end
    local seen = {}
    for _, binding in ipairs(ctx.attribute_bindings or {}) do
        local attribute_type = upper(binding.attribute_type)
        local attribute = attribute_type == "DIMENSION"
            and ctx.dimension_by_id[key(binding.attribute_id)]
            or attribute_type == "FACT" and ctx.fact_by_id[key(binding.attribute_id)] or nil
        local representation = representation_by_id[key(binding.representation_id)]
        local object_name = (attribute and attribute.name or tostring(binding.attribute_id))
            .. "@" .. (representation and representation.name or tostring(binding.representation_id))
        local binding_key = attribute_type .. ":" .. key(binding.attribute_id)
            .. ":" .. key(binding.representation_id)
        if seen[binding_key] then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Duplicate active binding for attribute and representation.")
        end
        seen[binding_key] = true
        if attribute == nil or (attribute_type ~= "DIMENSION" and attribute_type ~= "FACT") then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding references an unknown dimension or fact.")
        elseif key(attribute.entity_id) ~= key(binding.entity_id) then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding entity does not match the attribute owner.")
        end
        if representation == nil or key(representation.entity_id) ~= key(binding.entity_id) then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding representation does not belong to the attribute entity.")
        end
        local role = upper(binding.role)
        if role ~= "PREFER" and role ~= "FALLBACK" then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding role must be PREFER or FALLBACK.")
        end
        local priority = tonumber(binding.priority)
        if priority == nil or priority < 1 or priority % 1 ~= 0 then
            add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                "SEMANTIC_MODEL_039", "Binding priority must be a positive integer.")
        end
        if attribute ~= nil and representation ~= nil then
            local owning_alias = upper(representation.alias)
            for alias, _ in pairs(aliases_in_expression(binding.expression)) do
                if alias ~= owning_alias then
                    add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                        "SEMANTIC_MODEL_040", "Binding expression references alias outside its representation: "
                            .. tostring(alias) .. ".")
                end
            end
            for fn, _ in pairs(unsupported_functions(binding.expression)) do
                add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                    "SEMANTIC_MODEL_040", "Unsupported function in binding expression: "
                        .. tostring(fn) .. ".")
            end
            for _, ref in ipairs(column_refs_in_expression(binding.expression)) do
                if ref.alias == owning_alias and not source_column_exists(
                    representation.source_schema, representation.source_object, ref.column_name) then
                    add_issue(ctx, "ERROR", "ATTRIBUTE_BINDING", object_name,
                        "SEMANTIC_MODEL_040", "Binding expression references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name .. ".")
                end
            end
        end
    end

    for _, metric in ipairs(ctx.metrics) do
        if ctx.entity_name_by_id[key(metric.base_entity_id)] == nil then
            add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_014",
                "Metric base entity does not exist in this model version.")
        end
        for fn, _ in pairs(unsupported_functions(metric.expression)) do
            add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_016",
                "Unsupported function in metric expression: " .. fn .. ".")
        end
        for fn, _ in pairs(unsupported_functions(metric.filter_expr)) do
            add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_016",
                "Unsupported function in metric filter expression: " .. fn .. ".")
        end
        local valid_aliases = reachable_aliases(ctx, metric.base_entity_id, safe_edges)
        for alias, _ in pairs(aliases_in_expression(metric.filter_expr)) do
            if not valid_aliases[alias] then
                add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_013",
                    "Metric filter references an alias not reachable from the metric base entity: " .. alias .. ".")
            end
        end
        for _, ref in ipairs(column_refs_in_expression(metric.filter_expr)) do
            if valid_aliases[ref.alias] then
                local source_entity = nil
                for _, entity in ipairs(ctx.entities) do
                    if upper(entity.alias) == ref.alias then
                        source_entity = entity
                        break
                    end
                end
                local missing_representations = source_entity ~= nil
                    and missing_representation_columns(ctx, source_entity, ref.column_name) or {}
                if source_entity ~= nil and #missing_representations > 0 then
                    add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_017",
                        "Metric filter references unknown source column: "
                            .. ref.alias .. "." .. ref.column_name
                            .. representation_suffix(missing_representations) .. ".")
                end
            end
        end
    end
end

local function fusion_attribute(ctx, policy)
    local attribute_type = upper(policy.attribute_type)
    if attribute_type == "DIMENSION" then
        return ctx.dimension_by_id[key(policy.attribute_id)]
    elseif attribute_type == "FACT" then
        return ctx.fact_by_id[key(policy.attribute_id)]
    end
    return nil
end

local function physical_fusion_key(ctx, entity_id)
    for _, unique_key in ipairs(ctx.unique_keys_by_entity[key(entity_id)] or {}) do
        if #(unique_key.columns or {}) > 0 then
            local physical = true
            for _, column in ipairs(unique_key.columns) do
                if missing(column.column_name) or not missing(column.expression) then
                    physical = false
                    break
                end
            end
            if physical then return unique_key end
        end
    end
    return nil
end

local function validate_fusion_policies(ctx)
    local representation_by_id = {}
    local authoritative_by_entity = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
        local role = upper(representation.authority_role or "PREFER")
        if role ~= "AUTHORITATIVE" and role ~= "PREFER" and role ~= "SUPPLEMENTAL" then
            add_issue(ctx, "ERROR", "ENTITY_REPRESENTATION", representation.name,
                "SEMANTIC_MODEL_044", "Authority role must be AUTHORITATIVE, PREFER, or SUPPLEMENTAL.")
        elseif role == "AUTHORITATIVE" then
            local entity_key = key(representation.entity_id)
            authoritative_by_entity[entity_key] =
                (authoritative_by_entity[entity_key] or 0) + 1
        end
    end
    for entity_id, count in pairs(authoritative_by_entity) do
        if count > 1 then
            local entity = ctx.entity_by_id[key(entity_id)]
            add_issue(ctx, "ERROR", "ENTITY", entity and entity.name or entity_id,
                "SEMANTIC_MODEL_044",
                "At most one active representation may be AUTHORITATIVE for an entity.")
        end
    end

    for _, policy in ipairs(ctx.attribute_fusion_policies or {}) do
        local strategy = upper(policy.strategy)
        local attribute = fusion_attribute(ctx, policy)
        local object_name = attribute and attribute.name or tostring(policy.attribute_id)
        local attribute_key = upper(policy.attribute_type) .. ":" .. key(policy.attribute_id)
        if strategy ~= "PREFER" and strategy ~= "COALESCE" and strategy ~= "RECONCILE" then
            add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                "SEMANTIC_MODEL_044", "Fusion strategy must be PREFER, COALESCE, or RECONCILE.")
        elseif attribute == nil or key(attribute.entity_id) ~= key(policy.entity_id) then
            add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                "SEMANTIC_MODEL_044", "Fusion policy references an unknown or mismatched attribute.")
        elseif strategy ~= "PREFER" then
            local entity = ctx.entity_by_id[key(attribute.entity_id)]
            local bindings = ctx.bindings_by_attribute[attribute_key] or {}
            local contributor_representations = {}
            local authority_count = 0
            for _, binding in ipairs(bindings) do
                local representation = representation_by_id[key(binding.representation_id)]
                if representation ~= nil then
                    contributor_representations[key(representation.id)] = true
                    if upper(representation.authority_role or "PREFER") == "AUTHORITATIVE" then
                        authority_count = authority_count + 1
                    end
                end
            end
            local contributor_count = 0
            for _, _ in pairs(contributor_representations) do
                contributor_count = contributor_count + 1
            end
            if contributor_count < 2 then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                    "SEMANTIC_MODEL_044", strategy
                        .. " requires active bindings on at least two representations.")
            end
            if physical_fusion_key(ctx, attribute.entity_id) == nil
                and (entity == nil or complete_semantic_identity(ctx, entity) == nil) then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                    "SEMANTIC_MODEL_044", strategy
                        .. " requires a complete certified semantic identity or a declared unique key containing physical columns only.")
            end
            if entity ~= nil and entity_uses_partition_fusion(ctx, entity) then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                    "SEMANTIC_MODEL_044",
                    "Attribute reconciliation cannot be combined with partition UNION on the same entity.")
            end
            if strategy == "RECONCILE" and authority_count ~= 1 then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", object_name,
                    "SEMANTIC_MODEL_044",
                    "RECONCILE requires exactly one bound representation declared AUTHORITATIVE.")
            end
        end
    end
end

local function identity_conflict_source(representation, identity_binding, alias)
    if upper(identity_binding.kind) == "DIRECT" then
        return quote_qualified(representation.source_schema,
            representation.source_object),
            replace_qualified_alias(identity_binding.expression,
                representation.alias, alias)
    end
    local source_alias = "f5_conflict_src_" .. tostring(representation.id)
    local map_alias = "f5_conflict_map_" .. tostring(identity_binding.id)
    local mapping = identity_binding.mapping
    local local_expression = replace_qualified_alias(identity_binding.expression,
        representation.alias, source_alias)
    local source_sql = "(SELECT " .. source_alias .. ".*, " .. map_alias .. "."
        .. quote_ident(mapping.semantic_column) .. " AS "
        .. quote_ident("F5_SEMANTIC_KEY") .. " FROM "
        .. quote_qualified(representation.source_schema, representation.source_object)
        .. " " .. source_alias .. " JOIN "
        .. quote_qualified(mapping.source_schema, mapping.source_object) .. " "
        .. map_alias .. " ON " .. local_expression .. " = " .. map_alias .. "."
        .. quote_ident(mapping.local_column) .. ")"
    return source_sql, alias .. "." .. quote_ident("F5_SEMANTIC_KEY")
end

local function fusion_conflict_query(left_representation, left_binding,
        right_representation, right_binding, unique_key, semantic_identity)
    local left_alias = "f4_left"
    local right_alias = "f4_right"
    local predicates = {}
    local left_source = quote_qualified(left_representation.source_schema,
        left_representation.source_object)
    local right_source = quote_qualified(right_representation.source_schema,
        right_representation.source_object)
    if semantic_identity ~= nil then
        local left_identity = semantic_identity.binding_by_representation[
            key(left_representation.id)]
        local right_identity = semantic_identity.binding_by_representation[
            key(right_representation.id)]
        local left_key, right_key
        left_source, left_key = identity_conflict_source(left_representation,
            left_identity, left_alias)
        right_source, right_key = identity_conflict_source(right_representation,
            right_identity, right_alias)
        predicates[#predicates + 1] = left_key .. " = " .. right_key
    else
        for _, column in ipairs(unique_key.columns or {}) do
            local left_column, left_error = resolved_source_column_name(
                left_representation, column.column_name)
            local right_column, right_error = resolved_source_column_name(
                right_representation, column.column_name)
            if left_column == nil or right_column == nil then
                return nil, left_error or right_error
            end
            predicates[#predicates + 1] = left_alias .. "." .. quote_ident(left_column)
                .. " = " .. right_alias .. "." .. quote_ident(right_column)
        end
    end
    local left_expression = replace_qualified_alias(left_binding.expression,
        left_representation.alias, left_alias)
    local right_expression = replace_qualified_alias(right_binding.expression,
        right_representation.alias, right_alias)
    return "SELECT COUNT(*) AS PROBE_COUNT FROM "
        .. left_source .. " " .. left_alias
        .. " JOIN " .. right_source .. " " .. right_alias
        .. " ON " .. table.concat(predicates, " AND ")
        .. " WHERE (" .. left_expression .. ") IS NOT NULL"
        .. " AND (" .. right_expression .. ") IS NOT NULL"
        .. " AND (" .. left_expression .. ") <> (" .. right_expression .. ")", nil
end

local function validate_fusion_conflicts(ctx)
    if (ctx.error_count or 0) > 0 then return end
    local representation_by_id = {}
    for _, representation in ipairs(ctx.representations or {}) do
        representation_by_id[key(representation.id)] = representation
    end
    for _, policy in ipairs(ctx.attribute_fusion_policies or {}) do
        local strategy = upper(policy.strategy)
        if strategy == "COALESCE" or strategy == "RECONCILE" then
            local attribute = fusion_attribute(ctx, policy)
            local attribute_key = upper(policy.attribute_type) .. ":" .. key(policy.attribute_id)
            local bindings = ctx.bindings_by_attribute[attribute_key] or {}
            local unique_key = attribute and physical_fusion_key(ctx, attribute.entity_id) or nil
            local entity = attribute and ctx.entity_by_id[key(attribute.entity_id)] or nil
            local semantic_identity = entity and complete_semantic_identity(ctx, entity) or nil
            local conflict_count = 0
            local probe_error = nil
            for left_index = 1, #bindings - 1 do
                for right_index = left_index + 1, #bindings do
                    local left_binding = bindings[left_index]
                    local right_binding = bindings[right_index]
                    local left_representation = representation_by_id[key(left_binding.representation_id)]
                    local right_representation = representation_by_id[key(right_binding.representation_id)]
                    if left_representation ~= nil and right_representation ~= nil
                        and key(left_representation.id) ~= key(right_representation.id) then
                        local sql_text, build_error = fusion_conflict_query(
                            left_representation, left_binding, right_representation,
                            right_binding, unique_key, semantic_identity)
                        if sql_text == nil then
                            probe_error = build_error
                        else
                            local count, count_error = probe_count(sql_text)
                            if count_error ~= nil then probe_error = count_error
                            else conflict_count = conflict_count + count end
                        end
                    end
                end
            end
            if probe_error ~= nil then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", attribute.name,
                    "SEMANTIC_MODEL_044", "Could not evaluate representation conflicts: "
                        .. tostring(probe_error) .. ".")
            elseif conflict_count > 0 and strategy == "COALESCE" then
                add_issue(ctx, "ERROR", "ATTRIBUTE_FUSION_POLICY", attribute.name,
                    "SEMANTIC_MODEL_045", "COALESCE found " .. tostring(conflict_count)
                        .. " overlapping key value(s) with conflicting non-null values; use RECONCILE with one AUTHORITATIVE representation or correct the sources.")
            elseif conflict_count > 0 then
                add_issue(ctx, "WARNING", "ATTRIBUTE_FUSION_POLICY", attribute.name,
                    "SEMANTIC_MODEL_046", "RECONCILE resolved " .. tostring(conflict_count)
                        .. " overlapping key value conflict(s) using the AUTHORITATIVE representation.")
            end
        end
    end
end

local function extract_metric_dependencies(ctx)
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
        WHERE METRIC_ID IN (
          SELECT METRIC_ID
          FROM SYS_SEMANTIC.METRICS
          WHERE MODEL_ID = :model_id
            AND VERSION_ID = :version_id
        )
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})

    ctx.metric_edges = {}
    local dependency_seen = {}
    local function add_dependency(metric, object_type, object_id)
        local dep_key = key(metric.id) .. "|" .. object_type .. "|" .. key(object_id)
        if dependency_seen[dep_key] then
            return
        end
        dependency_seen[dep_key] = true
        query([[
            INSERT INTO SYS_SEMANTIC.METRIC_DEPENDENCIES (
              METRIC_ID, DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID, DEPENDENCY_KIND
            ) VALUES (
              :metric_id, :object_type, :object_id, 'EXPRESSION'
            )
        ]], {metric_id = metric.id, object_type = object_type, object_id = object_id})
        if object_type == "METRIC" then
            local metric_key = key(metric.id)
            ctx.metric_edges[metric_key] = ctx.metric_edges[metric_key] or {}
            table.insert(ctx.metric_edges[metric_key], key(object_id))
        end
    end

    for _, metric in ipairs(ctx.metrics) do
        for normalized, original in pairs(dependency_tokens(metric.expression)) do
            local fact = ctx.fact_by_name[normalized]
            local dependency_metric = ctx.metric_by_name[normalized]
            if fact ~= nil then
                add_dependency(metric, "FACT", fact.id)
            elseif dependency_metric ~= nil then
                add_dependency(metric, "METRIC", dependency_metric.id)
            else
                add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_011",
                    "Metric expression references unknown fact or metric: " .. tostring(original) .. ".")
            end
        end
    end
end

local function detect_metric_cycles(ctx)
    local state = {}
    local cycle_seen = {}

    local function visit(metric_id)
        local metric_key = key(metric_id)
        if state[metric_key] == "visiting" then
            if not cycle_seen[metric_key] then
                cycle_seen[metric_key] = true
                local metric = ctx.metric_by_id[metric_key]
                add_issue(ctx, "ERROR", "METRIC", metric and metric.name or metric_key, "SEMANTIC_MODEL_012",
                    "Cyclic metric dependency detected.")
            end
            return
        end
        if state[metric_key] == "visited" then
            return
        end
        state[metric_key] = "visiting"
        for _, next_id in ipairs(ctx.metric_edges[metric_key] or {}) do
            visit(next_id)
        end
        state[metric_key] = "visited"
    end

    for _, metric in ipairs(ctx.metrics) do
        visit(metric.id)
    end
end

local function validate_agent_metadata(ctx)
    local certified_synonyms = query([[
        SELECT UPPER(s.SYNONYM) AS SYNONYM_TEXT, COUNT(*) AS SYNONYM_COUNT
        FROM SYS_SEMANTIC.SYNONYMS s
        LEFT JOIN SYS_SEMANTIC.DIMENSIONS d
          ON s.OBJECT_TYPE = 'DIMENSION'
         AND d.DIMENSION_ID = s.OBJECT_ID
         AND d.IS_CERTIFIED = TRUE
        LEFT JOIN SYS_SEMANTIC.FACTS f
          ON s.OBJECT_TYPE = 'FACT'
         AND f.FACT_ID = s.OBJECT_ID
         AND f.IS_CERTIFIED = TRUE
        LEFT JOIN SYS_SEMANTIC.METRICS mt
          ON s.OBJECT_TYPE = 'METRIC'
         AND mt.METRIC_ID = s.OBJECT_ID
         AND mt.IS_CERTIFIED = TRUE
        LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON s.OBJECT_TYPE = 'SEMANTIC_OBJECT'
         AND so.OBJECT_ID = s.OBJECT_ID
        WHERE s.MODEL_ID = :model_id
          AND s.VERSION_ID = :version_id
          AND (
            d.DIMENSION_ID IS NOT NULL
            OR f.FACT_ID IS NOT NULL
            OR mt.METRIC_ID IS NOT NULL
            OR so.OBJECT_ID IS NOT NULL
          )
        GROUP BY UPPER(s.SYNONYM)
        HAVING COUNT(*) > 1
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(certified_synonyms or {}) do
        add_issue(ctx, "ERROR", "SYNONYM", row_value(row, "SYNONYM_TEXT", 1), "SEMANTIC_MODEL_021",
            "Certified synonym is ambiguous across multiple semantic objects.")
    end

    for _, metric in ipairs(ctx.metrics) do
        local public_metric = tostring(metric.is_private) ~= "true"
        if public_metric and missing(metric.description) then
            add_issue(ctx, "WARNING", "METRIC", metric.name, "SEMANTIC_MODEL_020",
                "Public metric is missing a description.")
        end
        local numeric_type = string.find(upper(metric.data_type), "DECIMAL") ~= nil
            or string.find(upper(metric.data_type), "DOUBLE") ~= nil
            or string.find(upper(metric.data_type), "INT") ~= nil
            or string.find(upper(metric.data_type), "NUMBER") ~= nil
        if public_metric and numeric_type and missing(metric.unit_hint) and missing(metric.format_hint) then
            add_issue(ctx, "WARNING", "METRIC", metric.name, "SEMANTIC_MODEL_022",
                "Public numeric metric is missing a unit or format hint.")
        end
    end

    local verified_query_rows = query([[
        SELECT vq.VERIFIED_QUERY_ID, vq.QUERY_NAME, vq.OBJECT_ID, vq.REQUEST_JSON
        FROM SYS_SEMANTIC.VERIFIED_QUERIES vq
        LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON so.OBJECT_ID = vq.OBJECT_ID
         AND so.MODEL_ID = vq.MODEL_ID
         AND so.VERSION_ID = vq.VERSION_ID
        WHERE vq.MODEL_ID = :model_id
          AND vq.VERSION_ID = :version_id
          AND vq.STATUS = 'ACTIVE'
          AND vq.OBJECT_ID IS NOT NULL
          AND so.OBJECT_ID IS NULL
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(verified_query_rows or {}) do
        if not missing(row_value(row, "OBJECT_ID", 3)) then
            add_issue(ctx, "ERROR", "VERIFIED_QUERY", row_value(row, "QUERY_NAME", 2), "SEMANTIC_MODEL_023",
                "Verified query references a missing semantic object.")
        end
    end

    local metric_synonyms = {}
    local dimension_synonyms = {}
    local synonym_rows = query([[
        SELECT OBJECT_TYPE, OBJECT_ID, SYNONYM
        FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE IN ('DIMENSION', 'METRIC')
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(synonym_rows or {}) do
        local object_type = upper(row_value(row, "OBJECT_TYPE", 1))
        local object_id = row_value(row, "OBJECT_ID", 2)
        local synonym = upper(row_value(row, "SYNONYM", 3))
        local index = object_type == "METRIC" and metric_synonyms or dimension_synonyms
        local active = object_type == "METRIC"
            and ctx.metric_by_id[key(object_id)] ~= nil
            or object_type == "DIMENSION" and ctx.dimension_by_id[key(object_id)] ~= nil
        if active then
            index[synonym] = index[synonym] or {}
            index[synonym][key(object_id)] = true
        end
    end

    local function reference_status(canonical, synonyms, name)
        local normalized = upper(name)
        if canonical[normalized] ~= nil then
            return "FOUND"
        end
        local count = 0
        for _ in pairs(synonyms[normalized] or {}) do
            count = count + 1
        end
        if count == 1 then
            return "FOUND"
        elseif count > 1 then
            return "AMBIGUOUS"
        end
        return "UNKNOWN"
    end

    local request_rows = query([[
        SELECT QUERY_NAME, REQUEST_JSON
        FROM SYS_SEMANTIC.VERIFIED_QUERIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(request_rows or {}) do
        local query_name = row_value(row, "QUERY_NAME", 1)
        local request_json = row_value(row, "REQUEST_JSON", 2)
        for _, metric_name in ipairs(extract_json_array_values(request_json, "metrics")) do
            local status = reference_status(ctx.metric_by_name, metric_synonyms, metric_name)
            if status == "UNKNOWN" then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references unknown metric: " .. metric_name .. ".")
            elseif status == "AMBIGUOUS" then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references ambiguous metric synonym: " .. metric_name .. ".")
            end
        end
        for _, dimension_name in ipairs(extract_json_array_values(request_json, "dimensions")) do
            local status = reference_status(ctx.dimension_by_name, dimension_synonyms, dimension_name)
            if status == "UNKNOWN" then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references unknown dimension: " .. dimension_name .. ".")
            elseif status == "AMBIGUOUS" then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references ambiguous dimension synonym: " .. dimension_name .. ".")
            end
        end
    end

    local instruction_rows = query([[
        SELECT INSTRUCTION_ID, SCOPE_TYPE, INSTRUCTION_KIND
        FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(instruction_rows or {}) do
        local scope_type = upper(row_value(row, "SCOPE_TYPE", 2))
        local kind = upper(row_value(row, "INSTRUCTION_KIND", 3))
        if not VALID_AGENT_SCOPE_TYPES[scope_type] then
            add_issue(ctx, "ERROR", "AGENT_INSTRUCTION", tostring(row_value(row, "INSTRUCTION_ID", 1)), "SEMANTIC_MODEL_024",
                "Agent instruction has unsupported scope type: " .. scope_type .. ".")
        end
        if not VALID_AGENT_INSTRUCTION_KINDS[kind] then
            add_issue(ctx, "ERROR", "AGENT_INSTRUCTION", tostring(row_value(row, "INSTRUCTION_ID", 1)), "SEMANTIC_MODEL_025",
                "Agent instruction has unsupported instruction kind: " .. kind .. ".")
        end
    end
end

local function rejected_path(edges)
    local parts = {}
    local first_reason = nil
    for _, edge in ipairs(edges or {}) do
        local name = tostring(edge.name)
        if edge.safe == false then
            local reason = tostring(edge.reason or "UNSAFE_RELATIONSHIP_EDGE")
            first_reason = first_reason or reason
            name = name .. " (rejected: " .. reason .. ")"
        end
        parts[#parts + 1] = name
    end
    return #parts == 0 and nil or table.concat(parts, " > "), first_reason
end

local function attempted_path(all_edges, from_id, to_id)
    local ok, reason, _, proof = find_path(all_edges, from_id, to_id, false)
    if ok then
        local path, blocked_reason = rejected_path(proof.edges)
        return path, blocked_reason
    end
    if proof ~= nil and proof.ambiguous then
        local paths = {}
        for _, candidate in ipairs(proof.candidates or {}) do
            paths[#paths + 1] = rejected_path(candidate)
        end
        return table.concat(paths, " | "), reason
    end
    return nil, reason
end

-- Mirrors the compiler's requirement that an object root can reach a metric
-- base without traversing from one-side to many-side.
local function metric_reachable_from_any_root(ctx, metric, safe_edges, all_edges)
    if #ctx.semantic_objects == 0 then
        return true, nil
    end
    local diagnostic_path = nil
    for _, obj in ipairs(ctx.semantic_objects) do
        local ok, _, _ = find_path(safe_edges, obj.root_entity_id, metric.base_entity_id, true)
        if ok then
            return true, nil
        end
        if diagnostic_path == nil then
            diagnostic_path = attempted_path(all_edges, obj.root_entity_id, metric.base_entity_id)
        end
    end
    return false, diagnostic_path
end

local function compute_metric_dimension_matrix(ctx, safe_edges, all_edges)
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})

    local matrix = {}
    for _, metric in ipairs(ctx.metrics) do
        matrix[key(metric.id)] = {}
        -- Pre-check: the compiler starts joins from the semantic object root. If the
        -- metric base entity is unreachable from any root via safe edges, every
        -- metric/dimension combination is invalid (compiler will return SEMANTIC_REQUEST_042).
        local root_can_reach_metric, root_path = metric_reachable_from_any_root(
            ctx, metric, safe_edges, all_edges)
        for _, dimension in ipairs(ctx.dimensions) do
            local is_valid = false
            local reason_code = "OK"
            local path = nil
            if not root_can_reach_metric then
                reason_code = "NO_SAFE_JOIN_PATH"
                path = root_path
            elseif ctx.entity_name_by_id[key(metric.base_entity_id)] == nil then
                reason_code = "MISSING_BASE_ENTITY"
            elseif ctx.entity_name_by_id[key(dimension.entity_id)] == nil then
                reason_code = "MISSING_DIMENSION_ENTITY"
            else
                local ok, reason, relationship_path = find_path(safe_edges, metric.base_entity_id, dimension.entity_id, true)
                if ok then
                    is_valid = true
                    reason_code = "OK"
                    path = relationship_path
                else
                    local blocked_path, blocked_reason = attempted_path(
                        all_edges, metric.base_entity_id, dimension.entity_id)
                    path = blocked_path
                    reason_code = blocked_path ~= nil and blocked_reason or reason
                end
            end
            matrix[key(metric.id)][key(dimension.id)] = {
                is_valid = is_valid,
                reason_code = reason_code,
                path = path,
            }
            query([[
                INSERT INTO SYS_SEMANTIC.METRIC_DIMENSION_MATRIX (
                  MODEL_ID, VERSION_ID, METRIC_ID, DIMENSION_ID, IS_VALID,
                  REASON_CODE, RELATIONSHIP_PATH, VALIDATION_RUN_ID, UPDATED_AT
                ) VALUES (
                  :model_id, :version_id, :metric_id, :dimension_id, :is_valid,
                  :reason_code, :relationship_path, :validation_run_id, CURRENT_TIMESTAMP
                )
            ]], {
                model_id = ctx.model_id,
                version_id = ctx.version_id,
                metric_id = metric.id,
                dimension_id = dimension.id,
                is_valid = is_valid,
                reason_code = reason_code,
                relationship_path = null_if_missing(path),
                validation_run_id = ctx.validation_run_id,
            })
        end
    end
    ctx.matrix = matrix
end

local function validate_visible_metric_dimension_pairs(ctx)
    local pairs = query([[
        SELECT
          so.OBJECT_NAME,
          mt.METRIC_ID,
          mt.METRIC_NAME,
          d.DIMENSION_ID,
          d.DIMENSION_NAME
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so
        JOIN SYS_SEMANTIC.OBJECT_COLUMNS metric_col
          ON metric_col.OBJECT_ID = so.OBJECT_ID
         AND metric_col.COLUMN_KIND = 'METRIC'
         AND metric_col.IS_VISIBLE = TRUE
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = metric_col.OBJECT_REF_ID
        JOIN SYS_SEMANTIC.OBJECT_COLUMNS dimension_col
          ON dimension_col.OBJECT_ID = so.OBJECT_ID
         AND dimension_col.COLUMN_KIND = 'DIMENSION'
         AND dimension_col.IS_VISIBLE = TRUE
        JOIN SYS_SEMANTIC.DIMENSIONS d
          ON d.DIMENSION_ID = dimension_col.OBJECT_REF_ID
        WHERE so.MODEL_ID = :model_id
          AND so.VERSION_ID = :version_id
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})

    for _, row in ipairs(pairs or {}) do
        local metric_id = row_value(row, "METRIC_ID", 2)
        local dimension_id = row_value(row, "DIMENSION_ID", 4)
        local matrix_row = ctx.matrix[key(metric_id)] and ctx.matrix[key(metric_id)][key(dimension_id)]
        if matrix_row ~= nil and not matrix_row.is_valid then
            local object_name = row_value(row, "OBJECT_NAME", 1)
            local path_detail = missing(matrix_row.path)
                and "" or " via " .. tostring(matrix_row.path)
            local message = "Visible metric " .. tostring(row_value(row, "METRIC_NAME", 3))
                .. " cannot be grouped or filtered by dimension " .. tostring(row_value(row, "DIMENSION_NAME", 5))
                .. ": " .. tostring(matrix_row.reason_code) .. path_detail .. "."
            if matrix_row.reason_code == "NO_SAFE_JOIN_PATH" then
                local metric = ctx.metric_by_id[key(metric_id)]
                if metric ~= nil then
                    local base_name = ctx.entity_name_by_id[key(metric.base_entity_id)]
                        or tostring(metric.base_entity_id)
                    message = message .. " Declare a semantic object rooted at '"
                        .. base_name .. "', or remove this metric from object '"
                        .. tostring(object_name) .. "'."
                end
            end
            add_issue(ctx, "ERROR", "SEMANTIC_OBJECT", object_name,
                "SEMANTIC_MODEL_030", message)
        end
    end
end

function M.validate_model(model_name_arg)
    local ctx = {
        issues = {},
        issue_seen = {},
        error_count = 0,
        warning_count = 0,
    }

    local model_loaded = load_model(ctx, model_name_arg)
    if model_loaded then
        load_catalog(ctx)
        validate_structural_rules(ctx)
        validate_custom_extensions(ctx)
        validate_semantic_identities(ctx)
        validate_unique_keys(ctx)
        validate_relationship_key_mappings(ctx)
        local safe_edges, all_edges = relationship_edges(ctx)
        validate_expressions(ctx, safe_edges)
        validate_fusion_policies(ctx)
        extract_metric_dependencies(ctx)
        detect_metric_cycles(ctx)
        validate_agent_metadata(ctx)
        compute_metric_dimension_matrix(ctx, safe_edges, all_edges)
        validate_visible_metric_dimension_pairs(ctx)
        -- Remote equivalence proofs are full data scans. Do not launch them
        -- for a model that is already invalid on local catalog metadata.
        if ctx.error_count == 0 and validate_representation_probe_timeout(ctx) then
            validate_representation_data_equivalence(ctx)
            validate_semantic_identity_data(ctx)
            validate_fusion_conflicts(ctx)
        end
        -- Every admin DDL script (ADD_*, REMOVE_*, PUBLISH_MODEL) calls
        -- VALIDATE_MODEL after mutating the catalog. Invalidating compile-cache
        -- entries here gives all those callers cache-coherent compile results
        -- without each one needing its own DELETE.
        query([[
            DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
            WHERE MODEL_VERSION_ID = :version_id
        ]], {version_id = ctx.version_id})
    end

    finish_validation_run(ctx)
    return ctx.issues
end

validate_model = M.validate_model

-- Test-only pure helpers. See the equivalent compiler block for why this is
-- gated instead of becoming part of the installed runtime contract.
if rawget(_G, "ESV_TEST_MODE") then
    ESV_VALIDATOR_TEST_API = {
        parse_json_text = parse_json_text,
        valid_json_text = valid_json_text,
        strip_string_literals = strip_string_literals,
        aliases_in_expression = aliases_in_expression,
        column_refs_in_expression = column_refs_in_expression,
        schema_qualified_functions = schema_qualified_functions,
        unsupported_functions = unsupported_functions,
        dependency_tokens = dependency_tokens,
        extract_json_array_values = extract_json_array_values,
        source_object_exists = source_object_exists,
        source_column_exists = source_column_exists,
        validate_structural_rules = validate_structural_rules,
        validate_partition_coverage = validate_partition_coverage,
        parse_partition_predicate = parse_partition_predicate,
        entity_has_base_metric = entity_has_base_metric,
        validate_custom_extensions = validate_custom_extensions,
        validate_unique_keys = validate_unique_keys,
        validate_representation_probe_timeout = validate_representation_probe_timeout,
        validate_representation_data_equivalence = validate_representation_data_equivalence,
        validate_semantic_identities = validate_semantic_identities,
        validate_semantic_identity_data = validate_semantic_identity_data,
        validate_fusion_policies = validate_fusion_policies,
        validate_fusion_conflicts = validate_fusion_conflicts,
        validate_relationship_key_mappings = validate_relationship_key_mappings,
        relationship_edges = relationship_edges,
        find_path = find_path,
        validate_expressions = validate_expressions,
        extract_metric_dependencies = extract_metric_dependencies,
        detect_metric_cycles = detect_metric_cycles,
        validate_agent_metadata = validate_agent_metadata,
        compute_metric_dimension_matrix = compute_metric_dimension_matrix,
        validate_visible_metric_dimension_pairs = validate_visible_metric_dimension_pairs,
    }
end
/
-- END GENERATED VALIDATOR_RUNTIME

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(
  MODEL_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.VALIDATOR_RUNTIME", "validator")

local issues = validator.validate_model(MODEL_NAME)
local output_rows = {}
for _, issue in ipairs(issues or {}) do
    table.insert(output_rows, {
        issue.severity,
        issue.object_type,
        issue.object_name or null,
        issue.rule_code,
        issue.message,
    })
end

exit(output_rows, [[
  SEVERITY VARCHAR(32),
  OBJECT_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(512),
  RULE_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000)
]])
/

-- BEGIN GENERATED COMPILER_RUNTIME
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME AS
local M = {}

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
end

local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local function field_key(field)
    return tostring(field.kind) .. ":" .. key(field.id)
end

local function add_rejection(rejections, candidate, reason_code, reason_message)
    rejections[#rejections + 1] = {
        materialization_id = candidate.materialization_id,
        materialization_name = candidate.materialization_name,
        reason_code = reason_code,
        reason_message = reason_message,
    }
end

local function supported_freshness(policy)
    if missing(policy) then
        return true
    end
    local normalized = upper(policy)
    return normalized == "ALWAYS" or normalized == "MANUAL" or normalized == "SNAPSHOT"
end

local function allowed_rollup_policy(policy)
    if missing(policy) then
        return true
    end
    local normalized = upper(policy)
    return normalized == "DIRECT"
        or normalized == "NONE"
        or normalized == "SUM"
        or normalized == "MIN"
        or normalized == "MAX"
        or normalized == "COUNT"
end

local function load_candidates(ctx)
    local rows = query([[
        SELECT MATERIALIZATION_ID, MATERIALIZATION_NAME, PHYSICAL_SCHEMA,
               PHYSICAL_OBJECT, MATERIALIZATION_TYPE, FRESHNESS_POLICY, STATUS
        FROM SYS_SEMANTIC.MATERIALIZATIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
        ORDER BY MATERIALIZATION_ID
    ]], {
        model_id = ctx.model.model_id,
        version_id = ctx.model.version_id,
    })

    local candidates = {}
    local by_id = {}
    local ids = {}
    for _, row in ipairs(rows or {}) do
        local candidate = {
            materialization_id = row_value(row, "MATERIALIZATION_ID", 1),
            materialization_name = row_value(row, "MATERIALIZATION_NAME", 2),
            physical_schema = row_value(row, "PHYSICAL_SCHEMA", 3),
            physical_object = row_value(row, "PHYSICAL_OBJECT", 4),
            materialization_type = row_value(row, "MATERIALIZATION_TYPE", 5),
            freshness_policy = row_value(row, "FRESHNESS_POLICY", 6),
            status = row_value(row, "STATUS", 7),
            columns = {},
            dimension_keys = {},
            metric_keys = {},
        }
        candidates[#candidates + 1] = candidate
        by_id[key(candidate.materialization_id)] = candidate
        ids[#ids + 1] = candidate.materialization_id
    end

    if #ids == 0 then
        return candidates
    end

    local column_rows = query([[
        SELECT MATERIALIZATION_ID, OBJECT_TYPE, OBJECT_ID, PHYSICAL_COLUMN, ROLLUP_POLICY
        FROM SYS_SEMANTIC.MATERIALIZATION_COLUMNS
        WHERE MATERIALIZATION_ID IN (
          SELECT MATERIALIZATION_ID
          FROM SYS_SEMANTIC.MATERIALIZATIONS
          WHERE MODEL_ID = :model_id
            AND VERSION_ID = :version_id
        )
        ORDER BY MATERIALIZATION_ID, OBJECT_TYPE, OBJECT_ID
    ]], {
        model_id = ctx.model.model_id,
        version_id = ctx.model.version_id,
    })

    for _, row in ipairs(column_rows or {}) do
        local materialization_id = row_value(row, "MATERIALIZATION_ID", 1)
        local candidate = by_id[key(materialization_id)]
        if candidate ~= nil then
            local object_type = upper(row_value(row, "OBJECT_TYPE", 2))
            local object_id = row_value(row, "OBJECT_ID", 3)
            local col_key = object_type .. ":" .. key(object_id)
            local column = {
                object_type = object_type,
                object_id = object_id,
                physical_column = row_value(row, "PHYSICAL_COLUMN", 4),
                rollup_policy = row_value(row, "ROLLUP_POLICY", 5),
            }
            candidate.columns[col_key] = column
            if object_type == "DIMENSION" then
                candidate.dimension_keys[col_key] = true
            elseif object_type == "METRIC" then
                candidate.metric_keys[col_key] = true
            end
        end
    end

    return candidates
end

local function count_extra_dimensions(candidate, selected_dimension_keys)
    local count = 0
    for dimension_key, _ in pairs(candidate.dimension_keys) do
        if not selected_dimension_keys[dimension_key] then
            count = count + 1
        end
    end
    return count
end

local function sorted_states_for_branch(physical_plan, branch)
    local result = {}
    for _, state in ipairs(physical_plan.states or {}) do
        if key(state.leaf_entity_id) == key(branch.leaf_entity_id) then
            result[#result + 1] = state
        end
    end
    table.sort(result, function(left, right)
        return key(left.state_id) < key(right.state_id)
    end)
    return result
end

local function required_branch_dimensions(physical_plan)
    local result = {}
    for _, dimension in ipairs(physical_plan.dimensions or {}) do
        result["DIMENSION:" .. key(dimension.dimension_id)] = true
    end
    for _, predicate in ipairs(physical_plan.global_filters or {}) do
        result["DIMENSION:" .. key(predicate.dimension_id)] = true
    end
    return result
end

local function branch_candidate(candidate, physical_plan, branch,
    required_dimensions, states)
    if upper(candidate.status) ~= "ACTIVE" then
        return nil, "INACTIVE", "Materialization status is not ACTIVE."
    end
    if upper(candidate.materialization_type) ~= "AGGREGATE" then
        return nil, "UNSUPPORTED_TYPE",
            "Only AGGREGATE materializations can provide branch states."
    end
    if not supported_freshness(candidate.freshness_policy) then
        return nil, "UNSUPPORTED_FRESHNESS_POLICY",
            "Freshness policy is not supported by the deterministic selector."
    end
    local dimension_columns = {}
    local dimension_keys = {}
    for dimension_key, _ in pairs(required_dimensions) do
        dimension_keys[#dimension_keys + 1] = dimension_key
    end
    table.sort(dimension_keys)
    for _, dimension_key in ipairs(dimension_keys) do
        local column = candidate.columns[dimension_key]
        if column == nil then
            return nil, "MISSING_DIMENSION",
                "A selected or globally filtered dimension is not present."
        end
        dimension_columns[dimension_key] = column
    end

    local state_columns = {}
    for _, state in ipairs(states) do
        if not missing(state.filter_expression) then
            return nil, "FILTERED_STATE_UNSUPPORTED",
                "Metric-local filters do not yet have a materialized-state identity contract."
        end
        if upper(state.merge_operator) ~= "SUM" then
            return nil, "STATE_MERGE_UNSUPPORTED",
                "The materialized state requires an unsupported merge operator."
        end
        local column = candidate.columns["METRIC:" .. key(state.metric_id)]
        if column == nil then
            return nil, "MISSING_STATE",
                "A complete aggregate-state producer metric is not present."
        end
        local policy = missing(column.rollup_policy)
            and "DIRECT" or upper(column.rollup_policy)
        if policy ~= upper(state.merge_operator) then
            return nil, "ROLLUP_POLICY_UNSAFE",
                "The state column rollup policy does not match its merge operator."
        end
        state_columns[key(state.state_id)] = column
    end

    return {
        candidate = candidate,
        dimension_columns = dimension_columns,
        state_columns = state_columns,
        extra_dimension_count = count_extra_dimensions(candidate,
            required_dimensions),
    }
end

local function materialization_column(candidate, field)
    return candidate.columns[field_key(field)]
end

function M.select_materialization(ctx, selected_dimensions, selected_metrics, filter_dimensions)
    local diagnostics = {
        candidate_count = 0,
        rejected_materializations = {},
    }

    local candidates = load_candidates(ctx)
    diagnostics.candidate_count = #candidates
    if #candidates == 0 then
        diagnostics.selected_materialization = null
        return nil, diagnostics
    end

    local selected_dimension_keys = {}
    local required_dimension_keys = {}
    for _, dimension in ipairs(selected_dimensions or {}) do
        selected_dimension_keys[field_key(dimension)] = true
        required_dimension_keys[field_key(dimension)] = true
    end
    for _, dimension in ipairs(filter_dimensions or {}) do
        required_dimension_keys[field_key(dimension)] = true
    end

    local eligible = {}
    for _, candidate in ipairs(candidates) do
        local rejected = false
        local function reject(reason_code, reason_message)
            if not rejected then
                add_rejection(diagnostics.rejected_materializations, candidate, reason_code, reason_message)
                rejected = true
            end
        end

        if upper(candidate.status) ~= "ACTIVE" then
            reject("INACTIVE", "Materialization status is not ACTIVE.")
        elseif upper(candidate.materialization_type) ~= "AGGREGATE" then
            reject("UNSUPPORTED_TYPE", "Only AGGREGATE materializations are supported in this milestone.")
        elseif not supported_freshness(candidate.freshness_policy) then
            reject("UNSUPPORTED_FRESHNESS_POLICY", "Freshness policy is not supported by the deterministic selector.")
        else
            for dimension_key, _ in pairs(required_dimension_keys) do
                if candidate.columns[dimension_key] == nil then
                    reject("MISSING_DIMENSION", "A selected or filtered dimension is not present.")
                    break
                end
            end
        end

        if not rejected then
            local extra_dimension_count = count_extra_dimensions(candidate, selected_dimension_keys)
            local needs_rollup = extra_dimension_count > 0
            local metric_rollup_policies = {}
            for _, metric in ipairs(selected_metrics or {}) do
                local column = materialization_column(candidate, metric)
                if column == nil then
                    reject("MISSING_METRIC", "A selected metric is not present.")
                    break
                end
                if not allowed_rollup_policy(column.rollup_policy) then
                    reject("UNSUPPORTED_ROLLUP_POLICY", "Metric rollup policy is not supported.")
                    break
                end
                local policy = missing(column.rollup_policy) and "DIRECT" or upper(column.rollup_policy)
                metric_rollup_policies[field_key(metric)] = policy
                if needs_rollup then
                    if policy ~= "SUM" then
                        reject("ROLLUP_POLICY_UNSAFE", "Metric rollup requires an explicit SUM policy.")
                        break
                    end
                    if upper(metric.metric_type) ~= "ADDITIVE" then
                        reject("NON_ADDITIVE_ROLLUP", "Only ADDITIVE metrics can be rolled up from aggregate materializations.")
                        break
                    end
                end
            end
            if not rejected then
                candidate.extra_dimension_count = extra_dimension_count
                candidate.rollup_required = needs_rollup
                candidate.metric_rollup_policies = metric_rollup_policies
                eligible[#eligible + 1] = candidate
            end
        end
    end

    if #eligible == 0 then
        diagnostics.selected_materialization = null
        return nil, diagnostics
    end

    table.sort(eligible, function(left, right)
        if left.extra_dimension_count ~= right.extra_dimension_count then
            return left.extra_dimension_count < right.extra_dimension_count
        end
        return tonumber(left.materialization_id) < tonumber(right.materialization_id)
    end)

    local selected = eligible[1]
    diagnostics.selected_materialization = selected.materialization_name
    diagnostics.selected_materialization_id = selected.materialization_id
    diagnostics.rollup_required = selected.rollup_required
    return selected, diagnostics
end

-- Select one complete aggregate-state source for each physical leaf. A
-- rejected or partial candidate never changes the already proven base branch.
function M.select_branch_sources(ctx, physical_plan)
    local candidates = load_candidates(ctx)
    local required_dimensions = required_branch_dimensions(physical_plan)
    local selections = {}
    local diagnostics = {
        candidate_count = #candidates,
        rejected_materializations = {},
        selected_materialization = null,
        selected_materializations = {},
        branches = {},
    }

    for _, branch in ipairs(physical_plan.branches or {}) do
        local branch_diagnostic = {
            branch_id = branch.branch_id,
            leaf_entity_id = branch.leaf_entity_id,
            candidate_count = #candidates,
            rejected_materializations = {},
            selected_materialization = null,
            fallback_reason = "NO_ELIGIBLE_MATERIALIZATION",
        }
        local eligible = {}
        local states = sorted_states_for_branch(physical_plan, branch)
        local partition_branch = upper(branch.source and branch.source.source_kind)
            == "REPRESENTATION_PARTITION"
        for _, candidate in ipairs(partition_branch and {} or candidates) do
            local selection, reason_code, reason_message = branch_candidate(
                candidate, physical_plan, branch, required_dimensions, states)
            if selection == nil then
                local rejection = {
                    branch_id = branch.branch_id,
                    materialization_id = candidate.materialization_id,
                    materialization_name = candidate.materialization_name,
                    reason_code = reason_code,
                    reason_message = reason_message,
                }
                branch_diagnostic.rejected_materializations[
                    #branch_diagnostic.rejected_materializations + 1] = rejection
                diagnostics.rejected_materializations[
                    #diagnostics.rejected_materializations + 1] = rejection
            else
                eligible[#eligible + 1] = selection
            end
        end
        if partition_branch then
            branch_diagnostic.candidate_count = 0
            branch_diagnostic.fallback_reason = "FUSION_PARTITION_MATERIALIZATION_UNSUPPORTED"
        end
        table.sort(eligible, function(left, right)
            if left.extra_dimension_count ~= right.extra_dimension_count then
                return left.extra_dimension_count < right.extra_dimension_count
            end
            return tonumber(left.candidate.materialization_id)
                < tonumber(right.candidate.materialization_id)
        end)
        if #eligible > 0 then
            local selected = eligible[1]
            selections[key(branch.branch_id)] = selected
            branch_diagnostic.selected_materialization =
                selected.candidate.materialization_name
            branch_diagnostic.selected_materialization_id =
                selected.candidate.materialization_id
            branch_diagnostic.extra_dimension_count =
                selected.extra_dimension_count
            branch_diagnostic.fallback_reason = null
            diagnostics.selected_materializations[
                #diagnostics.selected_materializations + 1] = {
                branch_id = branch.branch_id,
                leaf_entity_id = branch.leaf_entity_id,
                materialization_id = selected.candidate.materialization_id,
                materialization_name = selected.candidate.materialization_name,
                extra_dimension_count = selected.extra_dimension_count,
            }
        end
        diagnostics.branches[#diagnostics.branches + 1] = branch_diagnostic
    end
    return selections, diagnostics
end

select_materialization = M.select_materialization
select_branch_sources = M.select_branch_sources

if rawget(_G, "ESV_TEST_MODE") then
    ESV_MATERIALIZATION_TEST_API = {
        select_materialization = M.select_materialization,
        select_branch_sources = M.select_branch_sources,
        supported_freshness = supported_freshness,
        allowed_rollup_policy = allowed_rollup_policy,
    }
end
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILER_RUNTIME AS
-- Canonical relationship graph and path-proof implementation shared by the
-- validator and compiler runtimes. The packaging step embeds this source into
-- both Exasol scripts so the installed runtime has no external dependency.

local M = {}

local function key(value)
    return tostring(value)
end

local function upper(value)
    return string.upper(tostring(value or ""))
end

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function copy_list(values)
    local out = {}
    for _, value in ipairs(values or {}) do
        out[#out + 1] = value
    end
    return out
end

local function edge_order(left, right)
    local left_priority = tonumber(left.path_priority) or 100
    local right_priority = tonumber(right.path_priority) or 100
    if left_priority ~= right_priority then
        return left_priority < right_priority
    end
    local left_id = tonumber(left.relationship and left.relationship.id) or math.huge
    local right_id = tonumber(right.relationship and right.relationship.id) or math.huge
    if left_id ~= right_id then
        return left_id < right_id
    end
    if tostring(left.name) ~= tostring(right.name) then
        return tostring(left.name) < tostring(right.name)
    end
    return key(left.to_id) < key(right.to_id)
end

local function add_edge(target, from_id, to_id, relationship, safe, reason)
    local from_key = key(from_id)
    target[from_key] = target[from_key] or {}
    target[from_key][#target[from_key] + 1] = {
        from_id = from_id,
        to_id = to_id,
        name = relationship.name,
        relationship = relationship,
        safe = safe,
        reason = reason,
        path_priority = relationship.path_priority,
    }
end

-- Build both the cardinality-preserving graph and the complete relationship
-- graph. A declared fanout policy remains compatible with the legacy planner.
-- Phase C can pass allow_many_to_many=false for the stricter multi-fact proof.
function M.build_edges(relationships, options)
    options = options or {}
    local allow_many_to_many = options.allow_many_to_many
    if allow_many_to_many == nil then
        allow_many_to_many = true
    end
    local safe_edges = {}
    local all_edges = {}

    for _, relationship in ipairs(relationships or {}) do
        local cardinality = upper(relationship.cardinality)
        local function add(from_id, to_id, safe, reason)
            add_edge(all_edges, from_id, to_id, relationship, safe, reason)
            if safe then
                add_edge(safe_edges, from_id, to_id, relationship, true, "OK")
            end
        end

        if cardinality == "ONE_TO_ONE" then
            add(relationship.from_entity_id, relationship.to_entity_id, true, "OK")
            add(relationship.to_entity_id, relationship.from_entity_id, true, "OK")
        elseif cardinality == "MANY_TO_ONE" then
            add(relationship.from_entity_id, relationship.to_entity_id, true, "OK")
            add(relationship.to_entity_id, relationship.from_entity_id, false,
                "FANOUT_REQUIRES_POLICY")
        elseif cardinality == "ONE_TO_MANY" then
            add(relationship.to_entity_id, relationship.from_entity_id, true, "OK")
            add(relationship.from_entity_id, relationship.to_entity_id, false,
                "FANOUT_REQUIRES_POLICY")
        elseif cardinality == "MANY_TO_MANY" then
            local safe = allow_many_to_many and not missing(relationship.fanout_policy)
            local reason = safe and "OK" or "MANY_TO_MANY_REQUIRES_FANOUT"
            add(relationship.from_entity_id, relationship.to_entity_id, safe, reason)
            add(relationship.to_entity_id, relationship.from_entity_id, safe, reason)
        end
    end

    for _, edge_map in ipairs({safe_edges, all_edges}) do
        for _, edges in pairs(edge_map) do
            table.sort(edges, edge_order)
        end
    end
    return safe_edges, all_edges
end

local function path_signature(path)
    local parts = {}
    for _, edge in ipairs(path) do
        parts[#parts + 1] = tostring(edge.name) .. ":" .. key(edge.to_id)
    end
    return table.concat(parts, ">")
end

local function path_text(path)
    local names = {}
    for _, edge in ipairs(path or {}) do
        names[#names + 1] = edge.name
    end
    return #names == 0 and "SELF" or table.concat(names, " > ")
end

-- Return a proof object instead of only a path. All shortest safe paths are
-- retained so semantic ambiguity cannot be hidden by relationship ordering or
-- PATH_PRIORITY.
function M.prove_path(edge_map, from_id, to_id, options)
    options = options or {}
    if missing(from_id) or missing(to_id) then
        return {ok = false, reason = "MISSING_ENTITY", candidates = {}}
    end
    if key(from_id) == key(to_id) then
        return {
            ok = true,
            reason = "OK",
            edges = {},
            path = "SELF",
            candidates = {{}},
            ambiguous = false,
        }
    end

    local queue = {{id = from_id, path = {}, visited = {[key(from_id)] = true}}}
    local best_depth_by_node = {[key(from_id)] = 0}
    local candidates = {}
    local candidate_seen = {}
    local shortest = nil
    local first_blocked_reason = nil
    local index = 1

    local max_depth = tonumber(options.max_depth) or 64
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        local depth = #current.path
        if depth < max_depth
            and (shortest == nil or depth < shortest or options.reject_any_ambiguity) then
            for _, edge in ipairs(edge_map[key(current.id)] or {}) do
                if options.require_safe and not edge.safe then
                    first_blocked_reason = first_blocked_reason or edge.reason
                else
                    local next_key = key(edge.to_id)
                    if not current.visited[next_key] then
                        local next_path = copy_list(current.path)
                        next_path[#next_path + 1] = edge
                        local next_depth = #next_path
                        if next_key == key(to_id) then
                            shortest = shortest or next_depth
                            if next_depth == shortest or options.reject_any_ambiguity then
                                local signature = path_signature(next_path)
                                if not candidate_seen[signature] then
                                    candidate_seen[signature] = true
                                    candidates[#candidates + 1] = next_path
                                end
                            end
                        elseif (shortest == nil or options.reject_any_ambiguity)
                            and (options.reject_any_ambiguity
                                or best_depth_by_node[next_key] == nil
                                or next_depth <= best_depth_by_node[next_key]) then
                            best_depth_by_node[next_key] = next_depth
                            local visited = {}
                            for entity_key, seen in pairs(current.visited) do
                                visited[entity_key] = seen
                            end
                            visited[next_key] = true
                            queue[#queue + 1] = {
                                id = edge.to_id,
                                path = next_path,
                                visited = visited,
                            }
                        end
                    end
                end
            end
        end
    end

    if #candidates == 0 then
        return {
            ok = false,
            reason = first_blocked_reason or "NO_RELATIONSHIP_PATH",
            candidates = {},
            ambiguous = false,
        }
    end

    table.sort(candidates, function(left, right)
        if #left ~= #right then return #left < #right end
        return path_signature(left) < path_signature(right)
    end)
    local ambiguous = #candidates > 1
    if ambiguous and options.reject_ambiguous then
        local descriptions = {}
        for _, candidate in ipairs(candidates) do
            descriptions[#descriptions + 1] = path_text(candidate)
        end
        return {
            ok = false,
            reason = "AMBIGUOUS_RELATIONSHIP_PATH",
            candidates = candidates,
            candidate_paths = descriptions,
            ambiguous = true,
        }
    end

    return {
        ok = true,
        reason = "OK",
        edges = candidates[1],
        path = path_text(candidates[1]),
        candidates = candidates,
        ambiguous = ambiguous,
    }
end

function M.path_text(path)
    return path_text(path)
end

function M.canonical_key(unique_key)
    local columns = {}
    for _, column in ipairs((unique_key or {}).columns or {}) do
        local column_name = nil
        local expression = nil
        if not missing(column.column_name) then
            column_name = tostring(column.column_name)
        end
        if not missing(column.expression) then
            expression = tostring(column.expression)
        end
        columns[#columns + 1] = {
            ordinal_position = tonumber(column.ordinal_position),
            column_name = column_name,
            expression = expression,
        }
    end
    table.sort(columns, function(left, right)
        return (left.ordinal_position or math.huge) < (right.ordinal_position or math.huge)
    end)
    return {
        id = unique_key and unique_key.id or nil,
        entity_id = unique_key and unique_key.entity_id or nil,
        name = unique_key and unique_key.name or nil,
        kind = upper(unique_key and unique_key.kind or "UNIQUE"),
        columns = columns,
    }
end

function M.mapping_matches_key(mappings, side, unique_key)
    local columns = (unique_key or {}).columns or {}
    if #mappings == 0 or #mappings ~= #columns then
        return false
    end
    for index, mapping in ipairs(mappings) do
        local mapped_column = mapping[side .. "_column_name"]
        local mapped_expression = mapping[side .. "_expression"]
        local key_column = columns[index]
        if not missing(key_column.column_name) then
            if upper(mapped_column) ~= upper(key_column.column_name) then
                return false
            end
        elseif tostring(mapped_expression or "") ~= tostring(key_column.expression or "") then
            return false
        end
    end
    return true
end

local function direct_column_expression(expression, source_alias)
    local text = tostring(expression or ""):match("^%s*(.-)%s*$")
    local alias, column = string.match(text,
        "^([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*([A-Za-z_][A-Za-z0-9_]*)$")
    if alias ~= nil and upper(alias) == upper(source_alias) then
        return upper(column)
    end
    alias, column = string.match(text,
        '^([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*"([^"]+)"$')
    if alias ~= nil and upper(alias) == upper(source_alias) then
        return column
    end
    return nil
end

function M.scalar_mapping_key(unique_keys, mappings, side)
    if #(mappings or {}) ~= 1 then
        return nil, "COMPOSITE_RELATIONSHIP_KEY_UNSUPPORTED"
    end
    local mapping = mappings[1]
    if missing(mapping[side .. "_column_name"])
        or not missing(mapping[side .. "_expression"]) then
        return nil, "EXPRESSION_RELATIONSHIP_KEY_UNSUPPORTED"
    end
    for _, unique_key in ipairs(unique_keys or {}) do
        local columns = unique_key.columns or {}
        if #columns == 1 and not missing(columns[1].column_name)
            and missing(columns[1].expression)
            and M.mapping_matches_key(mappings, side, unique_key) then
            return unique_key, nil
        end
    end
    return nil, "RELATIONSHIP_ENDPOINT_IS_NOT_SCALAR_UNIQUE_KEY"
end

function M.direct_identity_remap(identity, primary_representation,
        target_representation, unique_key)
    if identity == nil or primary_representation == nil
        or target_representation == nil or unique_key == nil then
        return nil, "SEMANTIC_IDENTITY_REMAP_METADATA_MISSING"
    end
    local primary_binding = identity.binding_by_representation
        and identity.binding_by_representation[key(primary_representation.id)] or nil
    local target_binding = identity.binding_by_representation
        and identity.binding_by_representation[key(target_representation.id)] or nil
    if primary_binding == nil or upper(primary_binding.kind) ~= "DIRECT" then
        return nil, "PRIMARY_IDENTITY_BINDING_NOT_DIRECT"
    end
    if target_binding == nil or upper(target_binding.kind) ~= "DIRECT" then
        return nil, "REPRESENTATION_IDENTITY_BINDING_NOT_DIRECT"
    end
    local key_column = unique_key.columns and unique_key.columns[1]
        and unique_key.columns[1].column_name or nil
    local anchor_column = direct_column_expression(primary_binding.expression,
        primary_representation.alias)
    if missing(key_column) or anchor_column == nil
        or upper(anchor_column) ~= upper(key_column) then
        return nil, "SEMANTIC_IDENTITY_NOT_ANCHORED_TO_RELATIONSHIP_KEY"
    end
    return {
        identity = identity,
        unique_key = unique_key,
        primary_binding = primary_binding,
        binding = target_binding,
    }, nil
end

ESV_GRAIN_GRAPH = M

-- Canonical request boundary shared by JSON and Semantic SQL lowering.

local M = {VERSION = 1}

local ARRAY_FIELDS = {"metrics", "dimensions", "filters", "having", "order_by"}
local ARRAY_FIELD_SET = {}
for _, name in ipairs(ARRAY_FIELDS) do ARRAY_FIELD_SET[name] = true end

local function copy(value, seen)
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then error("QuerySpec cannot contain cycles") end
    seen[value] = true
    local out = {}
    for key, child in pairs(value) do out[key] = copy(child, seen) end
    seen[value] = nil
    return out
end

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function normalize_name(value)
    if value == nil then return nil end
    local normalized = trim(value)
    if normalized == "" then return nil end
    return normalized
end

local function is_array(value)
    if type(value) ~= "table" then return false end
    local count = 0
    local largest = 0
    for item_key, _ in pairs(value) do
        if type(item_key) ~= "number" or item_key < 1 or item_key % 1 ~= 0 then
            return false
        end
        count = count + 1
        if item_key > largest then largest = item_key end
    end
    return count == largest
end

function M.new(request, source)
    if type(request) ~= "table" then
        return nil, "QUERY_SPEC_INVALID"
    end
    local spec = {
        query_spec_version = M.VERSION,
        source = source or request.source or "JSON",
        model = normalize_name(request.model),
        object = normalize_name(request.object),
        metrics = {},
        dimensions = {},
        filters = {},
        having = {},
        order_by = {},
    }
    for _, name in ipairs(ARRAY_FIELDS) do
        local value = request[name]
        if value ~= nil then
            if not is_array(value) then
                return nil, "QUERY_SPEC_" .. string.upper(name) .. "_NOT_ARRAY"
            end
            spec[name] = copy(value)
        end
    end
    if request.limit ~= nil then spec.limit = request.limit end
    if request.client ~= nil then spec.client = request.client end
    if request.purpose ~= nil then spec.purpose = request.purpose end
    if request.natural_language_text ~= nil then
        spec.natural_language_text = request.natural_language_text
    end
    if request.proof_mode ~= nil then
        spec.proof_mode = string.upper(trim(request.proof_mode))
    else
        spec.proof_mode = "LEGACY_JOIN"
    end
    return spec
end

function M.equivalent(left, right)
    local function same(a, b)
        if type(a) ~= type(b) then return false end
        if type(a) ~= "table" then return a == b end
        for key, value in pairs(a) do
            if key ~= "source" and not same(value, b[key]) then return false end
        end
        for key, value in pairs(b) do
            if key ~= "source" and a[key] == nil and value ~= nil then return false end
        end
        return true
    end
    return same(left, right)
end

ESV_QUERY_SPEC = M

-- Detached model-versioned catalog input for the typed planner.

local M = {VERSION = 4}

local function key(value) return tostring(value) end

local function clone(value, seen)
    if value == null then return null end
    if type(value) ~= "table" then return value end
    seen = seen or {}
    if seen[value] then return seen[value] end
    local out = {}
    seen[value] = out
    for child_key, child in pairs(value) do
        if string.sub(tostring(child_key), 1, 1) ~= "_" then
            out[child_key] = clone(child, seen)
        end
    end
    return out
end

local function index_by(values, field)
    local out = {}
    for _, value in ipairs(values or {}) do out[key(value[field])] = value end
    return out
end

local function collect_transitive(metric_by_id, metric_ids)
    local selected = {}
    local ordered = {}
    local function visit(metric_id)
        local metric_key = key(metric_id)
        if selected[metric_key] then return end
        local metric = metric_by_id[metric_key]
        if metric == nil then return end
        selected[metric_key] = true
        for _, input in ipairs(metric.inputs or {}) do
            if string.upper(tostring(input.object_type or "")) == "METRIC" then
                visit(input.object_id)
            end
        end
        for _, dependency in ipairs(metric.dependencies or {}) do
            if string.upper(tostring(dependency.object_type or "")) == "METRIC" then
                visit(dependency.object_id)
            end
        end
        ordered[#ordered + 1] = metric
    end
    for _, metric_id in ipairs(metric_ids or {}) do visit(metric_id) end
    return ordered
end

function M.from_context(ctx, selected_metrics)
    local all_metrics = ctx.all_metrics or ctx.metrics or {}
    local all_metric_by_id = ctx.all_metric_by_id or index_by(all_metrics, "id")
    local requested_ids = {}
    for _, metric in ipairs(selected_metrics or {}) do requested_ids[#requested_ids + 1] = metric.id end
    local snapshot = {
        catalog_snapshot_version = M.VERSION,
        model_id = ctx.model and ctx.model.model_id,
        version_id = ctx.model and ctx.model.version_id,
        version_number = ctx.model and ctx.model.version_number,
        object = clone(ctx.object),
        entities = clone(ctx.entities or {}),
        representations = clone(ctx.representations or {}),
        dimensions = clone(ctx.dimensions or {}),
        visible_metrics = clone(ctx.metrics or {}),
        metrics = clone(collect_transitive(all_metric_by_id, requested_ids)),
        facts = clone(ctx.facts or {}),
        relationships = clone(ctx.relationships or {}),
        unique_keys = clone(ctx.unique_keys or {}),
    }
    snapshot.entity_by_id = index_by(snapshot.entities, "id")
    snapshot.representation_by_id = index_by(snapshot.representations, "id")
    snapshot.representations_by_entity = {}
    for _, representation in ipairs(snapshot.representations) do
        local entity_key = key(representation.entity_id)
        snapshot.representations_by_entity[entity_key] =
            snapshot.representations_by_entity[entity_key] or {}
        snapshot.representations_by_entity[entity_key]
            [#snapshot.representations_by_entity[entity_key] + 1] = representation
    end
    snapshot.dimension_by_id = index_by(snapshot.dimensions, "id")
    snapshot.metric_by_id = index_by(snapshot.metrics, "id")
    snapshot.fact_by_id = index_by(snapshot.facts, "id")
    snapshot.relationship_by_id = index_by(snapshot.relationships, "id")
    snapshot.unique_keys_by_entity = {}
    for _, unique_key in ipairs(snapshot.unique_keys) do
        local entity_key = key(unique_key.entity_id)
        snapshot.unique_keys_by_entity[entity_key] =
            snapshot.unique_keys_by_entity[entity_key] or {}
        snapshot.unique_keys_by_entity[entity_key][#snapshot.unique_keys_by_entity[entity_key] + 1] =
            unique_key
    end
    snapshot.detached = true
    snapshot.immutable = true
    return snapshot
end

function M.copy(snapshot)
    return clone(snapshot)
end

ESV_CATALOG_SNAPSHOT = M

-- Typed metric planning and strict grain-proof boundary.

local M = {PLAN_VERSION = 10}
local graph = assert(ESV_GRAIN_GRAPH, "shared grain graph runtime is required")

local function key(value) return tostring(value) end
local function upper(value) return string.upper(tostring(value or "")) end
local function missing(value)
    return value == nil or value == null or type(value) == "userdata"
        or tostring(value) == ""
end

local function sorted_keys(values)
    local out = {}
    for value_key, present in pairs(values or {}) do
        if present then out[#out + 1] = value_key end
    end
    table.sort(out)
    return out
end

local function classification(metric)
    local kind = upper(metric.metric_kind or metric.metric_type)
    local aggregate = upper(metric.aggregation_function)
    local expression = upper(metric.expression)
    if not missing(metric.window_spec_json) or kind == "WINDOW" then
        return "UNSUPPORTED_WINDOW"
    end
    if not missing(metric.distinct_key_expr) or aggregate == "COUNT_DISTINCT"
        or string.find(expression, "DISTINCT", 1, true) then
        return "UNSUPPORTED_DISTINCT"
    end
    if not missing(metric.non_additive_dimension_id) then
        return "UNSUPPORTED_NON_ADDITIVE"
    end
    if aggregate == "SUM" or string.match(expression, "^%s*SUM%s*%(") then
        return (#(metric.filters or {}) > 0 or not missing(metric.filter_expr))
            and "FILTERED_SUM" or "SUM"
    end
    if aggregate == "COUNT" or string.match(expression, "^%s*COUNT%s*%(") then
        return (#(metric.filters or {}) > 0 or not missing(metric.filter_expr))
            and "FILTERED_COUNT" or "COUNT"
    end
    if kind == "RATIO" or string.find(expression, "/", 1, true) then return "RATIO" end
    if kind == "DERIVED" or kind == "CALCULATED" then return "DERIVED_ARITHMETIC" end
    return "LEGACY_AGGREGATE"
end

local function authoritative_inputs(metric)
    local source = metric.inputs or {}
    local source_kind = "STRUCTURED_INPUTS"
    if #source == 0 then
        source = metric.dependencies or {}
        source_kind = "DEPENDENCY_FALLBACK"
    end
    local inputs = {}
    local seen = {}
    for index, input in ipairs(source) do
        local object_type = upper(input.object_type)
        local object_id = input.object_id
        local role = input.role or input.input_role
        local signature = object_type .. ":" .. key(object_id) .. ":" .. upper(role)
        if not seen[signature] then
            seen[signature] = true
            inputs[#inputs + 1] = {
                object_type = object_type,
                object_id = object_id,
                role = role,
                ordinal_position = input.ordinal_position or index,
                expression_alias = input.expression_alias,
                filter_expr = input.filter_expr,
            }
        end
    end
    return inputs, source_kind
end

local function state_spec(state_class, data_type)
    if state_class == "SUM" or state_class == "FILTERED_SUM" then
        return {
            state_kind = "SUM",
            merge_operator = "SUM",
            data_type = data_type,
            empty_behavior = "NULL",
        }
    end
    if state_class == "COUNT" or state_class == "FILTERED_COUNT" then
        return {
            state_kind = "COUNT",
            merge_operator = "SUM",
            data_type = data_type,
            empty_behavior = "ZERO",
        }
    end
    return nil
end

function M.build_dag(snapshot, selected_metrics)
    local nodes = {}
    local node_by_id = {}
    local metric_by_id = snapshot.metric_by_id or {}
    local fact_by_id = snapshot.fact_by_id or {}
    local visiting = {}
    local visited = {}
    local diagnostics = {}

    local function fact_node(fact)
        local node_id = "fact:" .. key(fact.id)
        if node_by_id[node_id] == nil then
            local node = {
                node_id = node_id,
                node_kind = "FACT_INPUT",
                fact_id = fact.id,
                name = fact.name,
                entity_id = fact.entity_id,
                data_type = fact.data_type,
            }
            nodes[#nodes + 1] = node
            node_by_id[node_id] = node
        end
        return node_by_id[node_id]
    end

    local function visit(metric)
        local metric_key = key(metric.id)
        local node_id = "metric:" .. metric_key
        if visiting[metric_key] then return nil, "METRIC_DEPENDENCY_CYCLE" end
        if visited[metric_key] then return node_by_id[node_id] end
        visiting[metric_key] = true

        local normalized_inputs, input_source = authoritative_inputs(metric)
        local inputs = {}
        local leaf_set = {}
        for _, input in ipairs(normalized_inputs) do
            if input.object_type == "METRIC" then
                local dependency = metric_by_id[key(input.object_id)]
                if dependency == nil then return nil, "MISSING_PRIVATE_METRIC_DEPENDENCY" end
                local dependency_node, err = visit(dependency)
                if err ~= nil then return nil, err end
                inputs[#inputs + 1] = {
                    kind = "METRIC",
                    id = dependency.id,
                    node_id = dependency_node.node_id,
                    role = input.role,
                    expression_alias = input.expression_alias,
                    filter_expr = input.filter_expr,
                }
                for _, entity_id in ipairs(dependency_node.leaf_entity_ids or {}) do
                    leaf_set[key(entity_id)] = entity_id
                end
            elseif input.object_type == "FACT" then
                local fact = fact_by_id[key(input.object_id)]
                if fact == nil then return nil, "MISSING_FACT_DEPENDENCY" end
                local dependency_node = fact_node(fact)
                inputs[#inputs + 1] = {
                    kind = "FACT",
                    id = fact.id,
                    node_id = dependency_node.node_id,
                    entity_id = fact.entity_id,
                    role = input.role,
                    expression_alias = input.expression_alias,
                    filter_expr = input.filter_expr,
                }
                leaf_set[key(fact.entity_id)] = fact.entity_id
            else
                inputs[#inputs + 1] = {
                    kind = input.object_type,
                    id = input.object_id,
                    role = input.role,
                    expression_alias = input.expression_alias,
                    filter_expr = input.filter_expr,
                }
            end
        end

        local leaf_entities = {}
        for _, entity_key in ipairs(sorted_keys(leaf_set)) do
            leaf_entities[#leaf_entities + 1] = leaf_set[entity_key]
        end
        local state_class = classification(metric)
        local state = state_spec(state_class, metric.data_type)
        local node_kind
        if state ~= nil then
            node_kind = "AGGREGATE_STATE"
        elseif state_class == "RATIO" or state_class == "DERIVED_ARITHMETIC" then
            node_kind = "SCALAR_FINALIZER"
        elseif string.sub(state_class, 1, 12) == "UNSUPPORTED_" then
            node_kind = "UNSUPPORTED"
        else
            node_kind = "LEGACY_AGGREGATE"
        end
        local node = {
            node_id = node_id,
            node_kind = node_kind,
            metric_id = metric.id,
            name = metric.name,
            expression = metric.expression,
            data_type = metric.data_type,
            state_class = state_class,
            aggregation_function = metric.aggregation_function,
            state_spec = state,
            base_entity_id = metric.base_entity_id,
            leaf_entity_ids = leaf_entities,
            inputs = inputs,
            input_source = input_source,
            local_filters = metric.filters or {},
            legacy_filter_expr = metric.filter_expr,
            stage = node_kind == "AGGREGATE_STATE" and "AGGREGATE"
                or (node_kind == "SCALAR_FINALIZER" and "FINALIZE" or "LEGACY"),
        }
        if node_kind == "AGGREGATE_STATE" and #leaf_entities == 0 then
            node.invalid_reason = "METRIC_INPUT_GRAIN_MISSING"
        elseif node_kind == "AGGREGATE_STATE" and #leaf_entities > 1 then
            node.invalid_reason = "METRIC_INPUT_GRAIN_AMBIGUOUS"
        end
        if metric.base_entity_id ~= nil and #leaf_entities > 0 then
            local matches_base = false
            for _, entity_id in ipairs(leaf_entities) do
                if key(entity_id) == key(metric.base_entity_id) then matches_base = true end
            end
            if not matches_base then
                diagnostics[#diagnostics + 1] = {
                    reason_code = "BASE_ENTITY_MISMATCH",
                    metric_id = metric.id,
                    declared_entity_id = metric.base_entity_id,
                    leaf_entity_ids = leaf_entities,
                }
            end
        end
        visiting[metric_key] = nil
        visited[metric_key] = true
        nodes[#nodes + 1] = node
        node_by_id[node_id] = node
        node_by_id[metric_key] = node
        return node
    end

    local selected_node_ids = {}
    for _, metric in ipairs(selected_metrics or {}) do
        local node, err = visit(metric_by_id[key(metric.id)] or metric)
        if err ~= nil then return nil, err end
        selected_node_ids[#selected_node_ids + 1] = node.node_id
    end
    return {
        nodes = nodes,
        node_by_id = node_by_id,
        selected_node_ids = selected_node_ids,
        diagnostics = diagnostics,
    }
end

local function field_ref(field)
    return {
        id = field.id or field.field_id,
        name = field.name or field.field,
        kind = field.kind or field.field_kind,
        entity_id = field.entity_id,
        data_type = field.data_type,
    }
end

function M.bind_query(spec, dimensions, metrics, global_filters, having_filters, relationship_targets)
    local bound = {
        bound_query_version = 1,
        selected_dimensions = {},
        selected_metrics = {},
        global_filters = {},
        having_filters = {},
        relationship_targets = relationship_targets or {},
        order_by = spec.order_by or {},
        limit = spec.limit,
    }
    for _, dimension in ipairs(dimensions or {}) do
        bound.selected_dimensions[#bound.selected_dimensions + 1] = field_ref(dimension)
    end
    for _, metric in ipairs(metrics or {}) do
        bound.selected_metrics[#bound.selected_metrics + 1] = field_ref(metric)
    end
    for _, filter in ipairs(global_filters or {}) do
        bound.global_filters[#bound.global_filters + 1] = {
            scope = "GLOBAL",
            field_id = filter.field_id,
            field = filter.field,
            entity_id = filter.entity_id,
            operator = filter.op,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = filter.data_type,
        }
    end
    for _, filter in ipairs(having_filters or {}) do
        bound.having_filters[#bound.having_filters + 1] = {
            scope = "HAVING",
            metric_id = filter.metric_id,
            metric = filter.metric,
            operator = filter.op,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = filter.data_type,
        }
    end
    return bound
end

local function mapping_has_expression(mapping)
    return not missing(mapping.from_expression) or not missing(mapping.to_expression)
end

local function keys_for(snapshot, entity_id)
    return (snapshot.unique_keys_by_entity or {})[key(entity_id)] or {}
end

local function matching_key(snapshot, relationship, side)
    local mappings = relationship.key_mappings or {}
    for _, mapping in ipairs(mappings) do
        if mapping_has_expression(mapping) then
            return nil, "EXPRESSION_KEY_PROOF_UNSUPPORTED"
        end
    end
    local expression_key_seen = false
    local column_key_seen = false
    for _, unique_key in ipairs(keys_for(snapshot,
        side == "from" and relationship.from_entity_id or relationship.to_entity_id)) do
        local has_expression = false
        for _, column in ipairs(unique_key.columns or {}) do
            if not missing(column.expression) then has_expression = true end
        end
        if has_expression then
            expression_key_seen = true
        else
            column_key_seen = true
            if graph.mapping_matches_key(mappings, side, unique_key) then return unique_key end
        end
    end
    if expression_key_seen and not column_key_seen then
        return nil, "EXPRESSION_KEY_PROOF_UNSUPPORTED"
    end
    return nil, "MISMATCHED_UNIQUE_KEY"
end

local function add_strict_edge(snapshot, edges, rejected, relationship, from_id, to_id, target_side)
    if #(relationship.key_mappings or {}) == 0 then
        rejected[#rejected + 1] = {
            relationship_id = relationship.id,
            from_entity_id = from_id,
            to_entity_id = to_id,
            reason = "MISSING_RELATIONSHIP_KEY_MAPPING",
        }
        return
    end
    local unique_key, reason = matching_key(snapshot, relationship, target_side)
    if unique_key == nil then
        rejected[#rejected + 1] = {
            relationship_id = relationship.id,
            from_entity_id = from_id,
            to_entity_id = to_id,
            reason = reason,
        }
        return
    end
    local from_key = key(from_id)
    edges[from_key] = edges[from_key] or {}
    local edge = {
        from_id = from_id,
        to_id = to_id,
        name = relationship.name,
        relationship = relationship,
        safe = true,
        reason = "OK",
        unique_key_id = unique_key.id,
        mapping_ordinals = {},
    }
    for _, mapping in ipairs(relationship.key_mappings or {}) do
        edge.mapping_ordinals[#edge.mapping_ordinals + 1] = mapping.ordinal_position
    end
    edges[from_key][#edges[from_key] + 1] = edge
end

function M.strict_edges(snapshot)
    local edges = {}
    local rejected = {}
    for _, relationship in ipairs(snapshot.relationships or {}) do
        local cardinality = upper(relationship.cardinality)
        if cardinality == "ONE_TO_ONE" then
            add_strict_edge(snapshot, edges, rejected, relationship,
                relationship.from_entity_id, relationship.to_entity_id, "to")
            add_strict_edge(snapshot, edges, rejected, relationship,
                relationship.to_entity_id, relationship.from_entity_id, "from")
        elseif cardinality == "MANY_TO_ONE" then
            add_strict_edge(snapshot, edges, rejected, relationship,
                relationship.from_entity_id, relationship.to_entity_id, "to")
        elseif cardinality == "ONE_TO_MANY" then
            add_strict_edge(snapshot, edges, rejected, relationship,
                relationship.to_entity_id, relationship.from_entity_id, "from")
        else
            rejected[#rejected + 1] = {
                relationship_id = relationship.id,
                reason = "MANY_TO_MANY_PROOF_UNSUPPORTED",
            }
        end
    end
    return edges, rejected
end

local function proof_json(mode, proof)
    local result = {
        mode = mode,
        status = proof.ok and "PROVEN" or "REJECTED",
        reason = proof.reason,
        candidate_paths = proof.candidate_paths or {},
        edges = {},
    }
    for _, edge in ipairs(proof.edges or {}) do
        result.edges[#result.edges + 1] = {
            relationship_id = edge.relationship and edge.relationship.id,
            relationship_name = edge.name,
            from_entity_id = edge.from_id,
            to_entity_id = edge.to_id,
            unique_key_id = edge.unique_key_id,
            mapping_ordinals = edge.mapping_ordinals or {},
        }
    end
    return result
end

local STABLE_REASONS = {
    MISSING_RELATIONSHIP_KEY_MAPPING = "RELATIONSHIP_MAPPING_MISSING",
    MISMATCHED_UNIQUE_KEY = "RELATIONSHIP_TARGET_NOT_UNIQUE",
    EXPRESSION_KEY_PROOF_UNSUPPORTED = "EXPRESSION_KEY_PROOF_UNSUPPORTED",
    MANY_TO_MANY_PROOF_UNSUPPORTED = "MANY_TO_MANY_UNSUPPORTED",
    AMBIGUOUS_RELATIONSHIP_PATH = "RELATIONSHIP_PATH_AMBIGUOUS",
}

local function strict_edge_exists(edges, edge)
    for _, candidate in ipairs(edges[key(edge.from_id)] or {}) do
        if key(candidate.to_id) == key(edge.to_id)
            and key(candidate.relationship.id) == key(edge.relationship.id) then
            return true
        end
    end
    return false
end

local function direction_reason(edge)
    local relationship = edge.relationship
    local cardinality = upper(relationship.cardinality)
    if cardinality == "MANY_TO_MANY" then return "MANY_TO_MANY_UNSUPPORTED" end
    if cardinality == "MANY_TO_ONE"
        and key(edge.from_id) == key(relationship.to_entity_id) then
        return "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED"
    end
    if cardinality == "ONE_TO_MANY"
        and key(edge.from_id) == key(relationship.from_entity_id) then
        return "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED"
    end
    return nil
end

local function blocking_rejection(rejected, edge)
    for _, item in ipairs(rejected or {}) do
        if key(item.relationship_id) == key(edge.relationship.id)
            and (item.from_entity_id == nil or key(item.from_entity_id) == key(edge.from_id))
            and (item.to_entity_id == nil or key(item.to_entity_id) == key(edge.to_id)) then
            return STABLE_REASONS[item.reason] or item.reason, item
        end
    end
    return direction_reason(edge), nil
end

function M.prove_strict(snapshot, from_id, to_id)
    local edges, rejected = M.strict_edges(snapshot)
    local proof = graph.prove_path(edges, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = true,
        reject_any_ambiguity = true,
    })
    local rendered = proof_json("STRICT_GRAIN", proof)
    rendered.from_entity_id = from_id
    rendered.to_entity_id = to_id
    rendered.rejected_edges = rejected
    if proof.ok then return rendered end
    if proof.reason == "AMBIGUOUS_RELATIONSHIP_PATH" then
        rendered.reason_code = "RELATIONSHIP_PATH_AMBIGUOUS"
        return rendered
    end

    local _, all_edges = graph.build_edges(snapshot.relationships or {},
        {allow_many_to_many = false})
    local attempted = graph.prove_path(all_edges, from_id, to_id, {
        require_safe = false,
        reject_ambiguous = true,
        reject_any_ambiguity = true,
    })
    if attempted.reason == "AMBIGUOUS_RELATIONSHIP_PATH" then
        rendered.reason_code = "RELATIONSHIP_PATH_AMBIGUOUS"
        rendered.candidate_paths = attempted.candidate_paths or {}
        return rendered
    end
    if attempted.ok then
        rendered.attempted_path = graph.path_text(attempted.edges)
        for _, edge in ipairs(attempted.edges) do
            if not strict_edge_exists(edges, edge) then
                local reason_code, detail = blocking_rejection(rejected, edge)
                rendered.reason_code = reason_code or "DIMENSION_NOT_CONFORMED"
                rendered.blocking_edge = {
                    relationship_id = edge.relationship.id,
                    relationship_name = edge.relationship.name,
                    from_entity_id = edge.from_id,
                    to_entity_id = edge.to_id,
                    detail = detail and detail.reason or nil,
                }
                return rendered
            end
        end
    end
    rendered.reason_code = "DIMENSION_NOT_CONFORMED"
    return rendered
end

function M.prove(snapshot, from_id, to_id, mode)
    if upper(mode) == "STRICT_GRAIN" then return M.prove_strict(snapshot, from_id, to_id) end
    local edges = graph.build_edges(snapshot.relationships or {})
    local proof = graph.prove_path(edges, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = true,
    })
    local rendered = proof_json("LEGACY_JOIN", proof)
    rendered.from_entity_id = from_id
    rendered.to_entity_id = to_id
    return rendered
end

local function add_requirement(requirements, seen, target_entity_id, dimension_id,
    dimension_name, scope, metric_id)
    if target_entity_id == nil then return end
    local signature = key(target_entity_id) .. ":" .. key(dimension_id) .. ":"
        .. tostring(scope) .. ":" .. key(metric_id)
    if seen[signature] then return end
    seen[signature] = true
    requirements[#requirements + 1] = {
        target_entity_id = target_entity_id,
        dimension_id = dimension_id,
        dimension_name = dimension_name,
        scope = scope,
        metric_id = metric_id,
    }
end

local function requirement_id(branch_id, requirement)
    return table.concat({
        branch_id,
        "requirement",
        tostring(requirement.scope),
        "entity",
        key(requirement.target_entity_id),
        "dimension",
        key(requirement.dimension_id),
        "metric",
        key(requirement.metric_id),
    }, ":")
end

local function entity_name(snapshot, entity_id)
    local entity = (snapshot.entity_by_id or {})[key(entity_id)]
    return entity and entity.name or nil
end

function M.logical_plan(spec, snapshot, bound_query, selected_metrics, relationship_targets)
    if bound_query == nil or bound_query.selected_dimensions == nil then
        bound_query = M.bind_query(spec, bound_query or {}, selected_metrics or {},
            {}, {}, relationship_targets or {})
    end
    local dag, dag_error = M.build_dag(snapshot, selected_metrics or snapshot.visible_metrics)
    if dag == nil then return nil, dag_error end

    local aggregate_nodes = {}
    local leaf_set = {}
    local failure = nil
    local legacy_state_failure = nil
    for _, node in ipairs(dag.nodes) do
        if node.node_kind == "UNSUPPORTED" or node.node_kind == "LEGACY_AGGREGATE" then
            if legacy_state_failure == nil then
                legacy_state_failure = {
                    reason_code = "METRIC_STATE_UNSUPPORTED",
                    metric_id = node.metric_id,
                    metric = node.name,
                    state_class = node.state_class,
                    aggregation_function = node.aggregation_function,
                    leaf_entity_ids = node.leaf_entity_ids,
                }
            end
            for _, entity_id in ipairs(node.leaf_entity_ids or {}) do
                leaf_set[key(entity_id)] = entity_id
            end
        elseif node.node_kind == "AGGREGATE_STATE" then
            aggregate_nodes[#aggregate_nodes + 1] = node
            if node.invalid_reason ~= nil and failure == nil then
                failure = {
                    reason_code = node.invalid_reason,
                    metric_id = node.metric_id,
                    metric = node.name,
                }
            end
            for _, entity_id in ipairs(node.leaf_entity_ids or {}) do
                leaf_set[key(entity_id)] = entity_id
            end
        end
    end

    local leaf_entities = {}
    for _, entity_key in ipairs(sorted_keys(leaf_set)) do
        leaf_entities[#leaf_entities + 1] = leaf_set[entity_key]
    end
    local has_partitioned_leaf = false
    for _, entity_id in ipairs(leaf_entities) do
        local entity = (snapshot.entity_by_id or {})[key(entity_id)]
        if entity ~= nil and upper(entity.fusion_strategy) == "UNION" then
            has_partitioned_leaf = true
            if legacy_state_failure ~= nil then
                for _, failure_entity_id in ipairs(
                    legacy_state_failure.leaf_entity_ids or {}) do
                    if key(failure_entity_id) == key(entity.id) then
                        legacy_state_failure.entity_id = entity.id
                        legacy_state_failure.entity_name = entity.name
                        legacy_state_failure.fusion_strategy = "UNION"
                        break
                    end
                end
            end
        end
    end
    local plan_kind = (#leaf_entities > 1 or has_partitioned_leaf)
        and "MULTI_BRANCH" or "SINGLE_BRANCH"
    -- Non-mergeable legacy aggregates remain valid on the unchanged
    -- single-branch compatibility renderer. They are rejected when a caller
    -- explicitly requests the strict typed boundary or when multiple leaves
    -- would require state merging.
    if failure == nil and legacy_state_failure ~= nil
        and (plan_kind == "MULTI_BRANCH" or spec.proof_mode == "STRICT_GRAIN") then
        failure = legacy_state_failure
    end
    local plan = {
        plan_version = M.PLAN_VERSION,
        plan_kind = plan_kind,
        query_spec_version = spec.query_spec_version,
        catalog_snapshot_version = snapshot.catalog_snapshot_version,
        bound_query = bound_query,
        proof_mode = plan_kind == "MULTI_BRANCH" and "STRICT_GRAIN" or spec.proof_mode,
        leaf_entity_ids = leaf_entities,
        metric_stages = dag.nodes,
        diagnostics = dag.diagnostics,
        branches = {},
        relationship_proofs = {},
        requested_dimensions = bound_query.selected_dimensions,
        requested_metrics = bound_query.selected_metrics,
        failure = failure,
        fusion_strategy = has_partitioned_leaf and "UNION" or nil,
    }

    local leaf_lookup = {}
    for _, entity_id in ipairs(leaf_entities) do leaf_lookup[key(entity_id)] = true end
    for _, dimension in ipairs(bound_query.selected_dimensions or {}) do
        local entity = (snapshot.entity_by_id or {})[key(dimension.entity_id)]
        if entity ~= nil and upper(entity.fusion_strategy) == "UNION"
            and not leaf_lookup[key(entity.id)] and plan.failure == nil then
            plan.failure = {
                reason_code = "FUSION_PARTITION_DIMENSION_UNSUPPORTED",
                entity_id = entity.id,
                entity_name = entity.name,
                dimension_id = dimension.id,
                dimension = dimension.name,
                usage = "SELECTED_DIMENSION",
            }
        end
    end
    for _, filter in ipairs(bound_query.global_filters or {}) do
        local entity = (snapshot.entity_by_id or {})[key(filter.entity_id)]
        if entity ~= nil and upper(entity.fusion_strategy) == "UNION"
            and not leaf_lookup[key(entity.id)] and plan.failure == nil then
            plan.failure = {
                reason_code = "FUSION_PARTITION_DIMENSION_UNSUPPORTED",
                entity_id = entity.id,
                entity_name = entity.name,
                dimension_id = filter.field_id,
                dimension = filter.field,
                usage = "GLOBAL_FILTER",
            }
        end
    end

    if plan_kind == "MULTI_BRANCH" then
        for _, leaf_entity_id in ipairs(leaf_entities) do
            local branch = {
                branch_id = "branch:" .. key(leaf_entity_id),
                leaf_entity_id = leaf_entity_id,
                leaf_entity_name = entity_name(snapshot, leaf_entity_id),
                state_node_ids = {},
                requirements = {},
                proofs = {},
            }
            for _, node in ipairs(aggregate_nodes) do
                if #node.leaf_entity_ids == 1
                    and key(node.leaf_entity_ids[1]) == key(leaf_entity_id) then
                    branch.state_node_ids[#branch.state_node_ids + 1] = node.node_id
                end
            end
            local requirement_seen = {}
            for _, dimension in ipairs(bound_query.selected_dimensions or {}) do
                add_requirement(branch.requirements, requirement_seen,
                    dimension.entity_id, dimension.id, dimension.name, "SELECTED", nil)
            end
            for _, filter in ipairs(bound_query.global_filters or {}) do
                add_requirement(branch.requirements, requirement_seen,
                    filter.entity_id, filter.field_id, filter.field, "GLOBAL_FILTER", nil)
            end
            for _, node in ipairs(aggregate_nodes) do
                if #node.leaf_entity_ids == 1
                    and key(node.leaf_entity_ids[1]) == key(leaf_entity_id) then
                    for _, filter in ipairs(node.local_filters or {}) do
                        local dimension_id = not missing(filter.required_dimension_id)
                            and filter.required_dimension_id or nil
                        local dimension = dimension_id ~= nil
                            and (snapshot.dimension_by_id or {})[key(dimension_id)] or nil
                        local entity_id = not missing(filter.required_entity_id)
                            and filter.required_entity_id
                            or (dimension and dimension.entity_id)
                        -- A metric-local predicate expressed directly against
                        -- its owning leaf needs no relationship proof. Only a
                        -- semantic dimension dependency adds a branch
                        -- requirement.
                        if not missing(entity_id) then
                            add_requirement(branch.requirements, requirement_seen,
                                entity_id,
                                dimension_id,
                                dimension and dimension.name or nil,
                                "METRIC_LOCAL",
                                node.metric_id)
                        end
                    end
                end
            end
            table.sort(branch.requirements, function(left, right)
                local left_key = key(left.target_entity_id) .. ":" .. key(left.dimension_id)
                    .. ":" .. tostring(left.scope) .. ":" .. key(left.metric_id)
                local right_key = key(right.target_entity_id) .. ":" .. key(right.dimension_id)
                    .. ":" .. tostring(right.scope) .. ":" .. key(right.metric_id)
                return left_key < right_key
            end)
            for _, requirement in ipairs(branch.requirements) do
                requirement.requirement_id = requirement_id(branch.branch_id, requirement)
                local proof = M.prove_strict(snapshot, leaf_entity_id,
                    requirement.target_entity_id)
                proof.proof_id = "proof:" .. requirement.requirement_id
                proof.requirement = requirement
                if proof.status == "PROVEN" and #(proof.edges or {}) > 0 then
                    proof.target_unique_key_id =
                        proof.edges[#proof.edges].unique_key_id
                elseif proof.status ~= "PROVEN" then
                    proof.rejection_id = proof.proof_id .. ":rejection"
                end
                branch.proofs[#branch.proofs + 1] = proof
                plan.relationship_proofs[#plan.relationship_proofs + 1] = proof
                if proof.status ~= "PROVEN" and plan.failure == nil then
                    plan.failure = {
                        reason_code = proof.reason_code or "DIMENSION_NOT_CONFORMED",
                        proof_id = proof.proof_id,
                        rejection_id = proof.rejection_id,
                        branch_id = branch.branch_id,
                        leaf_entity_id = leaf_entity_id,
                        metric_id = requirement.metric_id,
                        dimension_id = requirement.dimension_id,
                        dimension = requirement.dimension_name,
                        blocking_edge = proof.blocking_edge,
                        candidate_paths = proof.candidate_paths,
                    }
                end
            end
            plan.branches[#plan.branches + 1] = branch
        end
        if plan.failure == nil then
            plan.execution = {
                status = "PLANNING_ONLY",
                reason_code = "MULTI_BRANCH_EXECUTION_NOT_ENABLED",
            }
        end
    else
        local root_id = snapshot.object.root_entity_id
        for _, target in ipairs(bound_query.relationship_targets or {}) do
            local proof = M.prove(snapshot, root_id, target.target_entity_id, spec.proof_mode)
            plan.relationship_proofs[#plan.relationship_proofs + 1] = proof
        end
    end
    return plan, nil
end

ESV_METRIC_PLAN = M

-- Typed physical planning for proven multi-branch aggregate-state plans.

local M = {
    VERSION = 6,
    DEFAULT_MAX_BRANCHES = 8,
    DEFAULT_MAX_SQL_BYTES = 1000000,
}

local function key(value) return tostring(value) end
local function upper(value) return string.upper(tostring(value or "")) end
local function missing(value) return value == nil or value == null or tostring(value) == "" end

local function quote_ident(value)
    return '"' .. string.gsub(tostring(value), '"', '""') .. '"'
end

local function quote_qualified(schema_name, object_name)
    return quote_ident(schema_name) .. "." .. quote_ident(object_name)
end

local function sql_string(value)
    return "'" .. string.gsub(tostring(value), "'", "''") .. "'"
end

local function sql_literal(value, data_type)
    if value == nil or value == null then return "NULL" end
    if type(value) == "number" then return tostring(value) end
    if type(value) == "boolean" then return value and "TRUE" or "FALSE" end
    local text = tostring(value)
    local dtype = upper(data_type)
    if string.sub(dtype, 1, 4) == "DATE"
        and string.match(text, "^%d%d%d%d%-%d%d%-%d%d$") then
        return "DATE " .. sql_string(text)
    end
    if string.find(dtype, "TIMESTAMP", 1, true) == 1
        and string.match(text, "^%d%d%d%d%-%d%d%-%d%d") then
        return "TIMESTAMP " .. sql_string(text)
    end
    if string.find(dtype, "DECIMAL", 1, true)
        or string.find(dtype, "INT", 1, true)
        or string.find(dtype, "NUMBER", 1, true)
        or string.find(dtype, "DOUBLE", 1, true) then
        if string.match(text, "^%-?%d+%.?%d*$") then return text end
    end
    return sql_string(text)
end

local function is_text_type(data_type)
    local dtype = upper(data_type)
    return string.find(dtype, "CHAR", 1, true) ~= nil
        or string.find(dtype, "VARCHAR", 1, true) ~= nil
end

local function stable_token(value)
    local token = string.gsub(key(value), "[^%w_]", "_")
    if token == "" then token = "empty" end
    return token
end

local function replace_identifiers(text, replace_fn)
    local out = {}
    local value = tostring(text or "")
    local index = 1
    local in_quote = false
    while index <= #value do
        local char = string.sub(value, index, index)
        if char == "'" then
            out[#out + 1] = char
            local next_char = string.sub(value, index + 1, index + 1)
            if in_quote and next_char == "'" then
                out[#out + 1] = next_char
                index = index + 2
            else
                in_quote = not in_quote
                index = index + 1
            end
        elseif in_quote then
            out[#out + 1] = char
            index = index + 1
        elseif string.match(char, "[A-Za-z_]") then
            local finish = index + 1
            while finish <= #value
                and string.match(string.sub(value, finish, finish), "[A-Za-z0-9_]") do
                finish = finish + 1
            end
            local token = string.sub(value, index, finish - 1)
            out[#out + 1] = replace_fn(token) or token
            index = finish
        else
            out[#out + 1] = char
            index = index + 1
        end
    end
    return table.concat(out)
end

local function sorted_copy(values, field)
    local result = {}
    for _, value in ipairs(values or {}) do result[#result + 1] = value end
    table.sort(result, function(left, right)
        return key(left[field]) < key(right[field])
    end)
    return result
end

local function fail(reason_code, details)
    details = details or {}
    details.reason_code = reason_code
    return nil, details
end

local function source_sql(entity)
    if entity == nil or missing(entity.source_schema) or missing(entity.source_object)
        or missing(entity.alias) then
        return nil
    end
    return quote_qualified(entity.source_schema, entity.source_object)
        .. " " .. tostring(entity.alias)
end

local function predicate_sql(filter, dimension)
    local expression = dimension and dimension.expression
    if missing(expression) then return nil, "DIMENSION_EXPRESSION_MISSING" end
    local operator = upper(filter.operator)
    local rhs = filter.value_sql or sql_literal(filter.value, filter.data_type)
    if operator == "IS NULL" or operator == "IS NOT NULL" then
        return tostring(expression) .. " " .. operator
    end
    if operator == "IN" then
        local values = filter.value
        if type(values) ~= "table" or #values == 0 then
            return nil, "FILTER_VALUE_INVALID"
        end
        local literals = {}
        for _, value in ipairs(values) do
            local literal = sql_literal(value, filter.data_type)
            if is_text_type(filter.data_type) then literal = "UPPER(" .. literal .. ")" end
            literals[#literals + 1] = literal
        end
        local lhs = tostring(expression)
        if is_text_type(filter.data_type) then lhs = "UPPER(" .. lhs .. ")" end
        return lhs .. " IN (" .. table.concat(literals, ", ") .. ")"
    end
    if operator == "BETWEEN" then
        local values = filter.value
        if type(values) ~= "table" or #values ~= 2 then
            return nil, "FILTER_VALUE_INVALID"
        end
        return tostring(expression) .. " BETWEEN "
            .. sql_literal(values[1], filter.data_type) .. " AND "
            .. sql_literal(values[2], filter.data_type)
    end
    if operator == "=" or operator == "!=" or operator == "<>"
        or operator == ">" or operator == ">=" or operator == "<"
        or operator == "<=" or operator == "LIKE" then
        local lhs = tostring(expression)
        if is_text_type(filter.data_type)
            and (operator == "=" or operator == "!=" or operator == "<>"
                or operator == "LIKE") then
            lhs = "UPPER(" .. lhs .. ")"
            rhs = "UPPER(" .. rhs .. ")"
        end
        return lhs .. " " .. operator .. " " .. rhs
    end
    return nil, "FILTER_OPERATOR_UNSUPPORTED"
end

local function state_filter_sql(node)
    local predicates = {}
    for _, filter in ipairs(node.local_filters or {}) do
        local expression = filter.resolved_sql_expr
        if missing(expression) then return nil, "METRIC_FILTER_EXPRESSION_MISSING" end
        predicates[#predicates + 1] = tostring(expression)
    end
    if #predicates == 0 and not missing(node.legacy_filter_expr) then
        predicates[1] = tostring(node.legacy_filter_expr)
    end
    for _, input in ipairs(node.inputs or {}) do
        if not missing(input.filter_expr) then
            predicates[#predicates + 1] = tostring(input.filter_expr)
        end
    end
    if #predicates == 0 then return nil end
    return table.concat(predicates, " AND ")
end

local function state_expression(state, fact_expression, filter_expression)
    local value_expression = tostring(fact_expression)
    if filter_expression ~= nil then
        value_expression = "CASE WHEN (" .. filter_expression .. ") THEN "
            .. value_expression .. " ELSE NULL END"
    end
    if state.state_kind == "SUM" then return "SUM(" .. value_expression .. ")" end
    if state.state_kind == "COUNT" then return "COUNT(" .. value_expression .. ")" end
    return nil
end

local function collect_states(logical_plan, snapshot)
    local states = {}
    local aliases = {}
    for _, node in ipairs(logical_plan.metric_stages or {}) do
        if node.node_kind == "AGGREGATE_STATE" then
            if node.state_spec == nil or missing(node.state_spec.data_type) then
                return fail("METRIC_STATE_TYPE_INCOMPATIBLE", {
                    metric_id = node.metric_id,
                    state_id = node.node_id,
                })
            end
            local fact_input = nil
            for _, input in ipairs(node.inputs or {}) do
                if input.kind == "FACT" then
                    if fact_input ~= nil then
                        return fail("METRIC_INPUT_GRAIN_AMBIGUOUS", {
                            metric_id = node.metric_id,
                            state_id = node.node_id,
                        })
                    end
                    fact_input = input
                end
            end
            local fact = fact_input and (snapshot.fact_by_id or {})[key(fact_input.id)]
            if fact == nil or missing(fact.expression) then
                return fail("PHYSICAL_BINDING_INCOMPLETE", {
                    binding_kind = "FACT_EXPRESSION",
                    metric_id = node.metric_id,
                    fact_id = fact_input and fact_input.id,
                    state_id = node.node_id,
                })
            end
            local state_id = "state:metric:" .. key(node.metric_id)
            local alias = "__esv_s_" .. stable_token(node.metric_id)
            if aliases[alias] ~= nil and aliases[alias] ~= state_id then
                return fail("PHYSICAL_IDENTIFIER_COLLISION", {
                    state_id = state_id,
                    conflicting_state_id = aliases[alias],
                })
            end
            aliases[alias] = state_id
            local filter_expression, filter_error = state_filter_sql(node)
            if filter_error ~= nil then
                return fail("PHYSICAL_BINDING_INCOMPLETE", {
                    binding_kind = "METRIC_FILTER_EXPRESSION",
                    detail = filter_error,
                    metric_id = node.metric_id,
                    state_id = node.node_id,
                })
            end
            states[#states + 1] = {
                state_id = state_id,
                node_id = node.node_id,
                metric_id = node.metric_id,
                metric = node.name,
                leaf_entity_id = node.leaf_entity_ids[1],
                state_kind = node.state_spec.state_kind,
                merge_operator = node.state_spec.merge_operator,
                empty_behavior = node.state_spec.empty_behavior,
                data_type = node.state_spec.data_type,
                source_fact_id = fact.id,
                source_expression = fact.expression,
                filter_expression = filter_expression,
                column_alias = alias,
                placeholder_expression = "CAST(NULL AS "
                    .. tostring(node.state_spec.data_type) .. ")",
            }
        end
    end
    table.sort(states, function(left, right) return left.state_id < right.state_id end)
    for ordinal, state in ipairs(states) do state.ordinal = ordinal end
    return states, nil
end

local function collect_dimensions(logical_plan, snapshot)
    local dimensions = {}
    local aliases = {}
    for _, reference in ipairs(logical_plan.bound_query.selected_dimensions or {}) do
        local dimension = (snapshot.dimension_by_id or {})[key(reference.id)]
        if dimension == nil or missing(dimension.expression) then
            return fail("PHYSICAL_BINDING_INCOMPLETE", {
                binding_kind = "DIMENSION_EXPRESSION",
                dimension_id = reference.id,
            })
        end
        local alias = "__esv_d_" .. stable_token(reference.id)
        if aliases[alias] ~= nil and aliases[alias] ~= key(reference.id) then
            return fail("PHYSICAL_IDENTIFIER_COLLISION", {
                dimension_id = reference.id,
                conflicting_dimension_id = aliases[alias],
            })
        end
        aliases[alias] = key(reference.id)
        dimensions[#dimensions + 1] = {
            dimension_id = reference.id,
            name = reference.name,
            entity_id = dimension.entity_id,
            data_type = dimension.data_type,
            expression = dimension.expression,
            column_alias = alias,
            ordinal = #dimensions + 1,
        }
    end
    return dimensions, nil
end

local function branch_joins(branch, snapshot)
    local joins = {}
    local joined_relationships = {}
    local joined_entities = {[key(branch.leaf_entity_id)] = true}
    for _, proof in ipairs(branch.proofs or {}) do
        for _, proof_edge in ipairs(proof.edges or {}) do
            local relationship = (snapshot.relationship_by_id or {})[
                key(proof_edge.relationship_id)]
            local target = (snapshot.entity_by_id or {})[key(proof_edge.to_entity_id)]
            if relationship == nil or target == nil then
                return fail("PHYSICAL_PROOF_INVALID", {
                    issue = "REFERENCE_MISSING",
                    branch_id = branch.branch_id,
                    proof_id = proof.proof_id,
                    relationship_id = proof_edge.relationship_id,
                })
            end
            if not joined_entities[key(proof_edge.from_entity_id)] then
                return fail("PHYSICAL_PROOF_INVALID", {
                    issue = "PATH_DISCONNECTED",
                    branch_id = branch.branch_id,
                    proof_id = proof.proof_id,
                    relationship_id = proof_edge.relationship_id,
                })
            end
            if not joined_relationships[key(relationship.id)] then
                local target_sql = source_sql(target)
                if target_sql == nil or missing(relationship.join_condition) then
                    return fail("PHYSICAL_BINDING_INCOMPLETE", {
                        binding_kind = "RELATIONSHIP_JOIN",
                        branch_id = branch.branch_id,
                        relationship_id = relationship.id,
                    })
                end
                joins[#joins + 1] = {
                    join_id = "join:relationship:" .. key(relationship.id),
                    relationship_id = relationship.id,
                    from_entity_id = proof_edge.from_entity_id,
                    to_entity_id = proof_edge.to_entity_id,
                    join_type = upper(relationship.join_type or "LEFT"),
                    target_sql = target_sql,
                    condition = relationship.join_condition,
                }
                joined_relationships[key(relationship.id)] = true
                joined_entities[key(proof_edge.to_entity_id)] = true
            end
        end
    end
    return joins, nil
end

local function global_predicates(logical_plan, snapshot)
    local predicates = {}
    for _, filter in ipairs(logical_plan.bound_query.global_filters or {}) do
        local dimension = (snapshot.dimension_by_id or {})[key(filter.field_id)]
        local expression, reason = predicate_sql(filter, dimension)
        if expression == nil then
            return fail("PHYSICAL_FILTER_INVALID", {
                issue = reason,
                dimension_id = filter.field_id,
            })
        end
        predicates[#predicates + 1] = {
            filter_id = "global-filter:dimension:" .. key(filter.field_id)
                .. ":" .. key(#predicates + 1),
            dimension_id = filter.field_id,
            expression = expression,
            operator = filter.operator,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = filter.data_type,
        }
    end
    return predicates, nil
end

local function metric_column_alias(metric_id)
    return "__esv_m_" .. stable_token(metric_id)
end

local function qualified_column(source_alias, column_alias)
    return tostring(source_alias) .. "." .. quote_ident(column_alias)
end

local function collect_finalization(logical_plan, states, dimensions, options)
    local finalization = {
        base = {
            cte_id = "cte:metrics:0",
            cte_alias = "__esv_metrics_0",
            source_alias = "ms",
            metric_columns = {},
        },
        layers = {},
        outputs = {dimensions = {}, metrics = {}},
        having_predicates = {},
        order_by = options.output_order_by or {},
        limit = options.limit,
    }
    local metric_columns = {}
    local metric_names = {}
    for _, state in ipairs(states) do
        local column_alias = metric_column_alias(state.metric_id)
        local state_reference = qualified_column(finalization.base.source_alias,
            state.column_alias)
        local expression = state_reference
        if state.empty_behavior == "ZERO" then
            expression = "COALESCE(" .. state_reference .. ", 0)"
        end
        local column = {
            metric_id = state.metric_id,
            metric = state.metric,
            data_type = state.data_type,
            column_alias = column_alias,
            expression = expression,
            source_state_id = state.state_id,
            empty_behavior = state.empty_behavior,
        }
        finalization.base.metric_columns[#finalization.base.metric_columns + 1] = column
        metric_columns[key(state.metric_id)] = column
        metric_names[upper(state.metric)] = column
    end

    local previous_cte_alias = finalization.base.cte_alias
    local layer_ordinal = 0
    for _, node in ipairs(logical_plan.metric_stages or {}) do
        if node.node_kind == "SCALAR_FINALIZER" then
            for _, input in ipairs(node.inputs or {}) do
                if input.kind == "METRIC" and metric_columns[key(input.id)] == nil then
                    return fail("PHYSICAL_FINALIZER_INVALID", {
                        issue = "DEPENDENCY_NOT_AVAILABLE",
                        metric_id = node.metric_id,
                        dependency_metric_id = input.id,
                    })
                end
            end
            if missing(node.expression) then
                return fail("PHYSICAL_FINALIZER_INVALID", {
                    issue = "EXPRESSION_MISSING",
                    metric_id = node.metric_id,
                })
            end
            layer_ordinal = layer_ordinal + 1
            local source_alias = "p"
            local input_aliases = {}
            for _, input in ipairs(node.inputs or {}) do
                if input.kind == "METRIC" and not missing(input.expression_alias) then
                    input_aliases[upper(input.expression_alias)] =
                        metric_columns[key(input.id)]
                end
            end
            local expression = replace_identifiers(node.expression, function(token)
                local dependency = input_aliases[upper(token)]
                    or metric_names[upper(token)]
                if dependency ~= nil then
                    return "(" .. qualified_column(source_alias,
                        dependency.column_alias) .. ")"
                end
                return nil
            end)
            local column = {
                metric_id = node.metric_id,
                metric = node.name,
                data_type = node.data_type,
                column_alias = metric_column_alias(node.metric_id),
                expression = expression,
            }
            local layer = {
                layer_id = "finalizer:metric:" .. key(node.metric_id),
                cte_id = "cte:metrics:" .. key(layer_ordinal),
                cte_alias = "__esv_metrics_" .. key(layer_ordinal),
                input_cte_alias = previous_cte_alias,
                source_alias = source_alias,
                metric_column = column,
            }
            finalization.layers[#finalization.layers + 1] = layer
            previous_cte_alias = layer.cte_alias
            metric_columns[key(node.metric_id)] = column
            metric_names[upper(node.name)] = column
        end
    end
    finalization.result_cte_alias = previous_cte_alias
    finalization.result_source_alias = "f"

    for _, dimension in ipairs(dimensions) do
        finalization.outputs.dimensions[#finalization.outputs.dimensions + 1] = {
            dimension_id = dimension.dimension_id,
            name = dimension.name,
            source_expression = qualified_column(finalization.result_source_alias,
                dimension.column_alias),
            output_alias = dimension.name,
        }
    end
    for _, reference in ipairs(logical_plan.bound_query.selected_metrics or {}) do
        local column = metric_columns[key(reference.id)]
        if column == nil then
            return fail("PHYSICAL_FINALIZER_INVALID", {
                issue = "OUTPUT_METRIC_NOT_AVAILABLE",
                metric_id = reference.id,
            })
        end
        finalization.outputs.metrics[#finalization.outputs.metrics + 1] = {
            metric_id = reference.id,
            name = reference.name,
            source_expression = qualified_column(finalization.result_source_alias,
                column.column_alias),
            output_alias = reference.name,
        }
    end
    for _, filter in ipairs(logical_plan.bound_query.having_filters or {}) do
        local column = metric_columns[key(filter.metric_id)]
        if column == nil then
            return fail("PHYSICAL_FINALIZER_INVALID", {
                issue = "HAVING_METRIC_NOT_AVAILABLE",
                metric_id = filter.metric_id,
            })
        end
        local expression, reason = predicate_sql(filter, {
            expression = qualified_column(finalization.result_source_alias,
                column.column_alias),
        })
        if expression == nil then
            return fail("PHYSICAL_FILTER_INVALID", {
                issue = reason,
                metric_id = filter.metric_id,
                scope = "HAVING",
            })
        end
        finalization.having_predicates[#finalization.having_predicates + 1] = {
            filter_id = "having:metric:" .. key(filter.metric_id) .. ":"
                .. key(#finalization.having_predicates + 1),
            metric_id = filter.metric_id,
            expression = expression,
        }
    end
    return finalization, nil
end

function M.build(logical_plan, snapshot, options)
    options = options or {}
    if logical_plan == nil or logical_plan.plan_kind ~= "MULTI_BRANCH" then
        return fail("PHYSICAL_MULTI_BRANCH_PLAN_REQUIRED")
    end
    if logical_plan.failure ~= nil then
        return fail("LOGICAL_PLAN_NOT_VALID")
    end
    local branches = sorted_copy(logical_plan.branches, "branch_id")
    local max_branches = tonumber(options.max_branches) or M.DEFAULT_MAX_BRANCHES
    if #branches > max_branches then
        return fail("PLANNER_BRANCH_LIMIT_EXCEEDED", {
            branch_count = #branches,
            branch_limit = max_branches,
        })
    end

    local dimensions, dimension_error = collect_dimensions(logical_plan, snapshot)
    if dimensions == nil then return nil, dimension_error end
    local states, state_error = collect_states(logical_plan, snapshot)
    if states == nil then return nil, state_error end
    local predicates, predicate_error = global_predicates(logical_plan, snapshot)
    if predicates == nil then return nil, predicate_error end

    local physical = {
        physical_plan_version = M.VERSION,
        plan_kind = "MULTI_BRANCH_QUERY",
        logical_plan_version = logical_plan.plan_version,
        dimensions = dimensions,
        states = states,
        global_filters = predicates,
        branches = {},
        union = {
            cte_id = "cte:unioned-states",
            cte_alias = "__esv_unioned_states",
        },
        merge = {
            cte_id = "cte:merged-states",
            cte_alias = "__esv_merged_states",
            group_dimension_ids = {},
            state_ids = {},
        },
        safeguards = {
            branch_count = #branches,
            branch_limit = max_branches,
            sql_size_limit = tonumber(options.max_sql_bytes) or M.DEFAULT_MAX_SQL_BYTES,
        },
        execution = {
            status = "PLANNING_ONLY",
            reason_code = "MULTI_BRANCH_EXECUTION_NOT_ENABLED",
        },
    }
    for _, dimension in ipairs(dimensions) do
        physical.merge.group_dimension_ids[#physical.merge.group_dimension_ids + 1] =
            dimension.dimension_id
    end
    for _, state in ipairs(states) do
        physical.merge.state_ids[#physical.merge.state_ids + 1] = state.state_id
    end

    local finalization, finalization_error = collect_finalization(
        logical_plan, states, dimensions, options)
    if finalization == nil then return nil, finalization_error end
    physical.finalization = finalization

    local branch_aliases = {}
    local state_owner_counts = {}
    for _, state in ipairs(states) do state_owner_counts[state.state_id] = 0 end
    for _, branch in ipairs(branches) do
        local entity = (snapshot.entity_by_id or {})[key(branch.leaf_entity_id)]
        local from_sql = source_sql(entity)
        if from_sql == nil then
            return fail("PHYSICAL_BINDING_INCOMPLETE", {
                binding_kind = "SOURCE",
                branch_id = branch.branch_id,
                leaf_entity_id = branch.leaf_entity_id,
            })
        end
        local joins, join_error = branch_joins(branch, snapshot)
        if joins == nil then return nil, join_error end
        local cte_alias = "__esv_b_" .. stable_token(branch.leaf_entity_id)
        if branch_aliases[cte_alias] ~= nil
            and branch_aliases[cte_alias] ~= branch.branch_id then
            return fail("PHYSICAL_IDENTIFIER_COLLISION", {
                branch_id = branch.branch_id,
                conflicting_branch_id = branch_aliases[cte_alias],
            })
        end
        branch_aliases[cte_alias] = branch.branch_id
        local physical_branch = {
            branch_id = branch.branch_id,
            cte_id = "cte:" .. branch.branch_id,
            cte_alias = cte_alias,
            leaf_entity_id = branch.leaf_entity_id,
            source = {
                source_kind = "BASE",
                entity_id = entity.id,
                entity_name = entity.name,
                representation_id = entity.primary_representation
                    and entity.primary_representation.id or nil,
                representation_name = entity.primary_representation
                    and entity.primary_representation.name or nil,
                physical_schema = entity.source_schema,
                physical_object = entity.source_object,
            },
            from_sql = from_sql,
            joins = joins,
            dimensions = dimensions,
            where_predicates = predicates,
            state_columns = {},
        }
        for _, state in ipairs(states) do
            local column = {
                state_id = state.state_id,
                column_alias = state.column_alias,
                data_type = state.data_type,
                owner = key(state.leaf_entity_id) == key(branch.leaf_entity_id),
                source_fact_id = state.source_fact_id,
                state_kind = state.state_kind,
                filter_expression = state.filter_expression,
            }
            if column.owner then
                state_owner_counts[state.state_id] =
                    state_owner_counts[state.state_id] + 1
                column.expression = state_expression(state, state.source_expression,
                    state.filter_expression)
                if column.expression == nil then
                    return fail("METRIC_STATE_UNSUPPORTED", {
                        branch_id = branch.branch_id,
                        state_id = state.state_id,
                    })
                end
            else
                column.expression = state.placeholder_expression
            end
            physical_branch.state_columns[#physical_branch.state_columns + 1] = column
        end
        physical.branches[#physical.branches + 1] = physical_branch
    end
    for _, state in ipairs(states) do
        if state_owner_counts[state.state_id] ~= 1 then
            return fail("PHYSICAL_BINDING_INCOMPLETE", {
                binding_kind = "STATE_OWNER",
                state_id = state.state_id,
                owner_count = state_owner_counts[state.state_id],
            })
        end
    end
    return physical, nil
end

local function clone(value, seen)
    if type(value) ~= "table" or value == null then return value end
    seen = seen or {}
    if seen[value] ~= nil then return seen[value] end
    local out = {}
    seen[value] = out
    for child_key, child in pairs(value) do out[child_key] = clone(child, seen) end
    return out
end

local function candidate_binding(candidate, attribute_type, attribute_id)
    return (candidate.bindings or {})[attribute_type .. ":" .. key(attribute_id)]
end

local function rebind_partition_predicate(predicate, candidate)
    local binding = candidate_binding(candidate, "DIMENSION", predicate.dimension_id)
    if binding == nil then return predicate, nil end
    local expression, reason = predicate_sql(predicate, {expression = binding.expression})
    if expression == nil then return nil, reason end
    local rebound = clone(predicate)
    rebound.expression = expression
    return rebound, nil
end

-- Expand a grain-proven leaf into disjoint representation partitions. Each
-- partition computes mergeable aggregate state independently; the existing
-- UNION/merge pipeline combines those states without joining partition rows.
function M.apply_partitioned_sources(physical_plan, snapshot)
    local expanded = {}
    local fusion_partitions = {}
    local max_branches = physical_plan.safeguards.branch_limit
    for _, branch in ipairs(physical_plan.branches or {}) do
        local entity = (snapshot.entity_by_id or {})[key(branch.leaf_entity_id)]
        local candidates = entity and entity.fusion_candidates or nil
        if upper(entity and entity.fusion_strategy) ~= "UNION" then
            expanded[#expanded + 1] = branch
        else
            if candidates == nil or #candidates < 2 then
                return fail("FUSION_PARTITION_BINDING_INCOMPLETE", {
                    entity_id = branch.leaf_entity_id,
                })
            end
            for _, candidate in ipairs(candidates) do
                local representation = candidate.representation
                local partition = clone(branch)
                partition.branch_id = branch.branch_id .. ":representation:"
                    .. key(representation.id)
                partition.cte_id = "cte:" .. partition.branch_id
                partition.cte_alias = "__esv_b_" .. stable_token(branch.leaf_entity_id)
                    .. "_r_" .. stable_token(representation.id)
                partition.source = {
                    source_kind = "REPRESENTATION_PARTITION",
                    entity_id = entity.id,
                    entity_name = entity.name,
                    representation_id = representation.id,
                    representation_name = representation.name,
                    physical_schema = representation.source_schema,
                    physical_object = representation.source_object,
                    coverage_predicate = representation.coverage_predicate,
                    valid_from = representation.valid_from,
                    valid_to = representation.valid_to,
                }
                partition.from_sql = quote_qualified(representation.source_schema,
                    representation.source_object) .. " " .. tostring(representation.alias)
                for _, dimension in ipairs(partition.dimensions or {}) do
                    if key(dimension.entity_id) == key(entity.id) then
                        local binding = candidate_binding(candidate, "DIMENSION",
                            dimension.dimension_id)
                        if binding == nil then
                            return fail("FUSION_PARTITION_BINDING_INCOMPLETE", {
                                entity_id = entity.id,
                                representation_id = representation.id,
                                dimension_id = dimension.dimension_id,
                            })
                        end
                        dimension.expression = binding.expression
                    end
                end
                local predicates = {}
                for _, predicate in ipairs(partition.where_predicates or {}) do
                    local rebound, reason = rebind_partition_predicate(predicate, candidate)
                    if rebound == nil then
                        return fail("PHYSICAL_FILTER_INVALID", {
                            branch_id = partition.branch_id,
                            dimension_id = predicate.dimension_id,
                            issue = reason,
                        })
                    end
                    predicates[#predicates + 1] = rebound
                end
                predicates[#predicates + 1] = {
                    filter_id = "coverage:representation:" .. key(representation.id),
                    expression = representation.coverage_predicate,
                    predicate_kind = "COVERAGE",
                }
                partition.where_predicates = predicates
                for _, state_column in ipairs(partition.state_columns or {}) do
                    if state_column.owner then
                        local binding = candidate_binding(candidate, "FACT",
                            state_column.source_fact_id)
                        if binding == nil then
                            return fail("FUSION_PARTITION_BINDING_INCOMPLETE", {
                                entity_id = entity.id,
                                representation_id = representation.id,
                                fact_id = state_column.source_fact_id,
                            })
                        end
                        state_column.expression = state_expression(state_column,
                            binding.expression, state_column.filter_expression)
                    end
                end
                expanded[#expanded + 1] = partition
                fusion_partitions[#fusion_partitions + 1] = {
                    branch_id = partition.branch_id,
                    entity_id = entity.id,
                    representation_id = representation.id,
                    representation_name = representation.name,
                    coverage_predicate = representation.coverage_predicate,
                    valid_from = representation.valid_from,
                    valid_to = representation.valid_to,
                }
            end
        end
    end
    if #expanded > max_branches then
        return fail("PLANNER_BRANCH_LIMIT_EXCEEDED", {
            branch_count = #expanded,
            branch_limit = max_branches,
        })
    end
    physical_plan.branches = expanded
    physical_plan.safeguards.branch_count = #expanded
    if #fusion_partitions > 0 then
        physical_plan.fusion_plan = {
            fusion_plan_version = 1,
            strategy = "UNION",
            partitions = fusion_partitions,
        }
    end
    return physical_plan, nil
end

local function materialized_column_expression(source_alias, column)
    return tostring(source_alias) .. "." .. quote_ident(column.physical_column)
end

-- Rebind only complete, pre-selected leaf sources. The selector is deliberately
-- separate from physical construction so an ineligible candidate leaves the
-- proven base branch byte-for-byte intact.
function M.apply_branch_sources(physical_plan, selections)
    for _, branch in ipairs(physical_plan.branches or {}) do
        local selected = selections and selections[key(branch.branch_id)]
        if selected ~= nil then
            local candidate = selected.candidate
            local source_alias = "mat_" .. stable_token(candidate.materialization_id)
            branch.source = {
                source_kind = "MATERIALIZATION",
                materialization_id = candidate.materialization_id,
                materialization_name = candidate.materialization_name,
                physical_schema = candidate.physical_schema,
                physical_object = candidate.physical_object,
                extra_dimension_count = selected.extra_dimension_count,
            }
            branch.from_sql = quote_qualified(candidate.physical_schema,
                candidate.physical_object) .. " " .. source_alias
            branch.joins = {}

            local rebound_dimensions = {}
            for _, dimension in ipairs(branch.dimensions or {}) do
                local column = selected.dimension_columns[
                    "DIMENSION:" .. key(dimension.dimension_id)]
                if column == nil then
                    return fail("MATERIALIZATION_BINDING_INCOMPLETE", {
                        branch_id = branch.branch_id,
                        dimension_id = dimension.dimension_id,
                    })
                end
                local rebound = {}
                for name, value in pairs(dimension) do rebound[name] = value end
                rebound.expression = materialized_column_expression(source_alias,
                    column)
                rebound.source_column = column.physical_column
                rebound_dimensions[#rebound_dimensions + 1] = rebound
            end
            branch.dimensions = rebound_dimensions

            local rebound_predicates = {}
            for _, predicate in ipairs(branch.where_predicates or {}) do
                local column = selected.dimension_columns[
                    "DIMENSION:" .. key(predicate.dimension_id)]
                if column == nil then
                    return fail("MATERIALIZATION_BINDING_INCOMPLETE", {
                        branch_id = branch.branch_id,
                        dimension_id = predicate.dimension_id,
                        binding_kind = "FILTER_DIMENSION",
                    })
                end
                local expression, reason = predicate_sql(predicate, {
                    expression = materialized_column_expression(source_alias,
                        column),
                })
                if expression == nil then
                    return fail("PHYSICAL_FILTER_INVALID", {
                        branch_id = branch.branch_id,
                        dimension_id = predicate.dimension_id,
                        issue = reason,
                    })
                end
                rebound_predicates[#rebound_predicates + 1] = {
                    filter_id = predicate.filter_id,
                    dimension_id = predicate.dimension_id,
                    expression = expression,
                    operator = predicate.operator,
                    value = predicate.value,
                    value_sql = predicate.value_sql,
                    data_type = predicate.data_type,
                }
            end
            branch.where_predicates = rebound_predicates

            for _, state_column in ipairs(branch.state_columns or {}) do
                if state_column.owner then
                    local column = selected.state_columns[key(state_column.state_id)]
                    if column == nil then
                        return fail("MATERIALIZATION_BINDING_INCOMPLETE", {
                            branch_id = branch.branch_id,
                            state_id = state_column.state_id,
                            binding_kind = "STATE_COLUMN",
                        })
                    end
                    state_column.expression = "SUM("
                        .. materialized_column_expression(source_alias, column)
                        .. ")"
                    state_column.source_column = column.physical_column
                    state_column.source_rollup_policy = upper(column.rollup_policy)
                end
            end
        end
    end
    return physical_plan, nil
end

function M.check_sql_size(physical_plan, sql_text)
    local actual = #tostring(sql_text or "")
    physical_plan.safeguards.sql_size_bytes = actual
    if actual > physical_plan.safeguards.sql_size_limit then
        return false, {
            reason_code = "PLANNER_SQL_SIZE_LIMIT_EXCEEDED",
            sql_size_bytes = actual,
            sql_size_limit = physical_plan.safeguards.sql_size_limit,
        }
    end
    return true, nil
end

ESV_PHYSICAL_PLAN = M

-- Decision-free SQL renderer for validated single- and multi-branch plans.

local M = {VERSION = 1}

function M.render_single_branch(plan)
    local sql = {}
    sql[#sql + 1] = "SELECT " .. table.concat(plan.select_parts or {}, ", ")
    sql[#sql + 1] = "FROM " .. tostring(plan.from_sql)
    for _, join_sql in ipairs(plan.join_sql or {}) do sql[#sql + 1] = join_sql end
    if #(plan.where_predicates or {}) > 0 then
        sql[#sql + 1] = "WHERE " .. table.concat(plan.where_predicates, " AND ")
    end
    if #(plan.group_parts or {}) > 0 then
        sql[#sql + 1] = "GROUP BY " .. table.concat(plan.group_parts, ", ")
    end
    if #(plan.having_predicates or {}) > 0 then
        sql[#sql + 1] = "HAVING " .. table.concat(plan.having_predicates, " AND ")
    end
    if #(plan.order_by or {}) > 0 then
        sql[#sql + 1] = "ORDER BY " .. table.concat(plan.order_by, ", ")
    end
    if plan.limit ~= nil then sql[#sql + 1] = "LIMIT " .. tostring(plan.limit) end
    return table.concat(sql, "\n")
end

local function quote_ident(value)
    return '"' .. string.gsub(tostring(value), '"', '""') .. '"'
end

local function render_branch(branch)
    local select_parts = {}
    local group_parts = {}
    for _, dimension in ipairs(branch.dimensions or {}) do
        select_parts[#select_parts + 1] = tostring(dimension.expression)
            .. " AS " .. quote_ident(dimension.column_alias)
        group_parts[#group_parts + 1] = tostring(dimension.expression)
    end
    for _, state in ipairs(branch.state_columns or {}) do
        select_parts[#select_parts + 1] = tostring(state.expression)
            .. " AS " .. quote_ident(state.column_alias)
    end
    local sql = {
        quote_ident(branch.cte_alias) .. " AS (",
        "  SELECT " .. table.concat(select_parts, ", "),
        "  FROM " .. tostring(branch.from_sql),
    }
    for _, join in ipairs(branch.joins or {}) do
        sql[#sql + 1] = "  " .. tostring(join.join_type) .. " JOIN "
            .. tostring(join.target_sql) .. " ON " .. tostring(join.condition)
    end
    local predicates = {}
    for _, predicate in ipairs(branch.where_predicates or {}) do
        predicates[#predicates + 1] = tostring(predicate.expression)
    end
    if #predicates > 0 then
        sql[#sql + 1] = "  WHERE " .. table.concat(predicates, " AND ")
    end
    if #group_parts > 0 then
        sql[#sql + 1] = "  GROUP BY " .. table.concat(group_parts, ", ")
    end
    sql[#sql + 1] = ")"
    return table.concat(sql, "\n")
end

function M.render_multi_branch(plan)
    local ctes = {}
    for _, branch in ipairs(plan.branches or {}) do
        ctes[#ctes + 1] = render_branch(branch)
    end

    local union_columns = {}
    for _, dimension in ipairs(plan.dimensions or {}) do
        union_columns[#union_columns + 1] = quote_ident(dimension.column_alias)
    end
    for _, state in ipairs(plan.states or {}) do
        union_columns[#union_columns + 1] = quote_ident(state.column_alias)
    end
    local union_queries = {}
    for _, branch in ipairs(plan.branches or {}) do
        union_queries[#union_queries + 1] = "  SELECT "
            .. table.concat(union_columns, ", ") .. " FROM "
            .. quote_ident(branch.cte_alias)
    end
    ctes[#ctes + 1] = quote_ident(plan.union.cte_alias) .. " AS (\n"
        .. table.concat(union_queries, "\n  UNION ALL\n") .. "\n)"

    local merge_parts = {}
    local group_parts = {}
    for _, dimension in ipairs(plan.dimensions or {}) do
        local alias = quote_ident(dimension.column_alias)
        merge_parts[#merge_parts + 1] = alias
        group_parts[#group_parts + 1] = alias
    end
    for _, state in ipairs(plan.states or {}) do
        local alias = quote_ident(state.column_alias)
        merge_parts[#merge_parts + 1] = tostring(state.merge_operator)
            .. "(" .. alias .. ") AS " .. alias
    end
    local merge_sql = {
        quote_ident(plan.merge.cte_alias) .. " AS (",
        "  SELECT " .. table.concat(merge_parts, ", "),
        "  FROM " .. quote_ident(plan.union.cte_alias),
    }
    if #group_parts > 0 then
        merge_sql[#merge_sql + 1] = "  GROUP BY " .. table.concat(group_parts, ", ")
    end
    merge_sql[#merge_sql + 1] = ")"
    ctes[#ctes + 1] = table.concat(merge_sql, "\n")

    local finalization = plan.finalization
    if finalization == nil then
        return "WITH\n" .. table.concat(ctes, ",\n")
            .. "\nSELECT * FROM " .. quote_ident(plan.merge.cte_alias)
    end

    local base_parts = {}
    for _, dimension in ipairs(plan.dimensions or {}) do
        local alias = quote_ident(dimension.column_alias)
        base_parts[#base_parts + 1] = tostring(finalization.base.source_alias)
            .. "." .. alias .. " AS " .. alias
    end
    for _, metric in ipairs(finalization.base.metric_columns or {}) do
        base_parts[#base_parts + 1] = tostring(metric.expression)
            .. " AS " .. quote_ident(metric.column_alias)
    end
    ctes[#ctes + 1] = quote_ident(finalization.base.cte_alias) .. " AS (\n"
        .. "  SELECT " .. table.concat(base_parts, ", ") .. "\n"
        .. "  FROM " .. quote_ident(plan.merge.cte_alias) .. " "
        .. tostring(finalization.base.source_alias) .. "\n)"

    for _, layer in ipairs(finalization.layers or {}) do
        ctes[#ctes + 1] = quote_ident(layer.cte_alias) .. " AS (\n"
            .. "  SELECT " .. tostring(layer.source_alias) .. ".*, "
            .. tostring(layer.metric_column.expression) .. " AS "
            .. quote_ident(layer.metric_column.column_alias) .. "\n"
            .. "  FROM " .. quote_ident(layer.input_cte_alias) .. " "
            .. tostring(layer.source_alias) .. "\n)"
    end

    local output_parts = {}
    for _, dimension in ipairs(finalization.outputs.dimensions or {}) do
        output_parts[#output_parts + 1] = tostring(dimension.source_expression)
            .. " AS " .. quote_ident(dimension.output_alias)
    end
    for _, metric in ipairs(finalization.outputs.metrics or {}) do
        output_parts[#output_parts + 1] = tostring(metric.source_expression)
            .. " AS " .. quote_ident(metric.output_alias)
    end
    local final_sql = {
        "SELECT " .. table.concat(output_parts, ", "),
        "FROM " .. quote_ident(finalization.result_cte_alias) .. " "
            .. tostring(finalization.result_source_alias),
    }
    local having = {}
    for _, predicate in ipairs(finalization.having_predicates or {}) do
        having[#having + 1] = tostring(predicate.expression)
    end
    if #having > 0 then
        final_sql[#final_sql + 1] = "WHERE " .. table.concat(having, " AND ")
    end
    if #(finalization.order_by or {}) > 0 then
        final_sql[#final_sql + 1] = "ORDER BY "
            .. table.concat(finalization.order_by, ", ")
    end
    if finalization.limit ~= nil then
        final_sql[#final_sql + 1] = "LIMIT " .. tostring(finalization.limit)
    end
    return "WITH\n" .. table.concat(ctes, ",\n") .. "\n"
        .. table.concat(final_sql, "\n")
end

ESV_GRAIN_SQL = M

local M = {}
local grain_graph = assert(ESV_GRAIN_GRAPH, "shared grain graph runtime is required")
local query_spec_runtime = assert(ESV_QUERY_SPEC, "query spec runtime is required")
local catalog_snapshot_runtime = assert(ESV_CATALOG_SNAPSHOT, "catalog snapshot runtime is required")
local metric_plan_runtime = assert(ESV_METRIC_PLAN, "metric plan runtime is required")
local physical_plan_runtime = assert(ESV_PHYSICAL_PLAN, "physical plan runtime is required")
local grain_sql_runtime = assert(ESV_GRAIN_SQL, "grain SQL runtime is required")

if type(import) == "function" then
    import("SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME", "materializations")
elseif type(exa) == "table" and type(exa.import) == "function" then
    exa.import("SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME", "materializations")
end

local materialization_runtime = materializations

local JSON_NULL = {}
local MAX_LIMIT = 10000

local function missing(value)
    return value == nil or value == null or value == JSON_NULL or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
end

local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return row_value(rows[1], "VALUE", 1) or row_value(rows[1], "COUNT", 1) or row_value(rows[1], "MAX", 1) or rows[1][1]
end

local function null_if_missing(value)
    if missing(value) then
        return null
    end
    return value
end

local function is_array(value)
    if type(value) ~= "table" or value == JSON_NULL then
        return false
    end
    local max_index = 0
    local count = 0
    for k, _ in pairs(value) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
            return false
        end
        if k > max_index then
            max_index = k
        end
        count = count + 1
    end
    return max_index == count
end

local function json_escape(value)
    local text = tostring(value)
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "\n", "\\n")
    text = string.gsub(text, "\r", "\\r")
    text = string.gsub(text, "\t", "\\t")
    return text
end

local function json_encode(value)
    local value_type = type(value)
    if value == nil or value == null or value == JSON_NULL then
        return "null"
    elseif value_type == "string" then
        return '"' .. json_escape(value) .. '"'
    elseif value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "table" then
        local parts = {}
        if is_array(value) then
            for i = 1, #value do
                parts[#parts + 1] = json_encode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, _ in pairs(value) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = json_encode(k) .. ":" .. json_encode(value[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json_encode(tostring(value))
end

local function json_decode(text)
    if missing(text) then
        error("empty JSON payload")
    end
    text = tostring(text)
    local pos = 1

    local function peek()
        return string.sub(text, pos, pos)
    end

    local function skip_ws()
        while pos <= #text do
            local c = peek()
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                return
            end
        end
    end

    local function parse_string()
        if peek() ~= '"' then
            error("expected string at byte " .. tostring(pos))
        end
        pos = pos + 1
        local out = {}
        while pos <= #text do
            local c = peek()
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                local e = string.sub(text, pos + 1, pos + 1)
                if e == '"' or e == "\\" or e == "/" then
                    out[#out + 1] = e
                    pos = pos + 2
                elseif e == "b" then
                    out[#out + 1] = "\b"
                    pos = pos + 2
                elseif e == "f" then
                    out[#out + 1] = "\f"
                    pos = pos + 2
                elseif e == "n" then
                    out[#out + 1] = "\n"
                    pos = pos + 2
                elseif e == "r" then
                    out[#out + 1] = "\r"
                    pos = pos + 2
                elseif e == "t" then
                    out[#out + 1] = "\t"
                    pos = pos + 2
                elseif e == "u" then
                    out[#out + 1] = "?"
                    pos = pos + 6
                else
                    error("invalid escape at byte " .. tostring(pos))
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local parse_value

    local function parse_number()
        local start_pos = pos
        local c = peek()
        if c == "-" then
            pos = pos + 1
        end
        while string.match(peek(), "%d") do
            pos = pos + 1
        end
        if peek() == "." then
            pos = pos + 1
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then
                pos = pos + 1
            end
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        local raw = string.sub(text, start_pos, pos - 1)
        local value = tonumber(raw)
        if value == nil then
            error("invalid number at byte " .. tostring(start_pos))
        end
        return value
    end

    local function parse_array()
        pos = pos + 1
        local out = {}
        skip_ws()
        if peek() == "]" then
            pos = pos + 1
            return out
        end
        while true do
            out[#out + 1] = parse_value()
            skip_ws()
            local c = peek()
            if c == "]" then
                pos = pos + 1
                return out
            elseif c == "," then
                pos = pos + 1
            else
                error("expected array comma or close at byte " .. tostring(pos))
            end
        end
    end

    local function parse_object()
        pos = pos + 1
        local out = {}
        skip_ws()
        if peek() == "}" then
            pos = pos + 1
            return out
        end
        while true do
            skip_ws()
            local name = parse_string()
            skip_ws()
            if peek() ~= ":" then
                error("expected object colon at byte " .. tostring(pos))
            end
            pos = pos + 1
            out[name] = parse_value()
            skip_ws()
            local c = peek()
            if c == "}" then
                pos = pos + 1
                return out
            elseif c == "," then
                pos = pos + 1
            else
                error("expected object comma or close at byte " .. tostring(pos))
            end
        end
    end

    function parse_value()
        skip_ws()
        local c = peek()
        if c == '"' then
            return parse_string()
        elseif c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == "-" or string.match(c, "%d") then
            return parse_number()
        elseif string.sub(text, pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif string.sub(text, pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif string.sub(text, pos, pos + 3) == "null" then
            pos = pos + 4
            return JSON_NULL
        end
        error("unexpected JSON token at byte " .. tostring(pos))
    end

    local value = parse_value()
    skip_ws()
    if pos <= #text then
        error("unexpected trailing JSON at byte " .. tostring(pos))
    end
    return value
end

local function quote_ident(name)
    local text = tostring(name)
    text = string.gsub(text, '"', '""')
    return '"' .. text .. '"'
end

local function quote_qualified(schema_name, object_name)
    return quote_ident(schema_name) .. "." .. quote_ident(object_name)
end

local function quote_column(alias, column_name)
    return tostring(alias) .. "." .. quote_ident(column_name)
end

local function quote_alias(name)
    return quote_ident(name)
end

local function sql_string(value)
    local text = tostring(value)
    text = string.gsub(text, "'", "''")
    return "'" .. text .. "'"
end

local function sql_literal(value, data_type)
    if value == JSON_NULL or value == nil or value == null then
        return "NULL"
    end
    local value_type = type(value)
    if value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "TRUE" or "FALSE"
    end
    local text = tostring(value)
    local dtype = upper(data_type or "")
    if string.sub(dtype, 1, 4) == "DATE" and string.match(text, "^%d%d%d%d%-%d%d%-%d%d$") then
        return "DATE " .. sql_string(text)
    end
    if string.find(dtype, "TIMESTAMP", 1, true) == 1 and string.match(text, "^%d%d%d%d%-%d%d%-%d%d") then
        return "TIMESTAMP " .. sql_string(text)
    end
    if string.find(dtype, "DECIMAL", 1, true) or string.find(dtype, "INT", 1, true) or string.find(dtype, "NUMBER", 1, true) or string.find(dtype, "DOUBLE", 1, true) then
        if string.match(text, "^%-?%d+%.?%d*$") then
            return text
        end
    end
    return sql_string(text)
end

local function is_text_type(data_type)
    local dtype = upper(data_type or "")
    return string.find(dtype, "CHAR", 1, true) ~= nil
        or string.find(dtype, "CLOB", 1, true) ~= nil
        or string.find(dtype, "VARCHAR", 1, true) ~= nil
end

local function as_array(value, field_name)
    if missing(value) then
        return {}
    end
    if not is_array(value) then
        error(field_name .. " must be an array")
    end
    return value
end

local function normalize_name(value, label)
    if missing(value) then
        error(label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("invalid " .. label .. ": " .. name)
    end
    return name
end

local function boolish(value)
    return value == true or tostring(value) == "true" or tostring(value) == "TRUE" or tostring(value) == "1"
end

local function error_result(code, message, clarification)
    return {
        status = clarification and "NEEDS_CLARIFICATION" or "ERROR",
        error_code = code,
        error_message = message,
        generated_sql = nil,
        plan_json = nil,
        clarification_json = clarification and json_encode(clarification) or nil,
        validation_run_id = nil,
        agent_request_id = nil,
        query_log_id = nil,
    }
end

local function unchanged_result(sql_text)
    return {
        status = "UNCHANGED",
        error_code = nil,
        error_message = nil,
        generated_sql = sql_text,
        plan_json = nil,
        clarification_json = nil,
        validation_run_id = nil,
        agent_request_id = nil,
        query_log_id = nil,
    }
end

local function recode_error_prefix(result, prefix)
    if type(result) == "table" and type(result.error_code) == "string" then
        result.error_code = string.gsub(result.error_code, "^SEMANTIC_REQUEST", prefix)
    end
    return result
end

local function plan_materialization_name(plan)
    if type(plan) ~= "table" then
        return nil
    end
    if type(plan.selected_materializations) == "table"
        and #plan.selected_materializations > 0 then
        local names = {}
        for _, selected in ipairs(plan.selected_materializations) do
            names[#names + 1] = tostring(selected.materialization_name)
        end
        return table.concat(names, ",")
    end
    if plan.selected_materialization == nil
        or plan.selected_materialization == JSON_NULL then
        return nil
    elseif type(plan.selected_materialization) == "table" then
        return plan.selected_materialization.materialization_name
    end
    return tostring(plan.selected_materialization)
end

local function typed_failure_message(failure)
    local reason = failure.reason_code or "TYPED_PLANNING_FAILED"
    if reason == "METRIC_STATE_UNSUPPORTED" then
        local metric_name = tostring(failure.metric or failure.metric_id or "unknown")
        local aggregate = tostring(failure.aggregation_function
            or failure.state_class or "unknown aggregate")
        if failure.entity_name ~= nil then
            return "Metric '" .. metric_name .. "' uses " .. aggregate
                .. ", which has no mergeable aggregate state; entity '"
                .. tostring(failure.entity_name)
                .. "' is partitioned (F3 supports SUM and COUNT). Remove the metric "
                .. "from this request or express it using mergeable SUM/COUNT states."
        end
        return "Metric '" .. metric_name .. "' uses " .. aggregate
            .. ", which has no mergeable aggregate state for strict typed planning."
    end
    if reason == "FUSION_PARTITION_DIMENSION_UNSUPPORTED" then
        local dimension_name = tostring(failure.dimension
            or failure.dimension_id or "unknown")
        local usage = failure.usage == "GLOBAL_FILTER"
            and "Filter dimension" or "Dimension"
        return usage .. " '" .. dimension_name
            .. "' resolves to partitioned entity '"
            .. tostring(failure.entity_name or failure.entity_id or "unknown")
            .. "', which is used here only as a joined dimension. Partitioned joined "
            .. "dimensions are not supported in F3."
    end
    return "Typed planning failed: " .. tostring(reason) .. "."
end

local function ok_result(sql_text, plan, validation_run_id)
    return {
        status = "OK",
        error_code = nil,
        error_message = nil,
        generated_sql = sql_text,
        plan_json = json_encode(plan),
        clarification_json = nil,
        validation_run_id = validation_run_id,
        agent_request_id = nil,
        query_log_id = nil,
        materialization_used = plan_materialization_name(plan),
    }
end

local function monotonic_ms()
    if os ~= nil and type(os.clock) == "function" then
        return math.floor(os.clock() * 1000 + 0.5)
    end
    return nil
end

local function attach_planning_runtime(result, started_ms)
    local finished_ms = monotonic_ms()
    if result ~= nil and started_ms ~= nil and finished_ms ~= nil then
        result.planning_runtime_ms = math.max(0, finished_ms - started_ms)
    end
    return result
end

-- Compile-result cache (BUG-D-002). The compiler is deterministic per
-- (model_version_id, normalized request), so a successful compile is reused
-- until PUBLISH_MODEL drops cache entries for the model version. The parsed
-- request is canonicalized (strip logging-only fields, sort top-level keys)
-- and hashed with a 64-bit polynomial hash. Collisions in this space are
-- vanishingly improbable for any realistic dashboard workload.

local CACHE_IGNORED_REQUEST_KEYS = {client = true, purpose = true,
    natural_language_text = true, natural_language = true, source = true}

-- COMPILE_REQUEST_JSON is a closed contract. Silently dropping misspelled or
-- future-looking keys is unsafe for autonomous callers: a request can return
-- STATUS=OK while not doing what the caller asked. Keep this list aligned with
-- SEMANTIC_AGENT.COMPILE_REQUEST_SCHEMA_FOR_AGENT.
local STRUCTURED_REQUEST_KEY_NAMES = {
    "client", "dimensions", "filters", "having", "limit", "metrics",
    "model", "natural_language_text", "object", "order_by", "proof_mode",
    "purpose",
}
local STRUCTURED_REQUEST_KEYS = {}
for _, request_key in ipairs(STRUCTURED_REQUEST_KEY_NAMES) do
    STRUCTURED_REQUEST_KEYS[request_key] = true
end

local function validate_structured_request_keys(request)
    local unknown = {}
    for request_key, _ in pairs(request) do
        if type(request_key) ~= "string" or not STRUCTURED_REQUEST_KEYS[request_key] then
            unknown[#unknown + 1] = tostring(request_key)
        end
    end
    if #unknown == 0 then
        return nil
    end
    table.sort(unknown)
    return error_result(
        "SEMANTIC_REQUEST_004",
        "Unknown top-level request key(s): " .. table.concat(unknown, ", ")
            .. ". Allowed keys: " .. table.concat(STRUCTURED_REQUEST_KEY_NAMES, ", ") .. "."
    )
end

local function canonical_value(value)
    if value == nil or value == null or value == JSON_NULL then
        return null
    end
    if type(value) == "table" then
        if is_array(value) then
            local out = {}
            for i = 1, #value do
                out[i] = canonical_value(value[i])
            end
            return out
        end
        local keys = {}
        for k, _ in pairs(value) do
            if type(k) == "string" then
                keys[#keys + 1] = k
            end
        end
        table.sort(keys)
        local out = {}
        for _, k in ipairs(keys) do
            out[k] = canonical_value(value[k])
        end
        return out
    end
    return value
end

local function canonical_request_text(request)
    if type(request) ~= "table" then
        return nil
    end
    local stripped = {}
    for k, v in pairs(request) do
        if type(k) == "string" and not CACHE_IGNORED_REQUEST_KEYS[string.lower(k)] then
            stripped[k] = v
        end
    end
    local ok, encoded = pcall(json_encode, canonical_value(stripped))
    if not ok then
        return nil
    end
    return "plan=" .. tostring(metric_plan_runtime.PLAN_VERSION) .. "|" .. encoded
end

-- 64-bit polynomial hash (two parallel 32-bit polynomials with different bases
-- and primes). Pure Lua 5.1 - no bitwise ops, all arithmetic stays under 2^53
-- so doubles are exact.
local function compile_cache_key(canonical_text)
    if type(canonical_text) ~= "string" or canonical_text == "" then
        return nil
    end
    local h1, h2 = 5381, 0
    for i = 1, #canonical_text do
        local b = string.byte(canonical_text, i)
        h1 = (h1 * 33 + b) % 4294967296
        h2 = (h2 * 31 + b) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local function cache_lookup(model_version_id, cache_key)
    if cache_key == nil or model_version_id == nil then
        return nil
    end
    local rows = query([[
        SELECT GENERATED_SQL, PLAN_JSON, VALIDATION_RUN_ID
        FROM SYS_SEMANTIC.COMPILE_CACHE
        WHERE MODEL_VERSION_ID = :model_version_id
          AND CACHE_KEY = :cache_key
    ]], {model_version_id = model_version_id, cache_key = cache_key})
    if rows == nil or #rows == 0 then
        return nil
    end
    local row = rows[1]
    return {
        generated_sql = row_value(row, "GENERATED_SQL", 1),
        plan_json = row_value(row, "PLAN_JSON", 2),
        validation_run_id = row_value(row, "VALIDATION_RUN_ID", 3),
    }
end

local function cache_store(model_version_id, cache_key, result)
    if cache_key == nil or model_version_id == nil or result == nil
        or result.status ~= "OK" or missing(result.generated_sql) then
        return
    end
    -- Best-effort insert. A PK collision (same model_version_id + cache_key)
    -- means another concurrent compile already wrote this entry, so nothing
    -- to do. A transient transaction collision is also swallowed - the caller
    -- already has the compile result.
    pcall(query, [[
        INSERT INTO SYS_SEMANTIC.COMPILE_CACHE (
          MODEL_VERSION_ID, CACHE_KEY, GENERATED_SQL, PLAN_JSON,
          VALIDATION_RUN_ID, LAST_HIT_AT, HIT_COUNT
        ) VALUES (
          :model_version_id, :cache_key, :generated_sql, :plan_json,
          :validation_run_id, NULL, 0
        )
    ]], {
        model_version_id = model_version_id,
        cache_key = cache_key,
        generated_sql = null_if_missing(result.generated_sql),
        plan_json = null_if_missing(result.plan_json),
        validation_run_id = null_if_missing(result.validation_run_id),
    })
end

local function cache_touch(model_version_id, cache_key)
    if cache_key == nil or model_version_id == nil then
        return
    end
    pcall(query, [[
        UPDATE SYS_SEMANTIC.COMPILE_CACHE
        SET LAST_HIT_AT = CURRENT_TIMESTAMP,
            HIT_COUNT = HIT_COUNT + 1
        WHERE MODEL_VERSION_ID = :model_version_id
          AND CACHE_KEY = :cache_key
    ]], {model_version_id = model_version_id, cache_key = cache_key})
end

local function cached_ok_result(cached)
    -- Reconstruct an ok_result payload from the cached row. plan_json comes
    -- straight from storage. materialization_used is recovered by decoding it.
    local plan = nil
    if not missing(cached.plan_json) then
        local ok, decoded = pcall(json_decode, cached.plan_json)
        if ok then plan = decoded end
    end
    return {
        status = "OK",
        error_code = nil,
        error_message = nil,
        generated_sql = cached.generated_sql,
        plan_json = cached.plan_json,
        clarification_json = nil,
        validation_run_id = cached.validation_run_id,
        agent_request_id = nil,
        query_log_id = nil,
        materialization_used = plan_materialization_name(plan),
        cache_hit = true,
        planning_runtime_ms = 0,
    }
end

local function load_model(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID, mv.VERSION_NUMBER
        FROM SYS_SEMANTIC.MODELS m
        LEFT JOIN SYS_SEMANTIC.MODEL_VERSIONS mv
          ON mv.VERSION_ID = m.ACTIVE_VERSION_ID
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        return nil
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2),
        version_number = row_value(rows[1], "VERSION_NUMBER", 3),
        model_name = model_name,
    }
end

local function validate_model(model)
    local rows = query([[
        EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)
    ]], {model_name = model.model_name})
    local errors = {}
    for _, row in ipairs(rows or {}) do
        if row_value(row, "SEVERITY", 1) == "ERROR" then
            errors[#errors + 1] = {
                code = row_value(row, "RULE_CODE", 4),
                object_type = row_value(row, "OBJECT_TYPE", 2),
                object = row_value(row, "OBJECT_NAME", 3),
                message = row_value(row, "MESSAGE", 5),
            }
        end
    end
    local validation_run_id = scalar([[
        SELECT MAX(VALIDATION_RUN_ID)
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    return errors, validation_run_id
end

local function collect_referenced_validation_objects(ctx, metrics, dimensions)
    local referenced = {
        DIMENSION = {},
        FACT = {},
        METRIC = {},
    }
    for _, dimension in ipairs(dimensions or {}) do
        referenced.DIMENSION[upper(dimension.name)] = true
    end
    local function add_metric(metric, seen)
        local metric_key = key(metric.id)
        if seen[metric_key] then
            return
        end
        seen[metric_key] = true
        referenced.METRIC[upper(metric.name)] = true
        local dep_rows = query([[
            SELECT DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
            FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
            WHERE METRIC_ID = :metric_id
        ]], {metric_id = metric.id})
        for _, row in ipairs(dep_rows or {}) do
            local dep_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 1)
            local dep_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 2)
            if dep_type == "FACT" then
                local fact = ctx.fact_by_id[key(dep_id)]
                if fact ~= nil then
                    referenced.FACT[upper(fact.name)] = true
                end
            elseif dep_type == "METRIC" then
                local dep_metric = (ctx.all_metric_by_id or ctx.metric_by_id)[key(dep_id)]
                if dep_metric ~= nil then
                    add_metric(dep_metric, seen)
                end
            end
        end
    end
    for _, metric in ipairs(metrics or {}) do
        add_metric(metric, {})
    end
    return referenced
end

local function validation_error_applies(error_row, referenced)
    local object_type = upper(error_row.object_type or "")
    local object_name = upper(error_row.object or "")
    if object_type == "DIMENSION" or object_type == "FACT" or object_type == "METRIC" then
        return referenced[object_type] ~= nil and referenced[object_type][object_name] == true
    end
    if object_type == "SYNONYM" then
        return false
    end
    return true
end

local function load_catalog(model, object_name)
    local object_rows = query([[
        SELECT OBJECT_ID, OBJECT_NAME, ROOT_ENTITY_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
          AND STATUS = 'ACTIVE'
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if object_rows == nil or #object_rows == 0 then
        return nil, "SEMANTIC_REQUEST_012", "Semantic object not found: " .. tostring(object_name)
    end

    local ctx = {
        model = model,
        object = {
            id = row_value(object_rows[1], "OBJECT_ID", 1),
            name = row_value(object_rows[1], "OBJECT_NAME", 2),
            root_entity_id = row_value(object_rows[1], "ROOT_ENTITY_ID", 3),
        },
        entities = {},
        representations = {},
        representations_by_entity = {},
        representation_by_id = {},
        entity_by_id = {},
        entity_by_alias = {},
        dimensions = {},
        dimension_by_id = {},
        metrics = {},
        metric_by_id = {},
        all_metrics = {},
        all_metric_by_id = {},
        facts = {},
        fact_by_id = {},
        fact_by_name = {},
        attribute_bindings = {},
        bindings_by_attribute = {},
        attribute_fusion_policies = {},
        fusion_policy_by_attribute = {},
        semantic_identities = {},
        identity_by_id = {},
        identities_by_entity = {},
        identity_bindings = {},
        identity_binding_by_id = {},
        relationships = {},
        relationship_by_id = {},
        unique_keys = {},
        unique_key_by_id = {},
        unique_keys_by_entity = {},
        relationship_identity_remaps = {},
        relationship_candidate_rejections = {},
        canonical_fields = {},
        synonym_fields = {},
    }

    local entity_rows = query([[
        SELECT e.ENTITY_ID, e.ENTITY_NAME,
               er.SOURCE_SCHEMA, er.SOURCE_OBJECT, er.SOURCE_ALIAS,
               e.PRIMARY_KEY_EXPR, e.GRAIN_DESCRIPTION,
               er.REPRESENTATION_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.REPRESENTATION_ROLE, er.PRIORITY
        FROM SYS_SEMANTIC.ENTITIES e
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        ORDER BY e.ENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local entity = {
            id = row_value(row, "ENTITY_ID", 1),
            name = row_value(row, "ENTITY_NAME", 2),
            source_schema = row_value(row, "SOURCE_SCHEMA", 3),
            source_object = row_value(row, "SOURCE_OBJECT", 4),
            alias = row_value(row, "SOURCE_ALIAS", 5),
            primary_key_expr = row_value(row, "PRIMARY_KEY_EXPR", 6),
            grain_description = row_value(row, "GRAIN_DESCRIPTION", 7),
            primary_representation = {
                id = row_value(row, "REPRESENTATION_ID", 8),
                entity_id = row_value(row, "ENTITY_ID", 1),
                name = row_value(row, "REPRESENTATION_NAME", 9),
                source_kind = row_value(row, "SOURCE_KIND", 10) or "RELATION",
                role = row_value(row, "REPRESENTATION_ROLE", 11) or "PRIMARY",
                priority = row_value(row, "PRIORITY", 12) or 1,
                source_schema = row_value(row, "SOURCE_SCHEMA", 3),
                source_object = row_value(row, "SOURCE_OBJECT", 4),
                alias = row_value(row, "SOURCE_ALIAS", 5),
            },
        }
        ctx.entities[#ctx.entities + 1] = entity
        ctx.entity_by_id[key(entity.id)] = entity
        ctx.entity_by_alias[upper(entity.alias)] = entity
    end

    local representation_rows = query([[
        SELECT er.REPRESENTATION_ID, er.ENTITY_ID, er.REPRESENTATION_NAME,
               er.SOURCE_KIND, er.SOURCE_SCHEMA, er.SOURCE_OBJECT,
               er.SOURCE_ALIAS, er.REPRESENTATION_ROLE, er.PRIORITY,
               er.FRESHNESS_POLICY, er.COVERAGE_PREDICATE, er.VALID_FROM,
               er.VALID_TO, COALESCE(ra.AUTHORITY_ROLE, 'PREFER') AS AUTHORITY_ROLE
        FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
        LEFT JOIN SYS_SEMANTIC.REPRESENTATION_AUTHORITIES ra
          ON ra.MODEL_ID = er.MODEL_ID AND ra.VERSION_ID = er.VERSION_ID
         AND ra.REPRESENTATION_ID = er.REPRESENTATION_ID AND ra.STATUS = 'ACTIVE'
        WHERE er.MODEL_ID = :model_id
          AND er.VERSION_ID = :version_id
          AND er.STATUS = 'ACTIVE'
        ORDER BY er.ENTITY_ID,
          CASE WHEN er.REPRESENTATION_ROLE = 'PRIMARY' THEN 0 ELSE 1 END,
          er.PRIORITY, er.REPRESENTATION_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(representation_rows or {}) do
        local representation = {
            id = row_value(row, "REPRESENTATION_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "REPRESENTATION_NAME", 3),
            source_kind = row_value(row, "SOURCE_KIND", 4),
            source_schema = row_value(row, "SOURCE_SCHEMA", 5),
            source_object = row_value(row, "SOURCE_OBJECT", 6),
            alias = row_value(row, "SOURCE_ALIAS", 7),
            role = row_value(row, "REPRESENTATION_ROLE", 8),
            priority = row_value(row, "PRIORITY", 9),
            freshness_policy = row_value(row, "FRESHNESS_POLICY", 10),
            coverage_predicate = row_value(row, "COVERAGE_PREDICATE", 11),
            valid_from = row_value(row, "VALID_FROM", 12),
            valid_to = row_value(row, "VALID_TO", 13),
            authority_role = row_value(row, "AUTHORITY_ROLE", 14) or "PREFER",
        }
        ctx.representations[#ctx.representations + 1] = representation
        ctx.representation_by_id[key(representation.id)] = representation
        local entity_key = key(representation.entity_id)
        ctx.representations_by_entity[entity_key] =
            ctx.representations_by_entity[entity_key] or {}
        ctx.representations_by_entity[entity_key]
            [#ctx.representations_by_entity[entity_key] + 1] = representation
        if upper(representation.role) == "PRIMARY" and ctx.entity_by_id[entity_key] ~= nil then
            ctx.entity_by_id[entity_key].primary_representation = representation
        end
    end

    local dimension_rows = query([[
        SELECT d.DIMENSION_ID, d.DIMENSION_NAME, d.ENTITY_ID, d.EXPRESSION,
               d.DATA_TYPE, d.DISPLAY_NAME
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.DIMENSIONS d
          ON d.DIMENSION_ID = oc.OBJECT_REF_ID
        WHERE oc.OBJECT_ID = :object_id
          AND oc.COLUMN_KIND = 'DIMENSION'
          AND oc.IS_VISIBLE = TRUE
          AND d.STATUS = 'ACTIVE'
        ORDER BY oc.ORDINAL_POSITION
    ]], {object_id = ctx.object.id})
    for _, row in ipairs(dimension_rows or {}) do
        local dimension = {
            kind = "DIMENSION",
            id = row_value(row, "DIMENSION_ID", 1),
            name = row_value(row, "DIMENSION_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            display_name = row_value(row, "DISPLAY_NAME", 6),
        }
        ctx.dimensions[#ctx.dimensions + 1] = dimension
        ctx.dimension_by_id[key(dimension.id)] = dimension
        ctx.canonical_fields[upper(dimension.name)] = dimension
    end

    local metric_rows = query([[
        SELECT mt.METRIC_ID, mt.METRIC_NAME, mt.BASE_ENTITY_ID, mt.EXPRESSION,
               COALESCE(mt.SQL_FILTER_EXPR, mt.FILTER_EXPR) AS FILTER_EXPR,
               mt.METRIC_TYPE, mt.DATA_TYPE, mt.DISPLAY_NAME,
               COALESCE(mt.METRIC_KIND, mt.METRIC_TYPE) AS METRIC_KIND,
               mt.AGGREGATION_FUNCTION, mt.MEASURE_EXPR,
               mt.SEMANTIC_FILTER_EXPR, mt.SQL_FILTER_EXPR,
               mt.DISTINCT_KEY_EXPR, mt.NON_ADDITIVE_DIMENSION_ID,
               mt.WINDOW_SPEC_JSON, mt.TYPE_PARAMS_JSON
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = oc.OBJECT_REF_ID
        WHERE oc.OBJECT_ID = :object_id
          AND oc.COLUMN_KIND = 'METRIC'
          AND oc.IS_VISIBLE = TRUE
          AND mt.STATUS = 'ACTIVE'
        ORDER BY oc.ORDINAL_POSITION
    ]], {object_id = ctx.object.id})
    for _, row in ipairs(metric_rows or {}) do
        local metric = {
            kind = "METRIC",
            id = row_value(row, "METRIC_ID", 1),
            name = row_value(row, "METRIC_NAME", 2),
            base_entity_id = row_value(row, "BASE_ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            filter_expr = row_value(row, "FILTER_EXPR", 5),
            metric_type = row_value(row, "METRIC_TYPE", 6),
            data_type = row_value(row, "DATA_TYPE", 7),
            display_name = row_value(row, "DISPLAY_NAME", 8),
            metric_kind = row_value(row, "METRIC_KIND", 9),
            aggregation_function = row_value(row, "AGGREGATION_FUNCTION", 10),
            measure_expr = row_value(row, "MEASURE_EXPR", 11),
            semantic_filter_expr = row_value(row, "SEMANTIC_FILTER_EXPR", 12),
            sql_filter_expr = row_value(row, "SQL_FILTER_EXPR", 13),
            distinct_key_expr = row_value(row, "DISTINCT_KEY_EXPR", 14),
            non_additive_dimension_id = row_value(row, "NON_ADDITIVE_DIMENSION_ID", 15),
            window_spec_json = row_value(row, "WINDOW_SPEC_JSON", 16),
            type_params_json = row_value(row, "TYPE_PARAMS_JSON", 17),
            inputs = {},
            filters = {},
        }
        ctx.metrics[#ctx.metrics + 1] = metric
        ctx.metric_by_id[key(metric.id)] = metric
        ctx.all_metrics[#ctx.all_metrics + 1] = metric
        ctx.all_metric_by_id[key(metric.id)] = metric
        ctx.canonical_fields[upper(metric.name)] = metric
    end

    -- Planner catalog completeness is independent of field visibility.
    -- Private metrics stay absent from canonical_fields while remaining
    -- available for transitive dependency planning.
    local all_metric_rows = query([[
        SELECT METRIC_ID, METRIC_NAME, BASE_ENTITY_ID, EXPRESSION,
               COALESCE(SQL_FILTER_EXPR, FILTER_EXPR) AS FILTER_EXPR,
               METRIC_TYPE, DATA_TYPE, DISPLAY_NAME,
               COALESCE(METRIC_KIND, METRIC_TYPE) AS METRIC_KIND,
               AGGREGATION_FUNCTION, MEASURE_EXPR,
               SEMANTIC_FILTER_EXPR, SQL_FILTER_EXPR,
               DISTINCT_KEY_EXPR, NON_ADDITIVE_DIMENSION_ID,
               WINDOW_SPEC_JSON, TYPE_PARAMS_JSON
        FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY METRIC_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(all_metric_rows or {}) do
        local metric_id = row_value(row, "METRIC_ID", 1)
        if ctx.all_metric_by_id[key(metric_id)] == nil then
            local metric = {
                kind = "METRIC",
                id = metric_id,
                name = row_value(row, "METRIC_NAME", 2),
                base_entity_id = row_value(row, "BASE_ENTITY_ID", 3),
                expression = row_value(row, "EXPRESSION", 4),
                filter_expr = row_value(row, "FILTER_EXPR", 5),
                metric_type = row_value(row, "METRIC_TYPE", 6),
                data_type = row_value(row, "DATA_TYPE", 7),
                display_name = row_value(row, "DISPLAY_NAME", 8),
                metric_kind = row_value(row, "METRIC_KIND", 9),
                aggregation_function = row_value(row, "AGGREGATION_FUNCTION", 10),
                measure_expr = row_value(row, "MEASURE_EXPR", 11),
                semantic_filter_expr = row_value(row, "SEMANTIC_FILTER_EXPR", 12),
                sql_filter_expr = row_value(row, "SQL_FILTER_EXPR", 13),
                distinct_key_expr = row_value(row, "DISTINCT_KEY_EXPR", 14),
                non_additive_dimension_id = row_value(row, "NON_ADDITIVE_DIMENSION_ID", 15),
                window_spec_json = row_value(row, "WINDOW_SPEC_JSON", 16),
                type_params_json = row_value(row, "TYPE_PARAMS_JSON", 17),
                inputs = {},
                filters = {},
                dependencies = {},
                visible = false,
            }
            ctx.all_metrics[#ctx.all_metrics + 1] = metric
            ctx.all_metric_by_id[key(metric.id)] = metric
        end
    end

    local metric_input_rows = query([[
        SELECT mi.METRIC_ID, mi.INPUT_ROLE, mi.INPUT_OBJECT_TYPE,
               mi.INPUT_OBJECT_ID, mi.EXPRESSION_ALIAS, mi.OFFSET_WINDOW,
               mi.FILTER_EXPR, mi.ORDINAL_POSITION
        FROM SYS_SEMANTIC.METRIC_INPUTS mi
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = mi.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY mi.METRIC_ID, mi.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_input_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.inputs[#metric.inputs + 1] = {
                role = row_value(row, "INPUT_ROLE", 2),
                object_type = row_value(row, "INPUT_OBJECT_TYPE", 3),
                object_id = row_value(row, "INPUT_OBJECT_ID", 4),
                expression_alias = row_value(row, "EXPRESSION_ALIAS", 5),
                offset_window = row_value(row, "OFFSET_WINDOW", 6),
                filter_expr = row_value(row, "FILTER_EXPR", 7),
                ordinal_position = row_value(row, "ORDINAL_POSITION", 8),
            }
        end
    end

    local metric_filter_rows = query([[
        SELECT mf.METRIC_ID, mf.FILTER_KIND, mf.FILTER_EXPR,
               mf.RESOLVED_SQL_EXPR, mf.REQUIRED_DIMENSION_ID,
               mf.REQUIRED_ENTITY_ID, mf.ORDINAL_POSITION
        FROM SYS_SEMANTIC.METRIC_FILTERS mf
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = mf.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY mf.METRIC_ID, mf.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_filter_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.filters[#metric.filters + 1] = {
                kind = row_value(row, "FILTER_KIND", 2),
                expression = row_value(row, "FILTER_EXPR", 3),
                resolved_sql_expr = row_value(row, "RESOLVED_SQL_EXPR", 4),
                required_dimension_id = row_value(row, "REQUIRED_DIMENSION_ID", 5),
                required_entity_id = row_value(row, "REQUIRED_ENTITY_ID", 6),
                ordinal_position = row_value(row, "ORDINAL_POSITION", 7),
            }
        end
    end

    local metric_dependency_rows = query([[
        SELECT md.METRIC_ID, md.DEPENDS_ON_OBJECT_TYPE, md.DEPENDS_ON_OBJECT_ID
        FROM SYS_SEMANTIC.METRIC_DEPENDENCIES md
        JOIN SYS_SEMANTIC.METRICS mt ON mt.METRIC_ID = md.METRIC_ID
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
        ORDER BY md.METRIC_ID, md.DEPENDS_ON_OBJECT_TYPE, md.DEPENDS_ON_OBJECT_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(metric_dependency_rows or {}) do
        local metric = ctx.all_metric_by_id[key(row_value(row, "METRIC_ID", 1))]
        if metric ~= nil then
            metric.dependencies = metric.dependencies or {}
            metric.dependencies[#metric.dependencies + 1] = {
                object_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 2),
                object_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 3),
            }
        end
    end

    local fact_rows = query([[
        SELECT FACT_ID, FACT_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE,
               ADDITIVE_POLICY
        FROM SYS_SEMANTIC.FACTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY FACT_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(fact_rows or {}) do
        local fact = {
            id = row_value(row, "FACT_ID", 1),
            name = row_value(row, "FACT_NAME", 2),
            entity_id = row_value(row, "ENTITY_ID", 3),
            expression = row_value(row, "EXPRESSION", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            additive_policy = row_value(row, "ADDITIVE_POLICY", 6),
        }
        ctx.facts[#ctx.facts + 1] = fact
        ctx.fact_by_id[key(fact.id)] = fact
        ctx.fact_by_name[upper(fact.name)] = fact
    end

    local binding_rows = query([[
        SELECT ATTRIBUTE_BINDING_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
               REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
               BINDING_PRIORITY, IS_DEFAULT
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_ID,
          CASE WHEN BINDING_ROLE = 'PREFER' THEN 0 ELSE 1 END,
          BINDING_PRIORITY, ATTRIBUTE_BINDING_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(binding_rows or {}) do
        local binding = {
            id = row_value(row, "ATTRIBUTE_BINDING_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 3),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 4),
            representation_id = row_value(row, "REPRESENTATION_ID", 5),
            expression = row_value(row, "SOURCE_EXPRESSION", 6),
            role = row_value(row, "BINDING_ROLE", 7),
            priority = row_value(row, "BINDING_PRIORITY", 8),
            is_default = row_value(row, "IS_DEFAULT", 9),
            legacy = row_value(row, "IS_DEFAULT", 9) == true,
        }
        ctx.attribute_bindings[#ctx.attribute_bindings + 1] = binding
        local attribute_key = upper(binding.attribute_type) .. ":" .. key(binding.attribute_id)
        ctx.bindings_by_attribute[attribute_key] =
            ctx.bindings_by_attribute[attribute_key] or {}
        ctx.bindings_by_attribute[attribute_key]
            [#ctx.bindings_by_attribute[attribute_key] + 1] = binding
    end

    local fusion_policy_rows = query([[
        SELECT ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID, FUSION_STRATEGY
        FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ATTRIBUTE_TYPE, ATTRIBUTE_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(fusion_policy_rows or {}) do
        local policy = {
            entity_id = row_value(row, "ENTITY_ID", 1),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 2),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 3),
            strategy = row_value(row, "FUSION_STRATEGY", 4),
        }
        local attribute_key = upper(policy.attribute_type) .. ":" .. key(policy.attribute_id)
        ctx.attribute_fusion_policies[#ctx.attribute_fusion_policies + 1] = policy
        ctx.fusion_policy_by_attribute[attribute_key] = policy
    end

    local identity_rows = query([[
        SELECT IDENTITY_ID, ENTITY_ID, IDENTITY_NAME, IDENTITY_KIND, DATA_TYPE
        FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID, IDENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(identity_rows or {}) do
        local identity = {
            id = row_value(row, "IDENTITY_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "IDENTITY_NAME", 3),
            kind = row_value(row, "IDENTITY_KIND", 4),
            data_type = row_value(row, "DATA_TYPE", 5),
            bindings = {},
        }
        ctx.semantic_identities[#ctx.semantic_identities + 1] = identity
        ctx.identity_by_id[key(identity.id)] = identity
        ctx.identities_by_entity[key(identity.entity_id)] =
            ctx.identities_by_entity[key(identity.entity_id)] or {}
        ctx.identities_by_entity[key(identity.entity_id)]
            [#ctx.identities_by_entity[key(identity.entity_id)] + 1] = identity
    end
    local identity_binding_rows = query([[
        SELECT ib.IDENTITY_BINDING_ID, ib.ENTITY_ID, ib.IDENTITY_ID,
               ib.REPRESENTATION_ID, ib.SOURCE_EXPRESSION, ib.BINDING_KIND,
               im.IDENTITY_MAPPING_ID, im.SOURCE_SCHEMA, im.SOURCE_OBJECT,
               im.SOURCE_LOCAL_COLUMN, im.SEMANTIC_KEY_COLUMN,
               im.CERTIFICATION_STATUS
        FROM SYS_SEMANTIC.IDENTITY_BINDINGS ib
        LEFT JOIN SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS im
          ON im.IDENTITY_BINDING_ID = ib.IDENTITY_BINDING_ID
         AND im.STATUS = 'ACTIVE'
        WHERE ib.MODEL_ID = :model_id AND ib.VERSION_ID = :version_id
          AND ib.STATUS = 'ACTIVE'
        ORDER BY ib.IDENTITY_ID, ib.IDENTITY_BINDING_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(identity_binding_rows or {}) do
        local binding = {
            id = row_value(row, "IDENTITY_BINDING_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            identity_id = row_value(row, "IDENTITY_ID", 3),
            representation_id = row_value(row, "REPRESENTATION_ID", 4),
            expression = row_value(row, "SOURCE_EXPRESSION", 5),
            kind = row_value(row, "BINDING_KIND", 6),
            mapping = not missing(row_value(row, "IDENTITY_MAPPING_ID", 7)) and {
                id = row_value(row, "IDENTITY_MAPPING_ID", 7),
                source_schema = row_value(row, "SOURCE_SCHEMA", 8),
                source_object = row_value(row, "SOURCE_OBJECT", 9),
                local_column = row_value(row, "SOURCE_LOCAL_COLUMN", 10),
                semantic_column = row_value(row, "SEMANTIC_KEY_COLUMN", 11),
                certification = row_value(row, "CERTIFICATION_STATUS", 12),
            } or nil,
        }
        ctx.identity_bindings[#ctx.identity_bindings + 1] = binding
        ctx.identity_binding_by_id[key(binding.id)] = binding
        local identity = ctx.identity_by_id[key(binding.identity_id)]
        if identity ~= nil then
            identity.bindings[#identity.bindings + 1] = binding
            identity.binding_by_representation = identity.binding_by_representation or {}
            identity.binding_by_representation[key(binding.representation_id)] = binding
        end
    end

    local relationship_rows = query([[
        SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
               JOIN_CONDITION, RELATIONSHIP_CARDINALITY, JOIN_TYPE, FANOUT_POLICY,
               PATH_PRIORITY
        FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY PATH_PRIORITY, RELATIONSHIP_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(relationship_rows or {}) do
        local relationship = {
            id = row_value(row, "RELATIONSHIP_ID", 1),
            name = row_value(row, "RELATIONSHIP_NAME", 2),
            from_entity_id = row_value(row, "FROM_ENTITY_ID", 3),
            to_entity_id = row_value(row, "TO_ENTITY_ID", 4),
            join_condition = row_value(row, "JOIN_CONDITION", 5),
            cardinality = row_value(row, "RELATIONSHIP_CARDINALITY", 6),
            join_type = row_value(row, "JOIN_TYPE", 7),
            fanout_policy = row_value(row, "FANOUT_POLICY", 8),
            path_priority = row_value(row, "PATH_PRIORITY", 9),
            key_mappings = {},
        }
        ctx.relationships[#ctx.relationships + 1] = relationship
        ctx.relationship_by_id[key(relationship.id)] = relationship
    end

    local mapping_rows = query([[
        SELECT rkm.RELATIONSHIP_ID, rkm.ORDINAL_POSITION,
               rkm.FROM_COLUMN_NAME, rkm.FROM_EXPRESSION,
               rkm.TO_COLUMN_NAME, rkm.TO_EXPRESSION
        FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS rkm
        JOIN SYS_SEMANTIC.RELATIONSHIPS r
          ON r.RELATIONSHIP_ID = rkm.RELATIONSHIP_ID
        WHERE r.MODEL_ID = :model_id
          AND r.VERSION_ID = :version_id
          AND r.STATUS = 'ACTIVE'
        ORDER BY rkm.RELATIONSHIP_ID, rkm.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(mapping_rows or {}) do
        local relationship = ctx.relationship_by_id[key(row_value(row, "RELATIONSHIP_ID", 1))]
        if relationship ~= nil then
            relationship.key_mappings[#relationship.key_mappings + 1] = {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                from_column_name = row_value(row, "FROM_COLUMN_NAME", 3),
                from_expression = row_value(row, "FROM_EXPRESSION", 4),
                to_column_name = row_value(row, "TO_COLUMN_NAME", 5),
                to_expression = row_value(row, "TO_EXPRESSION", 6),
            }
        end
    end

    local unique_key_rows = query([[
        SELECT UNIQUE_KEY_ID, ENTITY_ID, KEY_NAME, KEY_KIND, SOURCE_FORMAT
        FROM SYS_SEMANTIC.UNIQUE_KEYS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID, UNIQUE_KEY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(unique_key_rows or {}) do
        local unique_key = {
            id = row_value(row, "UNIQUE_KEY_ID", 1),
            entity_id = row_value(row, "ENTITY_ID", 2),
            name = row_value(row, "KEY_NAME", 3),
            kind = row_value(row, "KEY_KIND", 4),
            source_format = row_value(row, "SOURCE_FORMAT", 5),
            columns = {},
        }
        ctx.unique_keys[#ctx.unique_keys + 1] = unique_key
        ctx.unique_key_by_id[key(unique_key.id)] = unique_key
        local entity_key = key(unique_key.entity_id)
        ctx.unique_keys_by_entity[entity_key] = ctx.unique_keys_by_entity[entity_key] or {}
        ctx.unique_keys_by_entity[entity_key][#ctx.unique_keys_by_entity[entity_key] + 1] = unique_key
    end

    local unique_key_column_rows = query([[
        SELECT ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION,
               ukc.COLUMN_NAME, ukc.EXPRESSION
        FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS ukc
        JOIN SYS_SEMANTIC.UNIQUE_KEYS uk
          ON uk.UNIQUE_KEY_ID = ukc.UNIQUE_KEY_ID
        WHERE uk.MODEL_ID = :model_id
          AND uk.VERSION_ID = :version_id
          AND uk.STATUS = 'ACTIVE'
        ORDER BY ukc.UNIQUE_KEY_ID, ukc.ORDINAL_POSITION
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(unique_key_column_rows or {}) do
        local unique_key = ctx.unique_key_by_id[key(row_value(row, "UNIQUE_KEY_ID", 1))]
        if unique_key ~= nil then
            unique_key.columns[#unique_key.columns + 1] = {
                ordinal_position = row_value(row, "ORDINAL_POSITION", 2),
                column_name = row_value(row, "COLUMN_NAME", 3),
                expression = row_value(row, "EXPRESSION", 4),
            }
        end
    end
    for _, unique_key in ipairs(ctx.unique_keys) do
        local canonical = grain_graph.canonical_key(unique_key)
        unique_key.columns = canonical.columns
        unique_key.kind = canonical.kind
    end

    local synonym_rows = query([[
        SELECT OBJECT_TYPE, OBJECT_ID, SYNONYM
        FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE IN ('DIMENSION', 'METRIC')
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(synonym_rows or {}) do
        local object_type = row_value(row, "OBJECT_TYPE", 1)
        local object_id = row_value(row, "OBJECT_ID", 2)
        local synonym = upper(row_value(row, "SYNONYM", 3))
        local field = nil
        if object_type == "DIMENSION" then
            field = ctx.dimension_by_id[key(object_id)]
        elseif object_type == "METRIC" then
            field = ctx.metric_by_id[key(object_id)]
        end
        if field ~= nil then
            ctx.synonym_fields[synonym] = ctx.synonym_fields[synonym] or {}
            ctx.synonym_fields[synonym][#ctx.synonym_fields[synonym] + 1] = field
        end
    end

    return ctx
end

local function add_unique(list, seen, item)
    local item_key = item.kind .. ":" .. key(item.id)
    if not seen[item_key] then
        seen[item_key] = true
        list[#list + 1] = item
    end
end

local function resolve_field(ctx, field_name, expected_kind)
    if missing(field_name) then
        return nil, error_result("SEMANTIC_REQUEST_020", "Field name is required.")
    end
    local normalized = upper(trim(field_name))
    local exact = ctx.canonical_fields[normalized]
    if exact ~= nil then
        if expected_kind ~= nil and exact.kind ~= expected_kind then
            return nil, error_result("SEMANTIC_REQUEST_022", "Field " .. tostring(field_name) .. " is not a " .. expected_kind .. ".")
        end
        return exact, nil
    end

    local candidates = ctx.synonym_fields[normalized] or {}
    local filtered = {}
    for _, candidate in ipairs(candidates) do
        if expected_kind == nil or candidate.kind == expected_kind then
            filtered[#filtered + 1] = candidate
        end
    end
    if #filtered == 1 then
        return filtered[1], nil
    elseif #filtered > 1 then
        local names = {}
        for _, candidate in ipairs(filtered) do
            names[#names + 1] = candidate.name
        end
        return nil, error_result("SEMANTIC_REQUEST_021", "Ambiguous semantic field: " .. tostring(field_name), {
            message = "Ambiguous semantic field.",
            field = tostring(field_name),
            candidates = names,
            clarification_question = "Which field did you mean for " .. tostring(field_name) .. "?",
        })
    end
    return nil, error_result("SEMANTIC_REQUEST_020", "Unknown semantic field: " .. tostring(field_name) .. ".")
end

local function relationship_edges(ctx)
    local safe_edges = grain_graph.build_edges(ctx.relationships)
    return safe_edges
end

local function find_path(ctx, from_id, to_id)
    local edges = ctx._edges
    if edges == nil then
        edges = relationship_edges(ctx)
        ctx._edges = edges
    end
    local proof = grain_graph.prove_path(edges, from_id, to_id, {
        require_safe = true,
        reject_ambiguous = true,
    })
    if not proof.ok then
        ctx._last_path_proof = proof
        return nil
    end
    local path = {}
    for _, edge in ipairs(proof.edges) do
        path[#path + 1] = {
            from_entity_id = edge.from_id,
            to_entity_id = edge.to_id,
            relationship = edge.relationship,
        }
    end
    ctx._last_path_proof = proof
    return path
end

local function strip_string_literals(text)
    local out = {}
    local in_quote = false
    local i = 1
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            if in_quote and n == "'" then
                out[#out + 1] = " "
                out[#out + 1] = " "
                i = i + 2
            else
                in_quote = not in_quote
                out[#out + 1] = " "
                i = i + 1
            end
        elseif in_quote then
            out[#out + 1] = " "
            i = i + 1
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function aliases_in_expression(expression)
    local aliases = {}
    if missing(expression) then
        return aliases
    end
    local text = strip_string_literals(tostring(expression))
    for alias in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.") do
        aliases[upper(alias)] = true
    end
    return aliases
end

local function replace_identifiers(text, replace_fn)
    local out = {}
    local i = 1
    local in_quote = false
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            out[#out + 1] = c
            if in_quote and n == "'" then
                out[#out + 1] = n
                i = i + 2
            else
                in_quote = not in_quote
                i = i + 1
            end
        elseif in_quote then
            out[#out + 1] = c
            i = i + 1
        elseif string.match(c, "[A-Za-z_]") then
            local j = i + 1
            while j <= #text and string.match(string.sub(text, j, j), "[A-Za-z0-9_]") do
                j = j + 1
            end
            local token = string.sub(text, i, j - 1)
            out[#out + 1] = replace_fn(token) or token
            i = j
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function collect_metric_entities(ctx, metric, needed_entities, seen_metrics)
    local metric_key = key(metric.id)
    if seen_metrics[metric_key] then
        return
    end
    seen_metrics[metric_key] = true
    needed_entities[key(metric.base_entity_id)] = true
    for alias, _ in pairs(aliases_in_expression(metric.filter_expr)) do
        local entity = ctx.entity_by_alias[alias]
        if entity ~= nil then
            needed_entities[key(entity.id)] = true
        end
    end
    local dep_rows = query([[
        SELECT DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
        FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
        WHERE METRIC_ID = :metric_id
        ORDER BY DEPENDS_ON_OBJECT_TYPE, DEPENDS_ON_OBJECT_ID
    ]], {metric_id = metric.id})
    for _, row in ipairs(dep_rows or {}) do
        local dep_type = row_value(row, "DEPENDS_ON_OBJECT_TYPE", 1)
        local dep_id = row_value(row, "DEPENDS_ON_OBJECT_ID", 2)
        if dep_type == "FACT" then
            local fact = ctx.fact_by_id[key(dep_id)]
            if fact ~= nil then
                needed_entities[key(fact.entity_id)] = true
            end
        elseif dep_type == "METRIC" then
            local dep_metric = (ctx.all_metric_by_id or ctx.metric_by_id)[key(dep_id)]
            if dep_metric ~= nil then
                collect_metric_entities(ctx, dep_metric, needed_entities, seen_metrics)
            end
        end
    end
end

local function collect_metric_facts(ctx, metric, required, seen_metrics)
    local metric_key = key(metric.id)
    if seen_metrics[metric_key] then return end
    seen_metrics[metric_key] = true
    for _, dependency in ipairs(metric.dependencies or {}) do
        if upper(dependency.object_type) == "FACT" then
            local fact = ctx.fact_by_id[key(dependency.object_id)]
            if fact ~= nil then required["FACT:" .. key(fact.id)] = fact end
        elseif upper(dependency.object_type) == "METRIC" then
            local nested = ctx.all_metric_by_id[key(dependency.object_id)]
            if nested ~= nil then collect_metric_facts(ctx, nested, required, seen_metrics) end
        end
    end
end

local function replace_qualified_alias(expression, source_alias, target_alias)
    local source = upper(source_alias)
    local text = tostring(expression)
    local out = {}
    local i = 1
    local in_quote = false
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            out[#out + 1] = c
            if in_quote and n == "'" then
                out[#out + 1] = n
                i = i + 2
            else
                in_quote = not in_quote
                i = i + 1
            end
        elseif not in_quote and string.match(c, "[A-Za-z_]") then
            local j = i + 1
            while j <= #text and string.match(string.sub(text, j, j), "[A-Za-z0-9_]") do
                j = j + 1
            end
            local cursor = j
            while string.match(string.sub(text, cursor, cursor), "%s") do cursor = cursor + 1 end
            local token = string.sub(text, i, j - 1)
            if upper(token) == source and string.sub(text, cursor, cursor) == "." then
                out[#out + 1] = target_alias
            else
                out[#out + 1] = token
            end
            i = j
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

local function physical_unique_key(ctx, entity_id)
    for _, unique_key in ipairs(ctx.unique_keys_by_entity[key(entity_id)] or {}) do
        if #(unique_key.columns or {}) > 0 then
            local physical = true
            for _, column in ipairs(unique_key.columns) do
                if missing(column.column_name) or not missing(column.expression) then
                    physical = false
                    break
                end
            end
            if physical then return unique_key end
        end
    end
    return nil
end

local function complete_semantic_identity(ctx, entity)
    local representations = ctx.representations_by_entity[key(entity.id)] or {}
    for _, identity in ipairs((ctx.identities_by_entity or {})[key(entity.id)] or {}) do
        local complete = #representations > 0
        for _, representation in ipairs(representations) do
            local binding = identity.binding_by_representation
                and identity.binding_by_representation[key(representation.id)] or nil
            if binding == nil or (upper(binding.kind) == "MAPPED"
                and (binding.mapping == nil
                    or upper(binding.mapping.certification) ~= "CERTIFIED")) then
                complete = false
                break
            end
        end
        if complete then return identity end
    end
    return nil
end

local function compiler_source_column_exists(ctx, representation, column_name)
    ctx._source_column_exists = ctx._source_column_exists or {}
    local cache_key = tostring(representation.source_schema) .. "\31"
        .. tostring(representation.source_object) .. "\31" .. tostring(column_name)
    if ctx._source_column_exists[cache_key] ~= nil then
        return ctx._source_column_exists[cache_key]
    end
    local rows = query([[
        SELECT COUNT(*) AS COLUMN_COUNT
        FROM SYS.EXA_ALL_COLUMNS
        WHERE COLUMN_SCHEMA = :schema_name
          AND COLUMN_TABLE = :object_name
          AND COLUMN_NAME = :column_name
    ]], {schema_name = representation.source_schema,
          object_name = representation.source_object,
          column_name = column_name})
    local exists = rows ~= nil and #rows > 0
        and tonumber(row_value(rows[1], "COLUMN_COUNT", 1) or 0) > 0
    ctx._source_column_exists[cache_key] = exists
    return exists
end

local function relationship_candidate(ctx, requirement, entity, representation)
    local relationship = requirement.relationship
    local side = requirement.side
    local mapping = relationship.key_mappings and relationship.key_mappings[1] or nil
    local column_name = mapping and mapping[side .. "_column_name"] or nil
    if missing(column_name) then
        return nil, "relationship endpoint is not a scalar physical column"
    end
    if compiler_source_column_exists(ctx, representation, column_name) then
        return {kind = "PHYSICAL", column_name = column_name}, nil
    end
    if key(representation.id) == key(entity.primary_representation.id) then
        return nil, "primary representation is missing the relationship key column"
    end
    local unique_key, key_error = grain_graph.scalar_mapping_key(
        ctx.unique_keys_by_entity[key(entity.id)] or {},
        relationship.key_mappings or {}, side)
    if unique_key == nil then return nil, key_error end
    local identity = complete_semantic_identity(ctx, entity)
    local remap, remap_error = grain_graph.direct_identity_remap(identity,
        entity.primary_representation, representation, unique_key)
    if remap == nil then return nil, remap_error end
    return {
        kind = "DIRECT_IDENTITY",
        column_name = column_name,
        identity = identity,
        unique_key = unique_key,
        binding = remap.binding,
    }, nil
end

local function base_semantic_key_expression(entity, representation, identity_binding)
    if upper(identity_binding.kind) == "DIRECT" then
        return tostring(identity_binding.expression)
    end
    local mapping = identity_binding.mapping
    local map_alias = "f5_base_map_" .. tostring(identity_binding.id)
    entity.fusion_joins = entity.fusion_joins or {}
    entity.fusion_join_by_representation = entity.fusion_join_by_representation or {}
    local join_key = "MAP:" .. key(identity_binding.id)
    if not entity.fusion_join_by_representation[join_key] then
        entity.fusion_joins[#entity.fusion_joins + 1] = {
            source_sql = quote_qualified(mapping.source_schema, mapping.source_object),
            alias = map_alias,
            predicates = {tostring(identity_binding.expression) .. " = "
                .. map_alias .. "." .. quote_ident(mapping.local_column)},
            identity_mapping = true,
        }
        entity.fusion_join_by_representation[join_key] = true
    end
    return map_alias .. "." .. quote_ident(mapping.semantic_column)
end

local function alternate_identity_source(representation, identity_binding, lookup_alias)
    if upper(identity_binding.kind) == "DIRECT" then
        return quote_qualified(representation.source_schema,
            representation.source_object),
            replace_qualified_alias(identity_binding.expression,
                representation.alias, lookup_alias), nil
    end
    local mapping = identity_binding.mapping
    local source_alias = "f5_src_" .. tostring(representation.id)
    local map_alias = "f5_map_" .. tostring(identity_binding.id)
    local local_expression = replace_qualified_alias(identity_binding.expression,
        representation.alias, source_alias)
    local source_sql = "(SELECT " .. source_alias .. ".*, " .. map_alias .. "."
        .. quote_ident(mapping.semantic_column) .. " AS "
        .. quote_ident("F5_SEMANTIC_KEY") .. " FROM "
        .. quote_qualified(representation.source_schema, representation.source_object)
        .. " " .. source_alias .. " JOIN "
        .. quote_qualified(mapping.source_schema, mapping.source_object) .. " "
        .. map_alias .. " ON " .. local_expression .. " = " .. map_alias .. "."
        .. quote_ident(mapping.local_column) .. ")"
    return source_sql, lookup_alias .. "." .. quote_ident("F5_SEMANTIC_KEY"), mapping
end

local function representation_by_id(ctx, representation_id)
    for _, representation in ipairs(ctx.representations or {}) do
        if key(representation.id) == key(representation_id) then return representation end
    end
    return nil
end

local function fusion_contributor_rank(ctx, binding)
    local representation = representation_by_id(ctx, binding.representation_id) or {}
    local authority = upper(representation.authority_role or "PREFER")
    local authority_rank = authority == "AUTHORITATIVE" and 0
        or authority == "PREFER" and 1 or 2
    local role_rank = upper(binding.role) == "PREFER" and 0 or 1
    return authority_rank, role_rank, tonumber(binding.priority or 1),
        tonumber(representation.priority or 1), tonumber(representation.id or 0)
end

local function sorted_fusion_bindings(ctx, bindings)
    local result = {}
    for _, binding in ipairs(bindings or {}) do result[#result + 1] = binding end
    table.sort(result, function(left, right)
        local la, lr, lb, lp, li = fusion_contributor_rank(ctx, left)
        local ra, rr, rb, rp, ri = fusion_contributor_rank(ctx, right)
        if la ~= ra then return la < ra end
        if lr ~= rr then return lr < rr end
        if lb ~= rb then return lb < rb end
        if lp ~= rp then return lp < rp end
        return li < ri
    end)
    return result
end

local function fused_attribute_expression(ctx, entity, base_representation,
        attribute_key, strategy)
    local unique_key = physical_unique_key(ctx, entity.id)
    local semantic_identity = complete_semantic_identity(ctx, entity)
    if unique_key == nil and semantic_identity == nil then
        return nil, nil, "Attribute fusion on entity '" .. tostring(entity.name)
            .. "' requires either a complete certified semantic identity or a declared unique key containing physical columns only."
    end
    local base_identity_binding = semantic_identity
        and semantic_identity.binding_by_representation[key(base_representation.id)] or nil
    local base_identity_expression = base_identity_binding
        and base_semantic_key_expression(entity, base_representation,
            base_identity_binding) or nil
    local bindings = sorted_fusion_bindings(ctx,
        ctx.bindings_by_attribute[attribute_key] or {})
    if #bindings < 2 then
        return nil, nil, "Fusion strategy " .. tostring(strategy) .. " for attribute '"
            .. tostring(attribute_key) .. "' requires bindings on at least two representations."
    end

    local expressions = {}
    local contributors = {}
    for _, binding in ipairs(bindings) do
        local representation = representation_by_id(ctx, binding.representation_id)
        if representation ~= nil then
            local expression = nil
            if key(representation.id) == key(base_representation.id) then
                expression = binding.expression
            else
                local lookup_alias = "f4_rep_" .. tostring(representation.id)
                local predicates = {}
                local source_sql = quote_qualified(representation.source_schema,
                    representation.source_object)
                local identity_mapping = nil
                if semantic_identity ~= nil then
                    local identity_binding = semantic_identity.binding_by_representation[
                        key(representation.id)]
                    local alternate_identity
                    source_sql, alternate_identity, identity_mapping =
                        alternate_identity_source(representation, identity_binding,
                            lookup_alias)
                    predicates[#predicates + 1] = alternate_identity
                        .. " = " .. base_identity_expression
                else
                    for _, column in ipairs(unique_key.columns) do
                        predicates[#predicates + 1] = quote_column(lookup_alias, column.column_name)
                            .. " = " .. quote_column(base_representation.alias, column.column_name)
                    end
                end
                entity.fusion_joins = entity.fusion_joins or {}
                entity.fusion_join_by_representation =
                    entity.fusion_join_by_representation or {}
                if not entity.fusion_join_by_representation[key(representation.id)] then
                    entity.fusion_joins[#entity.fusion_joins + 1] = {
                        representation = representation,
                        source_sql = source_sql,
                        alias = lookup_alias,
                        predicates = predicates,
                        identity_mapping = identity_mapping,
                    }
                    entity.fusion_join_by_representation[key(representation.id)] = true
                end
                expression = replace_qualified_alias(binding.expression,
                    representation.alias, lookup_alias)
            end
            expressions[#expressions + 1] = expression
            contributors[#contributors + 1] = {
                representation_id = representation.id,
                representation_name = representation.name,
                authority_role = upper(representation.authority_role or "PREFER"),
                attribute_binding_id = binding.id,
                source_expression = binding.expression,
                semantic_identity_id = semantic_identity and semantic_identity.id or nil,
                semantic_identity_name = semantic_identity and semantic_identity.name or nil,
                identity_binding_id = semantic_identity and
                    semantic_identity.binding_by_representation[key(representation.id)].id or nil,
                identity_mapping_id = semantic_identity and
                    semantic_identity.binding_by_representation[key(representation.id)].mapping
                    and semantic_identity.binding_by_representation[key(representation.id)].mapping.id or nil,
            }
        end
    end
    if #expressions < 2 then
        return nil, nil, "Fusion strategy " .. tostring(strategy) .. " for attribute '"
            .. tostring(attribute_key) .. "' has fewer than two active contributors."
    end
    return "COALESCE(" .. table.concat(expressions, ", ") .. ")", contributors, nil
end

local function select_attribute_bindings(ctx, dimensions, metrics, needed_entities)
    local required_by_entity = {}
    local function require_attribute(attribute_type, attribute)
        local entity_key = key(attribute.entity_id)
        required_by_entity[entity_key] = required_by_entity[entity_key] or {}
        required_by_entity[entity_key][attribute_type .. ":" .. key(attribute.id)] = attribute
    end
    for _, dimension in ipairs(dimensions or {}) do
        require_attribute("DIMENSION", dimension)
    end
    local required_facts = {}
    for _, metric in ipairs(metrics or {}) do
        collect_metric_facts(ctx, metric, required_facts, {})
    end
    for _, fact in pairs(required_facts) do require_attribute("FACT", fact) end

    ctx.selected_representations = {}
    for entity_id, _ in pairs(needed_entities or {}) do
        local entity = ctx.entity_by_id[key(entity_id)]
        if entity ~= nil then
            local attributes = required_by_entity[key(entity.id)] or {}
            local candidates = {}
            local incomplete_candidates = {}
            local representations = ctx.representations_by_entity[key(entity.id)] or {}
            if #representations == 0 and entity.primary_representation ~= nil then
                representations = {entity.primary_representation}
            end
            for _, representation in ipairs(representations) do
                local candidate = {
                    representation = representation,
                    bindings = {},
                    fallback_count = 0,
                    binding_priority = 0,
                    complete = true,
                    legacy_only = true,
                }
                local attribute_keys = {}
                for attribute_key, _ in pairs(attributes) do
                    attribute_keys[#attribute_keys + 1] = attribute_key
                end
                table.sort(attribute_keys)
                for _, attribute_key in ipairs(attribute_keys) do
                    local attribute = attributes[attribute_key]
                    local bindings = ctx.bindings_by_attribute[attribute_key] or {}
                    local selected = nil
                    for _, binding in ipairs(bindings) do
                        if key(binding.representation_id) == key(representation.id) then
                            selected = binding
                            break
                        end
                    end
                    if selected == nil and #bindings == 0
                        and upper(representation.role) == "PRIMARY" then
                        selected = {
                            id = nil,
                            representation_id = representation.id,
                            expression = attribute.expression,
                            role = "PREFER",
                            priority = 1,
                            legacy = true,
                        }
                    end
                    if selected == nil then
                        candidate.complete = false
                        candidate.missing_attribute_key = attribute_key
                        candidate.missing_attribute_name = attribute.name
                        break
                    end
                    candidate.bindings[attribute_key] = selected
                    if selected.legacy ~= true then candidate.legacy_only = false end
                    if upper(selected.role) == "FALLBACK" then
                        candidate.fallback_count = candidate.fallback_count + 1
                    end
                    candidate.binding_priority = candidate.binding_priority
                        + tonumber(selected.priority or 1)
                end
                for _, requirement in ipairs(
                    (ctx.relationship_requirements_by_entity or {})[key(entity.id)] or {}) do
                    if candidate.complete then
                        local route, route_error = relationship_candidate(ctx,
                            requirement, entity, representation)
                        if route == nil then
                            candidate.complete = false
                            candidate.relationship_error = route_error
                            candidate.relationship_name = requirement.relationship.name
                            candidate.relationship_side = requirement.side
                            ctx.relationship_candidate_rejections[#ctx.relationship_candidate_rejections + 1] = {
                                relationship_id = requirement.relationship.id,
                                relationship_name = requirement.relationship.name,
                                side = requirement.side,
                                entity_id = entity.id,
                                entity_name = entity.name,
                                representation_id = representation.id,
                                representation_name = representation.name,
                                reason = route_error,
                            }
                            break
                        end
                        candidate.relationship_routes = candidate.relationship_routes or {}
                        candidate.relationship_routes[key(requirement.relationship.id)
                            .. ":" .. requirement.side] = route
                    end
                end
                if candidate.complete then
                    candidates[#candidates + 1] = candidate
                else
                    incomplete_candidates[#incomplete_candidates + 1] = candidate
                end
            end
            table.sort(candidates, function(left, right)
                if left.fallback_count ~= right.fallback_count then
                    return left.fallback_count < right.fallback_count
                end
                if left.binding_priority ~= right.binding_priority then
                    return left.binding_priority < right.binding_priority
                end
                local left_is_primary = upper(left.representation.role) == "PRIMARY"
                local right_is_primary = upper(right.representation.role) == "PRIMARY"
                if left_is_primary ~= right_is_primary then return left_is_primary end
                local left_priority = tonumber(left.representation.priority or 1)
                local right_priority = tonumber(right.representation.priority or 1)
                if left_priority ~= right_priority then return left_priority < right_priority end
                return tonumber(left.representation.id) < tonumber(right.representation.id)
            end)
            local covered_count = 0
            for _, representation in ipairs(representations) do
                if not missing(representation.coverage_predicate) then
                    covered_count = covered_count + 1
                end
            end
            local partitioned = covered_count > 0
            if partitioned and covered_count ~= #representations then
                return nil, "Partitioned entity '" .. tostring(entity.name)
                    .. "' has incomplete coverage metadata."
            end
            if partitioned and #candidates ~= #representations then
                local incomplete = incomplete_candidates[1]
                if incomplete ~= nil then
                    return nil, "Attribute '" .. tostring(incomplete.missing_attribute_name
                        or incomplete.missing_attribute_key) .. "' has no binding on partition '"
                        .. tostring(incomplete.representation.name) .. "' of entity '"
                        .. tostring(entity.name)
                        .. "'. Add it with ADD_ATTRIBUTE_BINDING."
                end
                return nil, "No complete UNION binding set exists for every partition of entity '"
                    .. tostring(entity.name) .. "'."
            end
            for attribute_key, _ in pairs(attributes) do
                local policy = ctx.fusion_policy_by_attribute[attribute_key]
                local strategy = upper(policy and policy.strategy or "PREFER")
                if partitioned and strategy ~= "PREFER" then
                    return nil, "Entity '" .. tostring(entity.name)
                        .. "' cannot combine partition UNION with attribute strategy "
                        .. tostring(strategy) .. "."
                end
            end
            local selected = candidates[1]
            if selected == nil then
                local relationship_failure = nil
                for _, incomplete in ipairs(incomplete_candidates) do
                    if incomplete.relationship_name ~= nil then
                        relationship_failure = incomplete
                        break
                    end
                end
                if relationship_failure ~= nil then
                    return nil, "No active representation can traverse relationship '"
                        .. tostring(relationship_failure.relationship_name) .. "' on "
                        .. tostring(relationship_failure.relationship_side) .. " entity '"
                        .. tostring(entity.name) .. "': "
                        .. tostring(relationship_failure.relationship_error) .. "."
                end
                return nil, "No active representation provides every required attribute for entity '"
                    .. tostring(entity.name) .. "'. Add compatible PREFER/FALLBACK bindings."
            end
            local representation = selected.representation
            entity.source_schema = representation.source_schema
            entity.source_object = representation.source_object
            entity.alias = representation.alias
            entity.selected_representation = representation
            if partitioned then
                entity.fusion_strategy = "UNION"
                entity.fusion_candidates = candidates
            end
            for attribute_key, binding in pairs(selected.bindings) do
                local attribute_type, attribute_id = string.match(attribute_key, "^([^:]+):(.+)$")
                local attribute = attribute_type == "DIMENSION"
                    and ctx.dimension_by_id[key(attribute_id)] or ctx.fact_by_id[key(attribute_id)]
                if attribute ~= nil then
                    local policy = ctx.fusion_policy_by_attribute[attribute_key]
                    local strategy = upper(policy and policy.strategy or "PREFER")
                    if strategy == "COALESCE" or strategy == "RECONCILE" then
                        local fused_expression, contributors, fusion_error =
                            fused_attribute_expression(ctx, entity, representation,
                                attribute_key, strategy)
                        if fused_expression == nil then return nil, fusion_error end
                        attribute.expression = fused_expression
                        attribute.fusion_strategy = strategy
                        attribute.fusion_contributors = contributors
                        ctx.has_attribute_fusion = true
                    else
                        attribute.expression = binding.expression
                        attribute.fusion_strategy = "PREFER"
                    end
                    attribute.selected_binding = binding
                end
            end
            ctx.selected_representations[key(entity.id)] = {
                representation = representation,
                fallback_count = selected.fallback_count,
                binding_priority = selected.binding_priority,
                bindings = selected.bindings,
                legacy_only = selected.legacy_only,
                fusion_strategy = partitioned and "UNION" or nil,
                candidates = partitioned and candidates or nil,
                relationship_routes = selected.relationship_routes or {},
            }
        end
    end
    return true, nil
end

local function apply_metric_filter(expression, filter_expr)
    if missing(filter_expr) then
        return expression
    end
    local inner = string.match(expression, "^%s*SUM%s*%((.*)%)%s*$")
    if inner ~= nil then
        return "SUM(CASE WHEN " .. tostring(filter_expr) .. " THEN " .. inner .. " ELSE 0 END)"
    end
    inner = string.match(expression, "^%s*COUNT%s*%((.*)%)%s*$")
    if inner ~= nil then
        return "COUNT(CASE WHEN " .. tostring(filter_expr) .. " THEN " .. inner .. " ELSE NULL END)"
    end
    return "CASE WHEN " .. tostring(filter_expr) .. " THEN " .. expression .. " ELSE NULL END"
end

local function expand_metric(ctx, metric, stack)
    stack = stack or {}
    local metric_key = key(metric.id)
    if stack[metric_key] then
        error("Cyclic metric dependency detected while expanding " .. tostring(metric.name))
    end
    stack[metric_key] = true
    local expanded = replace_identifiers(tostring(metric.expression), function(token)
        local normalized = upper(token)
        local fact = ctx.fact_by_name[normalized]
        if fact ~= nil then
            return "(" .. tostring(fact.expression) .. ")"
        end
        for _, candidate in ipairs(ctx.all_metrics or ctx.metrics) do
            if upper(candidate.name) == normalized then
                return "(" .. expand_metric(ctx, candidate, stack) .. ")"
            end
        end
        return nil
    end)
    stack[metric_key] = nil
    return apply_metric_filter(expanded, metric.filter_expr)
end

local function build_dimension_predicate(expression, op, value, data_type, value_sql)
    if op == "IS NULL" or op == "IS NOT NULL" then
        return expression .. " " .. op, nil
    end
    local rhs = value_sql or sql_literal(value, data_type)
    local text_compare = value_sql == nil and is_text_type(data_type)
    if op == "=" or op == "!=" or op == "<>" or op == ">" or op == ">=" or op == "<" or op == "<=" or op == "LIKE" then
        if text_compare and (op == "=" or op == "!=" or op == "<>" or op == "LIKE") then
            return "UPPER(" .. expression .. ") " .. op .. " UPPER(" .. rhs .. ")"
        end
        return expression .. " " .. op .. " " .. rhs
    elseif op == "IN" then
        local values = as_array(value, "filter.value")
        if #values == 0 then
            return nil, error_result("SEMANTIC_REQUEST_032", "IN filter requires at least one value.")
        end
        local literals = {}
        for _, item in ipairs(values) do
            local literal = sql_literal(item, data_type)
            if is_text_type(data_type) then
                literal = "UPPER(" .. literal .. ")"
            end
            literals[#literals + 1] = literal
        end
        if is_text_type(data_type) then
            return "UPPER(" .. expression .. ") IN (" .. table.concat(literals, ", ") .. ")", nil
        end
        return expression .. " IN (" .. table.concat(literals, ", ") .. ")", nil
    elseif op == "BETWEEN" then
        local values = as_array(value, "filter.value")
        if #values ~= 2 then
            return nil, error_result("SEMANTIC_REQUEST_032", "BETWEEN filter requires exactly two values.")
        end
        return expression .. " BETWEEN " .. sql_literal(values[1], data_type) .. " AND " .. sql_literal(values[2], data_type), nil
    end
    return nil, error_result("SEMANTIC_REQUEST_033", "Unsupported filter operator: " .. tostring(op) .. ". Supported operators: =, !=, <>, >, >=, <, <=, LIKE, IN, BETWEEN, IS NULL, IS NOT NULL.")
end

local function build_filters(ctx, request_filters, selected_dimensions, needed_entities)
    local filters = {}
    local filter_dimensions = {}
    local filter_seen = {}
    for _, filter in ipairs(as_array(request_filters, "filters")) do
        if type(filter) ~= "table" then
            return nil, nil, error_result("SEMANTIC_REQUEST_030", "Each filter must be an object.")
        end
        local filter_field = filter.field or filter.dimension or filter.column or filter.name
        if missing(filter_field) then
            return nil, nil, error_result("SEMANTIC_REQUEST_020", "Filter requires a field key. Accepted aliases: field, dimension, column, name.")
        end
        local field, err = resolve_field(ctx, filter_field, nil)
        if err ~= nil then
            return nil, nil, err
        end
        if field.kind ~= "DIMENSION" then
            return nil, nil, error_result("SEMANTIC_REQUEST_031", "MVP filters support dimensions only: " .. tostring(filter_field) .. ".")
        end
        local op = upper(filter.op or filter.operator or "=")
        if missing(filter.value) and missing(filter.value_sql) and op ~= "IS NULL" and op ~= "IS NOT NULL" then
            return nil, nil, error_result("SEMANTIC_REQUEST_015",
                "Filter for field '" .. tostring(field.name) .. "' requires a value or value_sql key.")
        end
        local expression = tostring(field.expression)
        local predicate, predicate_err = build_dimension_predicate(expression, op, filter.value, field.data_type, filter.value_sql)
        if predicate_err ~= nil then
            return nil, nil, predicate_err
        end
        filters[#filters + 1] = {
            field = field.name,
            field_id = field.id,
            field_kind = field.kind,
            entity_id = field.entity_id,
            op = op,
            value = filter.value,
            value_sql = filter.value_sql,
            data_type = field.data_type,
            expression = expression,
            predicate = predicate,
        }
        needed_entities[key(field.entity_id)] = true
        add_unique(filter_dimensions, filter_seen, field)
    end
    return filters, filter_dimensions, nil
end

local function collect_intrinsic_filter_dimensions(ctx, metrics, needed_entities)
    local dimensions = {}
    local seen = {}
    for _, metric in ipairs(metrics or {}) do
        local rows = query([[
            SELECT REQUIRED_DIMENSION_ID
            FROM SYS_SEMANTIC.METRIC_FILTERS
            WHERE METRIC_ID = :metric_id
              AND REQUIRED_DIMENSION_ID IS NOT NULL
            ORDER BY ORDINAL_POSITION
        ]], {metric_id = metric.id})
        for _, row in ipairs(rows or {}) do
            local dimension = ctx.dimension_by_id[key(row_value(row, "REQUIRED_DIMENSION_ID", 1))]
            if dimension ~= nil then
                needed_entities[key(dimension.entity_id)] = true
                add_unique(dimensions, seen, dimension)
            end
        end
    end
    return dimensions
end

local function validate_metric_dimensions(ctx, metrics, dimensions)
    for _, metric in ipairs(metrics) do
        for _, dimension in ipairs(dimensions) do
            local rows = query([[
                SELECT IS_VALID, REASON_CODE, RELATIONSHIP_PATH
                FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX
                WHERE MODEL_ID = :model_id
                  AND VERSION_ID = :version_id
                  AND METRIC_ID = :metric_id
                  AND DIMENSION_ID = :dimension_id
            ]], {
                model_id = ctx.model.model_id,
                version_id = ctx.model.version_id,
                metric_id = metric.id,
                dimension_id = dimension.id,
            })
            if rows == nil or #rows == 0 then
                return error_result("SEMANTIC_REQUEST_040", "Missing validation matrix row for " .. tostring(metric.name) .. " and " .. tostring(dimension.name) .. ".")
            end
            local is_valid = row_value(rows[1], "IS_VALID", 1)
            if not boolish(is_valid) then
                return error_result("SEMANTIC_REQUEST_041", "Metric " .. tostring(metric.name) .. " cannot be grouped or filtered by dimension " .. tostring(dimension.name) .. ": " .. tostring(row_value(rows[1], "REASON_CODE", 2)) .. ".")
            end
        end
    end
    return nil
end

local function plan_joins(ctx, needed_entities)
    local root_id = ctx.object.root_entity_id
    needed_entities[key(root_id)] = true
    local joins = {}
    local joined_entities = {[key(root_id)] = true}
    local joined_relationships = {}
    local relationship_paths = {}

    local entity_ids = {}
    for entity_id, _ in pairs(needed_entities) do
        if entity_id ~= key(root_id) then
            entity_ids[#entity_ids + 1] = entity_id
        end
    end
    table.sort(entity_ids)

    for _, entity_id in ipairs(entity_ids) do
        local path = find_path(ctx, root_id, entity_id)
        if path == nil then
            local entity = ctx.entity_by_id[entity_id]
            local proof = ctx._last_path_proof or {}
            if proof.reason == "AMBIGUOUS_RELATIONSHIP_PATH" then
                return nil, nil, error_result(
                    "SEMANTIC_REQUEST_042",
                    "Ambiguous safe relationship path from semantic object root to entity "
                        .. tostring(entity and entity.name or entity_id) .. ": "
                        .. table.concat(proof.candidate_paths or {}, " | ") .. "."
                )
            end
            return nil, nil, error_result("SEMANTIC_REQUEST_042",
                "No safe relationship path from semantic object root to entity "
                    .. tostring(entity and entity.name or entity_id) .. ".")
        end
        local path_names = {}
        for _, edge in ipairs(path) do
            local relationship = edge.relationship
            path_names[#path_names + 1] = relationship.name
            local join_key = key(relationship.id)
            local to_entity_key = key(edge.to_entity_id)
            needed_entities[to_entity_key] = true
            if not joined_relationships[join_key] and not joined_entities[to_entity_key] then
                joins[#joins + 1] = {
                    relationship = relationship,
                    entity = ctx.entity_by_id[to_entity_key],
                }
                joined_relationships[join_key] = true
                joined_entities[to_entity_key] = true
            end
        end
        relationship_paths[#relationship_paths + 1] = table.concat(path_names, " > ")
    end
    return joins, relationship_paths, nil
end

local function configure_relationship_requirements(ctx, joins)
    ctx.relationship_requirements_by_entity = {}
    for _, join in ipairs(joins or {}) do
        local relationship = join.relationship
        if #(relationship.key_mappings or {}) > 0 then
            for _, endpoint in ipairs({
                {side = "from", entity_id = relationship.from_entity_id},
                {side = "to", entity_id = relationship.to_entity_id},
            }) do
                local entity_key = key(endpoint.entity_id)
                ctx.relationship_requirements_by_entity[entity_key] =
                    ctx.relationship_requirements_by_entity[entity_key] or {}
                ctx.relationship_requirements_by_entity[entity_key][#ctx.relationship_requirements_by_entity[entity_key] + 1] = {
                    relationship = relationship,
                    side = endpoint.side,
                }
            end
        end
    end
end

local function replace_qualified_column(expression, source_alias, source_column,
        replacement)
    local text = tostring(expression)
    local out = {}
    local i = 1
    local in_string = false
    while i <= #text do
        local char = string.sub(text, i, i)
        local next_char = string.sub(text, i + 1, i + 1)
        if char == "'" then
            out[#out + 1] = char
            if in_string and next_char == "'" then
                out[#out + 1] = next_char
                i = i + 2
            else
                in_string = not in_string
                i = i + 1
            end
        elseif not in_string and string.match(char, "[A-Za-z_]") then
            local alias_end = i + 1
            while alias_end <= #text
                and string.match(string.sub(text, alias_end, alias_end), "[A-Za-z0-9_]") do
                alias_end = alias_end + 1
            end
            local alias = string.sub(text, i, alias_end - 1)
            local cursor = alias_end
            while string.match(string.sub(text, cursor, cursor), "%s") do cursor = cursor + 1 end
            if upper(alias) == upper(source_alias)
                and string.sub(text, cursor, cursor) == "." then
                cursor = cursor + 1
                while string.match(string.sub(text, cursor, cursor), "%s") do cursor = cursor + 1 end
                local column = nil
                local column_end = cursor
                if string.sub(text, cursor, cursor) == '"' then
                    local parts = {}
                    column_end = cursor + 1
                    while column_end <= #text do
                        local current = string.sub(text, column_end, column_end)
                        local following = string.sub(text, column_end + 1, column_end + 1)
                        if current == '"' and following == '"' then
                            parts[#parts + 1] = '"'
                            column_end = column_end + 2
                        elseif current == '"' then
                            column = table.concat(parts)
                            column_end = column_end + 1
                            break
                        else
                            parts[#parts + 1] = current
                            column_end = column_end + 1
                        end
                    end
                else
                    local start_pos, end_pos, value = string.find(text,
                        "([A-Za-z_][A-Za-z0-9_]*)", cursor)
                    if start_pos == cursor then
                        column = value
                        column_end = end_pos + 1
                    end
                end
                if column ~= nil and upper(column) == upper(source_column) then
                    out[#out + 1] = tostring(replacement)
                    i = column_end
                else
                    out[#out + 1] = alias
                    i = alias_end
                end
            else
                out[#out + 1] = alias
                i = alias_end
            end
        else
            out[#out + 1] = char
            i = i + 1
        end
    end
    return table.concat(out)
end

local function relationship_join_condition(ctx, relationship)
    local condition = tostring(relationship.join_condition)
    local provenance = {}
    for _, endpoint in ipairs({
        {side = "from", entity_id = relationship.from_entity_id},
        {side = "to", entity_id = relationship.to_entity_id},
    }) do
        local entity = ctx.entity_by_id[key(endpoint.entity_id)]
        local selection = entity and ctx.selected_representations
            and ctx.selected_representations[key(entity.id)] or nil
        local route = selection and selection.relationship_routes[
            key(relationship.id) .. ":" .. endpoint.side] or nil
        if route ~= nil and route.kind == "DIRECT_IDENTITY" then
            condition = replace_qualified_column(condition, entity.alias,
                route.column_name, route.binding.expression)
            provenance[#provenance + 1] = {
                relationship_id = relationship.id,
                relationship_name = relationship.name,
                side = endpoint.side,
                entity_id = entity.id,
                entity_name = entity.name,
                representation_id = selection.representation.id,
                representation_name = selection.representation.name,
                semantic_identity_id = route.identity.id,
                semantic_identity_name = route.identity.name,
                identity_binding_id = route.binding.id,
                identity_mapping_id = nil,
                source_expression = route.binding.expression,
                unique_key_id = route.unique_key.id,
            }
        end
    end
    return condition, provenance
end

local function build_order_by(ctx, request_order_by, output_fields)
    local clauses = {}
    for _, item in ipairs(as_array(request_order_by, "order_by")) do
        if type(item) ~= "table" then
            return nil, error_result("SEMANTIC_REQUEST_060", "Each order_by item must be an object.")
        end
        local field, err = resolve_field(ctx, item.field, nil)
        if err ~= nil then
            return nil, err
        end
        if not output_fields[field.kind .. ":" .. key(field.id)] then
            return nil, error_result("SEMANTIC_REQUEST_061", "ORDER BY field must be selected in the MVP: " .. tostring(item.field) .. ".")
        end
        local direction = upper(item.direction or "ASC")
        if direction ~= "ASC" and direction ~= "DESC" then
            return nil, error_result("SEMANTIC_REQUEST_062", "Unsupported ORDER BY direction: " .. tostring(item.direction) .. ".")
        end
        clauses[#clauses + 1] = quote_alias(field.name) .. " " .. direction
    end
    return clauses, nil
end

local function build_sql(ctx, dimensions, metrics, filters, joins, order_by, limit, having_predicates)
    local root = ctx.entity_by_id[key(ctx.object.root_entity_id)]
    local select_parts = {}
    local group_parts = {}
    local join_sql = {}
    local where_predicates = {}
    for _, dimension in ipairs(dimensions) do
        select_parts[#select_parts + 1] = tostring(dimension.expression) .. " AS " .. quote_alias(dimension.name)
        group_parts[#group_parts + 1] = tostring(dimension.expression)
    end
    for _, metric in ipairs(metrics) do
        select_parts[#select_parts + 1] = expand_metric(ctx, metric) .. " AS " .. quote_alias(metric.name)
    end

    local function append_fusion_joins(entity)
        for _, fusion_join in ipairs(entity.fusion_joins or {}) do
            local representation = fusion_join.representation
            join_sql[#join_sql + 1] = "LEFT JOIN "
                .. (fusion_join.source_sql or quote_qualified(
                    representation.source_schema, representation.source_object))
                .. " " .. fusion_join.alias
                .. " ON " .. table.concat(fusion_join.predicates, " AND ")
        end
    end
    append_fusion_joins(root)
    for _, join in ipairs(joins) do
        local join_condition, remaps = relationship_join_condition(ctx,
            join.relationship)
        for _, remap in ipairs(remaps) do
            ctx.relationship_identity_remaps[#ctx.relationship_identity_remaps + 1] = remap
        end
        join_sql[#join_sql + 1] = tostring(join.relationship.join_type or "LEFT") .. " JOIN "
            .. quote_qualified(join.entity.source_schema, join.entity.source_object)
            .. " " .. tostring(join.entity.alias)
            .. " ON " .. join_condition
        append_fusion_joins(join.entity)
    end
    for _, filter in ipairs(filters) do
        where_predicates[#where_predicates + 1] = filter.predicate
    end
    return grain_sql_runtime.render_single_branch({
        select_parts = select_parts,
        from_sql = quote_qualified(root.source_schema, root.source_object)
            .. " " .. tostring(root.alias),
        join_sql = join_sql,
        where_predicates = where_predicates,
        group_parts = group_parts,
        having_predicates = having_predicates or {},
        order_by = order_by,
        limit = limit,
    })
end

local function build_materialized_sql(ctx, dimensions, metrics, filters, order_by, limit, materialization)
    local alias = "mat"
    local select_parts = {}
    local group_parts = {}
    local uses_aggregate = false
    for _, dimension in ipairs(dimensions) do
        local column = materialization.columns[dimension.kind .. ":" .. key(dimension.id)]
        local expression = quote_column(alias, column.physical_column)
        select_parts[#select_parts + 1] = expression .. " AS " .. quote_alias(dimension.name)
        group_parts[#group_parts + 1] = expression
    end
    for _, metric in ipairs(metrics) do
        local metric_key = metric.kind .. ":" .. key(metric.id)
        local column = materialization.columns[metric_key]
        local column_expression = quote_column(alias, column.physical_column)
        local policy = materialization.metric_rollup_policies and materialization.metric_rollup_policies[metric_key] or "DIRECT"
        local expression = column_expression
        if policy == "SUM" then
            expression = "SUM(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "MIN" then
            expression = "MIN(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "MAX" then
            expression = "MAX(" .. column_expression .. ")"
            uses_aggregate = true
        elseif policy == "COUNT" then
            expression = "SUM(" .. column_expression .. ")"
            uses_aggregate = true
        end
        select_parts[#select_parts + 1] = expression .. " AS " .. quote_alias(metric.name)
    end

    local sql_parts = {}
    sql_parts[#sql_parts + 1] = "SELECT " .. table.concat(select_parts, ", ")
    sql_parts[#sql_parts + 1] = "FROM " .. quote_qualified(materialization.physical_schema, materialization.physical_object) .. " " .. alias
    if #filters > 0 then
        local predicates = {}
        for _, filter in ipairs(filters) do
            local column = materialization.columns[tostring(filter.field_kind) .. ":" .. key(filter.field_id)]
            local predicate, predicate_err = build_dimension_predicate(
                quote_column(alias, column.physical_column),
                filter.op,
                filter.value,
                filter.data_type,
                filter.value_sql
            )
            if predicate_err ~= nil then
                error(predicate_err.error_message or "Invalid materialized filter predicate.")
            end
            predicates[#predicates + 1] = predicate
        end
        sql_parts[#sql_parts + 1] = "WHERE " .. table.concat(predicates, " AND ")
    end
    if uses_aggregate and #group_parts > 0 then
        sql_parts[#sql_parts + 1] = "GROUP BY " .. table.concat(group_parts, ", ")
    end
    if #order_by > 0 then
        sql_parts[#sql_parts + 1] = "ORDER BY " .. table.concat(order_by, ", ")
    end
    if limit ~= nil then
        sql_parts[#sql_parts + 1] = "LIMIT " .. tostring(limit)
    end
    return table.concat(sql_parts, "\n")
end

local function log_request(result, request_json, request, model)
    local request_model_id = model and model.model_id or null
    local request_version_id = model and model.version_id or null
    local dimensions = request and request.dimensions or {}
    local metrics = request and request.metrics or {}
    query([[
        INSERT INTO SYS_SEMANTIC.AGENT_REQUEST_LOG (
          MODEL_ID, VERSION_ID, CLIENT_NAME, PURPOSE, REQUEST_JSON, GENERATED_SQL,
          PLAN_JSON, REQUESTED_METRICS, REQUESTED_DIMENSIONS, STATUS, ERROR_CODE, ERROR_MESSAGE,
          CACHE_HIT, FINISHED_AT, RUNTIME_MS
        ) VALUES (
          :model_id, :version_id, :client_name, :purpose, :request_json, :generated_sql,
          :plan_json, :requested_metrics, :requested_dimensions, :status, :error_code, :error_message,
          :cache_hit, CURRENT_TIMESTAMP, :runtime_ms
        )
    ]], {
        model_id = null_if_missing(request_model_id),
        version_id = null_if_missing(request_version_id),
        client_name = request and null_if_missing(request.client) or null,
        purpose = request and null_if_missing(request.purpose) or null,
        request_json = null_if_missing(request_json),
        generated_sql = null_if_missing(result.generated_sql),
        plan_json = null_if_missing(result.plan_json),
        requested_metrics = null_if_missing(json_encode(metrics)),
        requested_dimensions = null_if_missing(json_encode(dimensions)),
        status = null_if_missing(result.status),
        error_code = null_if_missing(result.error_code),
        error_message = null_if_missing(result.error_message),
        cache_hit = result.cache_hit == true,
        runtime_ms = null_if_missing(result.planning_runtime_ms),
    })
    result.agent_request_id = scalar([[
        SELECT MAX(AGENT_REQUEST_ID)
        FROM SYS_SEMANTIC.AGENT_REQUEST_LOG
        WHERE USER_NAME = CURRENT_USER
    ]])
end

local function log_query_result(result, original_sql, request, model, client_name)
    local request_model_id = model and model.model_id or null
    local request_version_id = model and model.version_id or null
    local dimensions = request and request.dimensions or {}
    local metrics = request and request.metrics or {}
    query([[
        INSERT INTO SYS_SEMANTIC.QUERY_LOG (
          MODEL_ID, VERSION_ID, CLIENT_NAME, ORIGINAL_SQL, GENERATED_SQL,
          PLAN_JSON, REQUESTED_DIMENSIONS, REQUESTED_METRICS, MATERIALIZATION_USED,
          STATUS, ERROR_CODE,
          ERROR_MESSAGE, FINISHED_AT, RUNTIME_MS
        ) VALUES (
          :model_id, :version_id, :client_name, :original_sql, :generated_sql,
          :plan_json, :requested_dimensions, :requested_metrics, :materialization_used,
          :status, :error_code,
          :error_message, CURRENT_TIMESTAMP, :runtime_ms
        )
    ]], {
        model_id = null_if_missing(request_model_id),
        version_id = null_if_missing(request_version_id),
        client_name = null_if_missing(client_name or "COMPILE_SQL_DEBUG"),
        original_sql = null_if_missing(original_sql),
        generated_sql = null_if_missing(result.generated_sql),
        plan_json = null_if_missing(result.plan_json),
        requested_dimensions = null_if_missing(json_encode(dimensions)),
        requested_metrics = null_if_missing(json_encode(metrics)),
        materialization_used = null_if_missing(result.materialization_used),
        status = null_if_missing(result.status),
        error_code = null_if_missing(result.error_code),
        error_message = null_if_missing(result.error_message),
        runtime_ms = null_if_missing(result.planning_runtime_ms),
    })
    result.query_log_id = scalar([[
        SELECT MAX(QUERY_LOG_ID)
        FROM SYS_SEMANTIC.QUERY_LOG
        WHERE USER_NAME = CURRENT_USER
    ]])
end

local function latest_successful_validation(model)
    local rows = query([[
        SELECT VALIDATION_RUN_ID, STATUS, ERROR_COUNT
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS IN ('OK', 'WARNING')
          AND ERROR_COUNT = 0
        ORDER BY VALIDATION_RUN_ID DESC
        LIMIT 1
    ]], {model_id = model.model_id, version_id = model.version_id})
    if rows == nil or #rows == 0 then
        local latest_rows = query([[
            SELECT STATUS, ERROR_COUNT
            FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id
              AND VERSION_ID = :version_id
            ORDER BY VALIDATION_RUN_ID DESC
            LIMIT 1
        ]], {model_id = model.model_id, version_id = model.version_id})
        if latest_rows ~= nil and #latest_rows > 0 then
            local status = tostring(row_value(latest_rows[1], "STATUS", 1) or "UNKNOWN")
            if status == "STALE" then
                return nil, "The active catalog version changed after its last successful validation. This release edits the published version in place, so its published surface is unavailable until VALIDATE_MODEL succeeds."
            end
            return nil, "The latest validation status is " .. status
                .. " with " .. tostring(row_value(latest_rows[1], "ERROR_COUNT", 2) or 0)
                .. " error(s)."
        end
        return nil, "No validation run exists for this model version."
    end
    return row_value(rows[1], "VALIDATION_RUN_ID", 1), nil
end

local function load_model_by_published_schema(schema_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.MODEL_NAME, m.ACTIVE_VERSION_ID AS VERSION_ID, mv.VERSION_NUMBER
        FROM SYS_SEMANTIC.MODELS m
        LEFT JOIN SYS_SEMANTIC.MODEL_VERSIONS mv
          ON mv.VERSION_ID = m.ACTIVE_VERSION_ID
        WHERE UPPER(m.PUBLISHED_SCHEMA) = UPPER(:schema_name)
    ]], {schema_name = schema_name})
    if rows == nil or #rows == 0 then
        return nil
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        model_name = row_value(rows[1], "MODEL_NAME", 2),
        version_id = row_value(rows[1], "VERSION_ID", 3),
        version_number = row_value(rows[1], "VERSION_NUMBER", 4),
    }
end

local function compile_request_table(request, options)
    options = options or {}
    local error_prefix = options.error_prefix or "SEMANTIC_REQUEST"
    local normalized_request, query_spec_error = query_spec_runtime.new(
        request, options.source or request.source or "JSON"
    )
    if normalized_request == nil then
        return error_result(error_prefix .. "_001",
            "Invalid canonical query specification: " .. tostring(query_spec_error) .. ".")
    end
    request = normalized_request
    if request.proof_mode ~= "LEGACY_JOIN" and request.proof_mode ~= "STRICT_GRAIN" then
        return error_result(error_prefix .. "_071",
            "Unsupported proof_mode: " .. tostring(request.proof_mode) .. ".")
    end

    local ok_model_name, model_name = pcall(normalize_name, request.model, "model")
    if not ok_model_name then
        return error_result(error_prefix .. "_002", tostring(model_name) .. ".")
    end
    local ok_object_name, object_name = pcall(normalize_name, request.object, "object")
    if not ok_object_name then
        return error_result(error_prefix .. "_003", tostring(object_name) .. ".")
    end

    local model = options.model or load_model(model_name)
    if model == nil then
        return error_result(error_prefix .. "_011", "Model not found: " .. model_name .. ".")
    end

    -- Compile-cache fast path: hit returns the stored GENERATED_SQL + PLAN_JSON
    -- without re-running catalog load, matrix lookup, join planning, materialization
    -- selection, or SQL emission. Cache writes happen further down the function
    -- only when the full compile succeeded (so error results never get cached).
    local cache_key = nil
    if options.cache ~= false and not missing(model.version_id) then
        cache_key = compile_cache_key(canonical_request_text(request))
        if cache_key ~= nil then
            local cached = cache_lookup(model.version_id, cache_key)
            if cached ~= nil then
                cache_touch(model.version_id, cache_key)
                local result = cached_ok_result(cached)
                if error_prefix ~= "SEMANTIC_REQUEST" then
                    recode_error_prefix(result, error_prefix)
                end
                return result, request, model
            end
        end
    end

    local planning_started_ms = monotonic_ms()
    local ctx, load_code, load_message = load_catalog(model, object_name)
    if ctx == nil then
        return error_result(load_code, load_message)
    end

    local selected_dimensions = {}
    local selected_dimension_seen = {}
    for _, dimension_name in ipairs(as_array(request.dimensions, "dimensions")) do
        local field, err = resolve_field(ctx, dimension_name, "DIMENSION")
        if err ~= nil then
            return err
        end
        add_unique(selected_dimensions, selected_dimension_seen, field)
    end

    local selected_metrics = {}
    local selected_metric_seen = {}
    for _, metric_name in ipairs(as_array(request.metrics, "metrics")) do
        local field, err = resolve_field(ctx, metric_name, "METRIC")
        if err ~= nil then
            return err
        end
        add_unique(selected_metrics, selected_metric_seen, field)
    end
    -- Dimension-only discovery (BUG-D-003): allow an empty metrics list as long
    -- as dimensions is non-empty. Compiles to a deduplicated GROUP BY over the
    -- dimensions - the same shape a dashboard needs to populate facet filters
    -- without having to fake an unused metric.
    if #selected_metrics == 0 and #selected_dimensions == 0 then
        return error_result("SEMANTIC_REQUEST_023",
            "At least one metric or dimension is required.")
    end

    local needed_entities = {[key(ctx.object.root_entity_id)] = true}
    local all_dimensions = {}
    local all_dimension_seen = {}
    for _, dimension in ipairs(selected_dimensions) do
        add_unique(all_dimensions, all_dimension_seen, dimension)
        needed_entities[key(dimension.entity_id)] = true
    end
    for _, metric in ipairs(selected_metrics) do
        collect_metric_entities(ctx, metric, needed_entities, {})
    end

    local filters, filter_dimensions, filter_err = build_filters(ctx, request.filters, selected_dimensions, needed_entities)
    if filter_err ~= nil then
        return filter_err
    end
    local filter_dimension_seen = {}
    for _, dimension in ipairs(filter_dimensions) do
        filter_dimension_seen[dimension.kind .. ":" .. key(dimension.id)] = true
    end
    local intrinsic_filter_dimensions = collect_intrinsic_filter_dimensions(ctx, selected_metrics, needed_entities)
    for _, dimension in ipairs(intrinsic_filter_dimensions) do
        add_unique(filter_dimensions, filter_dimension_seen, dimension)
    end
    for _, dimension in ipairs(filter_dimensions) do
        add_unique(all_dimensions, all_dimension_seen, dimension)
    end

    local validation_run_id = nil
    if options.validate == false then
        local validation_message
        validation_run_id, validation_message = latest_successful_validation(model)
        if validation_run_id == nil then
            return error_result(error_prefix .. "_010",
                "Model validation is missing or stale: " .. validation_message
                .. " Run EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('" .. tostring(model.model_name) .. "') (or PUBLISH_MODEL) before compiling.")
        end
    else
        local validation_errors
        validation_errors, validation_run_id = validate_model(model)
        local referenced = collect_referenced_validation_objects(ctx, selected_metrics, all_dimensions)
        for _, validation_error in ipairs(validation_errors) do
            if validation_error_applies(validation_error, referenced) then
                return error_result(error_prefix .. "_010", "Model validation failed: " .. tostring(validation_error.code) .. " " .. tostring(validation_error.message))
            end
        end
    end

    local limit = nil
    if not missing(request.limit) then
        limit = tonumber(request.limit)
        if limit == nil or limit < 1 or limit % 1 ~= 0 then
            return error_result("SEMANTIC_REQUEST_050", "LIMIT must be a positive integer.")
        end
        if limit > MAX_LIMIT then
            return error_result("SEMANTIC_REQUEST_051", "LIMIT exceeds maximum " .. tostring(MAX_LIMIT) .. ".")
        end
    end

    local output_fields = {}
    for _, dimension in ipairs(selected_dimensions) do
        output_fields[dimension.kind .. ":" .. key(dimension.id)] = true
    end
    for _, metric in ipairs(selected_metrics) do
        output_fields[metric.kind .. ":" .. key(metric.id)] = true
    end
    local order_by, order_err = build_order_by(ctx, request.order_by, output_fields)
    if order_err ~= nil then
        return order_err
    end

    local having_predicates = {}
    local bound_having_filters = {}
    local planning_metrics = {}
    local planning_metric_seen = {}
    for _, metric in ipairs(selected_metrics) do
        add_unique(planning_metrics, planning_metric_seen, metric)
    end
    local having_list = as_array(request.having, "having")
    if #having_list > 0 and #selected_metrics == 0 then
        return error_result("SEMANTIC_REQUEST_026",
            "HAVING requires at least one metric in the request.")
    end
    for _, having_filter in ipairs(having_list) do
        if type(having_filter) ~= "table" then
            return error_result("SEMANTIC_REQUEST_030", "Each having filter must be an object.")
        end
        local filter_field = having_filter.field or having_filter.dimension or having_filter.column or having_filter.name
        if missing(filter_field) then
            -- SEMANTIC_REQUEST_025: having filter structure error (missing field key), distinct from
            -- SEMANTIC_REQUEST_020 (unknown field name) so agents can handle each differently.
            return error_result("SEMANTIC_REQUEST_025", "Having filter requires a field key. Accepted aliases: field, dimension, column, name.")
        end
        local metric_field, having_err = resolve_field(ctx, filter_field, "METRIC")
        if having_err ~= nil then
            return having_err
        end
        add_unique(planning_metrics, planning_metric_seen, metric_field)
        collect_metric_entities(ctx, metric_field, needed_entities, {})
        local op = upper(having_filter.op or having_filter.operator or "=")
        if missing(having_filter.value) and missing(having_filter.value_sql)
            and op ~= "IS NULL" and op ~= "IS NOT NULL" then
            return error_result("SEMANTIC_REQUEST_015",
                "Having filter for field '" .. tostring(metric_field.name)
                .. "' requires a value or value_sql key.")
        end
        local expr = expand_metric(ctx, metric_field)
        local predicate, predicate_err = build_dimension_predicate(expr, op, having_filter.value, metric_field.data_type, having_filter.value_sql)
        if predicate_err ~= nil then
            return predicate_err
        end
        having_predicates[#having_predicates + 1] = predicate
        bound_having_filters[#bound_having_filters + 1] = {
            metric_id = metric_field.id,
            metric = metric_field.name,
            op = op,
            value = having_filter.value,
            value_sql = having_filter.value_sql,
            data_type = metric_field.data_type,
        }
    end


    local metric_base_entities = {}
    for _, planning_metric in ipairs(planning_metrics) do
        metric_base_entities[key(planning_metric.base_entity_id)] = true
        local planning_facts = {}
        collect_metric_facts(ctx, planning_metric, planning_facts, {})
        for _, planning_fact in pairs(planning_facts) do
            metric_base_entities[key(planning_fact.entity_id)] = true
        end
    end
    local metric_base_entity_count = 0
    for _, _ in pairs(metric_base_entities) do
        metric_base_entity_count = metric_base_entity_count + 1
    end
    local joins, relationship_paths = {}, {}
    if metric_base_entity_count <= 1 then
        local join_err
        joins, relationship_paths, join_err = plan_joins(ctx, needed_entities)
        if join_err ~= nil then return join_err end
        configure_relationship_requirements(ctx, joins)
    end

    local binding_ok, binding_error = select_attribute_bindings(
        ctx, all_dimensions, planning_metrics, needed_entities)
    if binding_ok == nil then
        return error_result(error_prefix .. "_080", binding_error)
    end

    -- Filters and HAVING expressions were resolved while discovering required
    -- attributes. Rebuild them after representation selection so fallback
    -- expressions are used consistently in WHERE and HAVING.
    filters, _, filter_err = build_filters(
        ctx, request.filters, selected_dimensions, needed_entities)
    if filter_err ~= nil then return filter_err end
    having_predicates = {}
    for index, bound in ipairs(bound_having_filters) do
        local metric_field = ctx.all_metric_by_id[key(bound.metric_id)]
        local source = having_list[index]
        local expression = expand_metric(ctx, metric_field)
        local predicate, predicate_err = build_dimension_predicate(
            expression, bound.op, source.value, bound.data_type, source.value_sql)
        if predicate_err ~= nil then return predicate_err end
        having_predicates[#having_predicates + 1] = predicate
    end

    local snapshot = catalog_snapshot_runtime.from_context(ctx, planning_metrics)
    local relationship_targets = {}
    for entity_id, _ in pairs(needed_entities) do
        if entity_id ~= key(ctx.object.root_entity_id) then
            relationship_targets[#relationship_targets + 1] = {
                target_entity_id = entity_id,
            }
        end
    end
    table.sort(relationship_targets, function(left, right)
        return key(left.target_entity_id) < key(right.target_entity_id)
    end)
    local bound_query = metric_plan_runtime.bind_query(
        request,
        selected_dimensions,
        selected_metrics,
        filters,
        bound_having_filters,
        relationship_targets
    )
    local typed_plan, typed_plan_error = metric_plan_runtime.logical_plan(
        request,
        snapshot,
        bound_query,
        planning_metrics
    )
    if typed_plan == nil then
        return error_result(error_prefix .. "_070",
            "Typed planning failed: " .. tostring(typed_plan_error) .. ".")
    end

    local function plan_envelope(materialization_decision, selected_materialization,
        relationship_paths)
        materialization_decision = materialization_decision or {
            candidate_count = 0,
            rejected_materializations = typed_plan.plan_kind == "MULTI_BRANCH"
                and {{reason_code = "MATERIALIZATION_BRANCH_INELIGIBLE"}} or {},
            selected_materialization = JSON_NULL,
        }
        local plan = {
            plan_version = metric_plan_runtime.PLAN_VERSION,
            logical_plan = typed_plan,
            model = model.model_name,
            version_id = model.version_id,
            version_number = model.version_number,
            object = ctx.object.name,
            metrics = {},
            metric_details = {},
            dimensions = {},
            filters = filters,
            relationship_paths = relationship_paths or {},
            selected_materialization = JSON_NULL,
            selected_materializations = materialization_decision.selected_materializations
                or {},
            materialization_decision = materialization_decision,
            validation_run_id = validation_run_id,
            warnings = {},
            selected_representations = {},
        }
        if #(ctx.relationship_identity_remaps or {}) > 0 then
            plan.relationship_identity_remaps = ctx.relationship_identity_remaps
        end
        if #(ctx.relationship_candidate_rejections or {}) > 0 then
            plan.relationship_candidate_rejections =
                ctx.relationship_candidate_rejections
        end
        if selected_materialization ~= nil then
            plan.selected_materialization = {
                materialization_id = selected_materialization.materialization_id,
                materialization_name = selected_materialization.materialization_name,
                physical_schema = selected_materialization.physical_schema,
                physical_object = selected_materialization.physical_object,
                materialization_type = selected_materialization.materialization_type,
                rollup_required = selected_materialization.rollup_required,
            }
        end
        for _, metric in ipairs(selected_metrics) do
            plan.metrics[#plan.metrics + 1] = metric.name
            local detail = {
                name = metric.name,
                metric_kind = metric.metric_kind or metric.metric_type,
                metric_type = metric.metric_type,
                input_roles = {},
            }
            for _, row in ipairs(query([[
                SELECT INPUT_ROLE, INPUT_OBJECT_TYPE, EXPRESSION_ALIAS
                FROM SYS_SEMANTIC.METRIC_INPUTS
                WHERE METRIC_ID = :metric_id
                ORDER BY ORDINAL_POSITION
            ]], {metric_id = metric.id}) or {}) do
                detail.input_roles[#detail.input_roles + 1] = {
                    role = row_value(row, "INPUT_ROLE", 1),
                    object_type = row_value(row, "INPUT_OBJECT_TYPE", 2),
                    alias = row_value(row, "EXPRESSION_ALIAS", 3),
                }
            end
            plan.metric_details[#plan.metric_details + 1] = detail
        end
        for _, dimension in ipairs(selected_dimensions) do
            plan.dimensions[#plan.dimensions + 1] = dimension.name
        end
        local representation_entity_ids = {}
        for entity_id, _ in pairs(needed_entities) do
            representation_entity_ids[#representation_entity_ids + 1] = entity_id
        end
        table.sort(representation_entity_ids, function(left, right)
            return key(left) < key(right)
        end)
        for _, entity_id in ipairs(representation_entity_ids) do
            local entity = ctx.entity_by_id[key(entity_id)]
            local selection = entity and ctx.selected_representations[key(entity.id)] or nil
            local representation = selection and selection.representation
                or entity and entity.primary_representation or nil
            if representation ~= nil then
                local selected_bindings = {}
                for attribute_key, binding in pairs(selection and selection.bindings or {}) do
                    local attribute_type, attribute_id = string.match(
                        attribute_key, "^([^:]+):(.+)$")
                    local attribute = attribute_type == "DIMENSION"
                        and ctx.dimension_by_id[key(attribute_id)]
                        or ctx.fact_by_id[key(attribute_id)]
                    selected_bindings[#selected_bindings + 1] = {
                        attribute = attribute_key,
                        attribute_binding_id = binding.id or JSON_NULL,
                        binding_role = binding.role,
                        binding_priority = binding.priority,
                        source_expression = binding.expression,
                        legacy = binding.legacy == true,
                        fusion_strategy = attribute and attribute.fusion_strategy or "PREFER",
                        fusion_contributors = attribute
                            and attribute.fusion_contributors or {},
                    }
                end
                table.sort(selected_bindings, function(left, right)
                    return left.attribute < right.attribute
                end)
                plan.selected_representations[#plan.selected_representations + 1] = {
                    entity_id = entity.id,
                    entity_name = entity.name,
                    representation_id = representation.id,
                    representation_name = representation.name,
                    source_kind = representation.source_kind,
                    source_schema = representation.source_schema,
                    source_object = representation.source_object,
                    selection_reason = (selection == nil or selection.legacy_only)
                        and "STATIC_PRIMARY"
                        or selection.fallback_count > 0 and "ATTRIBUTE_FALLBACK"
                        or "ATTRIBUTE_PREFER",
                    fallback_binding_count = selection and selection.fallback_count or 0,
                    binding_priority = selection and selection.binding_priority or 0,
                    selected_bindings = selected_bindings,
                    fusion_strategy = selection and selection.fusion_strategy or JSON_NULL,
                    partitions = {},
                }
                local selected_entry = plan.selected_representations[
                    #plan.selected_representations]
                for _, candidate in ipairs(selection and selection.candidates or {}) do
                    local candidate_representation = candidate.representation
                    selected_entry.partitions[#selected_entry.partitions + 1] = {
                        representation_id = candidate_representation.id,
                        representation_name = candidate_representation.name,
                        source_kind = candidate_representation.source_kind,
                        source_schema = candidate_representation.source_schema,
                        source_object = candidate_representation.source_object,
                        coverage_predicate = candidate_representation.coverage_predicate,
                        valid_from = candidate_representation.valid_from or JSON_NULL,
                        valid_to = candidate_representation.valid_to or JSON_NULL,
                    }
                end
            end
        end
        return plan
    end

    local function plan_error(code, message)
        local result = error_result(error_prefix .. code, message)
        result.plan_json = json_encode(plan_envelope())
        return result
    end

    if typed_plan.failure ~= nil then
        local reason = typed_plan.failure.reason_code or "TYPED_PLANNING_FAILED"
        local code = string.find(reason, "METRIC_", 1, true) == 1
            and "_070" or "_074"
        return plan_error(code, typed_failure_message(typed_plan.failure))
    end
    if typed_plan.plan_kind == "MULTI_BRANCH" then
        if ctx.has_attribute_fusion then
            return plan_error("_074",
                "F4 attribute reconciliation is not supported in a multi-fact branch plan; split the request or model a pre-reconciled canonical source.")
        end
        local physical_plan, physical_error = physical_plan_runtime.build(
            typed_plan,
            snapshot,
            {output_order_by = order_by, limit = limit}
        )
        if physical_plan == nil then
            typed_plan.failure = physical_error
            return plan_error("_075", "Physical planning failed: "
                .. tostring(physical_error.reason_code) .. ".")
        end
        local fused_plan, fusion_error = physical_plan_runtime.apply_partitioned_sources(
            physical_plan, snapshot)
        if fused_plan == nil then
            typed_plan.failure = fusion_error
            return plan_error("_075", "Fusion planning failed: "
                .. tostring(fusion_error.reason_code) .. ".")
        end
        physical_plan = fused_plan
        local branch_decision = nil
        if materialization_runtime ~= nil
            and type(materialization_runtime.select_branch_sources) == "function" then
            local selections
            selections, branch_decision =
                materialization_runtime.select_branch_sources(ctx, physical_plan)
            local rebound_plan, rebound_error =
                physical_plan_runtime.apply_branch_sources(physical_plan, selections)
            if rebound_plan == nil then
                typed_plan.failure = rebound_error
                return plan_error("_075", "Physical planning failed: "
                    .. tostring(rebound_error.reason_code) .. ".")
            end
            physical_plan = rebound_plan
            physical_plan.source_selection = branch_decision
        end
        typed_plan.physical_plan = physical_plan
        local internal_sql = grain_sql_runtime.render_multi_branch(physical_plan)
        local within_limit, size_error = physical_plan_runtime.check_sql_size(
            physical_plan,
            internal_sql
        )
        if not within_limit then
            typed_plan.failure = size_error
            return plan_error("_075", "Physical planning failed: "
                .. tostring(size_error.reason_code) .. ".")
        end
        typed_plan.execution = {status = "EXECUTABLE"}
        physical_plan.execution = {status = "EXECUTABLE"}
        local plan = plan_envelope(branch_decision)
        local result = attach_planning_runtime(
            ok_result(internal_sql, plan, validation_run_id), planning_started_ms)
        if cache_key ~= nil then
            cache_store(model.version_id, cache_key, result)
        end
        return result, request, model
    end
    if request.proof_mode == "STRICT_GRAIN" then
        for _, proof in ipairs(typed_plan.relationship_proofs or {}) do
            if proof.status ~= "PROVEN" then
                return plan_error("_072", "Strict grain proof failed: "
                    .. tostring(proof.reason_code or proof.reason) .. ".")
            end
        end
    end

    local matrix_err = validate_metric_dimensions(ctx, selected_metrics, all_dimensions)
    if matrix_err ~= nil then
        return matrix_err
    end

    local selected_materialization = nil
    local materialization_decision = {
        candidate_count = 0,
        rejected_materializations = {},
        selected_materialization = JSON_NULL,
    }
    -- Aggregate materializations exist to serve metric aggregations. A
    -- dimension-only discovery request (#selected_metrics == 0) bypasses
    -- the selector and falls through to base-source SQL so distinct
    -- dimension values come from the authoritative source.
    if materialization_runtime ~= nil
        and type(materialization_runtime.select_materialization) == "function"
        and #having_predicates == 0
        and #selected_metrics > 0
        and not ctx.has_attribute_fusion then
        selected_materialization, materialization_decision = materialization_runtime.select_materialization(
            ctx,
            selected_dimensions,
            selected_metrics,
            filter_dimensions
        )
    end

    local sql_text
    if selected_materialization ~= nil then
        sql_text = build_materialized_sql(ctx, selected_dimensions, selected_metrics, filters, order_by, limit, selected_materialization)
    else
        sql_text = build_sql(ctx, selected_dimensions, selected_metrics, filters, joins, order_by, limit, having_predicates)
    end

    local plan = plan_envelope(materialization_decision, selected_materialization,
        relationship_paths)
    local result = attach_planning_runtime(
        ok_result(sql_text, plan, validation_run_id), planning_started_ms)
    if cache_key ~= nil then
        cache_store(model.version_id, cache_key, result)
    end
    return result, request, model
end

local function compile_internal(request_json)
    local decoded, request = pcall(json_decode, request_json)
    if not decoded then
        return error_result("SEMANTIC_REQUEST_001", "Invalid request JSON: " .. tostring(request) .. ".")
    end
    if type(request) ~= "table" or is_array(request) then
        return error_result("SEMANTIC_REQUEST_001", "Request JSON must be an object.")
    end
    local request_key_error = validate_structured_request_keys(request)
    if request_key_error ~= nil then
        return request_key_error, request, nil
    end
    -- Compile reuses the latest successful validation run for the active model version.
    -- PUBLISH_MODEL (and VALIDATE_MODEL) own the writes to VALIDATION_RUNS,
    -- METRIC_DEPENDENCIES, and METRIC_DIMENSION_MATRIX. Re-running them on every
    -- compile produced transaction collisions under concurrent load (BUG-001).
    return compile_request_table(request, {validate = false, error_prefix = "SEMANTIC_REQUEST"})
end

local function decode_quoted_identifier(token)
    local text = tostring(token)
    if string.sub(text, 1, 1) ~= '"' then
        return text
    end
    local inner = string.sub(text, 2, -2)
    return string.gsub(inner, '""', '"')
end

local function sql_tokens(sql_text)
    local tokens = {}
    local text = tostring(sql_text)
    local i = 1
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if string.match(c, "%s") then
            i = i + 1
        elseif c == "-" and n == "-" then
            i = i + 2
            while i <= #text and string.sub(text, i, i) ~= "\n" do
                i = i + 1
            end
        elseif c == "/" and n == "*" then
            i = i + 2
            while i <= #text - 1 and string.sub(text, i, i + 1) ~= "*/" do
                i = i + 1
            end
            i = math.min(i + 2, #text + 1)
        elseif c == "'" then
            local start_pos = i
            i = i + 1
            while i <= #text do
                c = string.sub(text, i, i)
                n = string.sub(text, i + 1, i + 1)
                if c == "'" and n == "'" then
                    i = i + 2
                elseif c == "'" then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1), kind = "literal"}
        elseif c == '"' then
            local start_pos = i
            i = i + 1
            while i <= #text do
                c = string.sub(text, i, i)
                n = string.sub(text, i + 1, i + 1)
                if c == '"' and n == '"' then
                    i = i + 2
                elseif c == '"' then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            local token_text = string.sub(text, start_pos, i - 1)
            tokens[#tokens + 1] = {text = token_text, kind = "identifier", value = decode_quoted_identifier(token_text)}
        elseif string.match(c, "[A-Za-z_]") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[A-Za-z0-9_]") do
                i = i + 1
            end
            local token_text = string.sub(text, start_pos, i - 1)
            tokens[#tokens + 1] = {text = token_text, kind = "word", value = token_text, upper = upper(token_text)}
        elseif string.match(c, "%d") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[0-9.]") do
                i = i + 1
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1), kind = "number"}
        else
            local two = string.sub(text, i, i + 1)
            if two == ">=" or two == "<=" or two == "<>" or two == "!=" then
                tokens[#tokens + 1] = {text = two, kind = "operator", upper = two}
                i = i + 2
            else
                tokens[#tokens + 1] = {text = c, kind = "symbol", upper = c}
                i = i + 1
            end
        end
    end
    if #tokens > 0 and tokens[#tokens].text == ";" then
        table.remove(tokens, #tokens)
    end
    return tokens
end

local function token_upper(token)
    if token == nil then
        return nil
    end
    return token.upper or upper(token.text)
end

local function token_identifier_value(token)
    if token == nil then
        return nil
    end
    if token.kind == "identifier" or token.kind == "word" then
        return token.value or token.text
    end
    return nil
end

local function split_top_level(tokens, start_index, end_index, separator)
    local parts = {}
    local current = {}
    local depth = 0
    for i = start_index, end_index do
        local token = tokens[i]
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        end
        if depth == 0 and token.text == separator then
            parts[#parts + 1] = current
            current = {}
        else
            current[#current + 1] = token
        end
    end
    if #current > 0 then
        parts[#parts + 1] = current
    end
    return parts
end

-- Databricks metric views wrap measures in MEASURE(...) (or its agg() synonym)
-- in SELECT / HAVING / ORDER BY. Unwrap that call to the bare semantic field name
-- so the rest of the parser treats it like any other metric reference. Returns the
-- (possibly rewritten) token list and whether a wrapper was actually removed.
local function unwrap_measure_part(part)
    if part == nil or #part < 4 then
        return part, false
    end
    local head = token_upper(part[1])
    if (head ~= "MEASURE" and head ~= "AGG") or part[2].text ~= "(" then
        return part, false
    end
    local depth = 0
    local close_index = nil
    for i = 2, #part do
        local text = part[i].text
        if text == "(" then
            depth = depth + 1
        elseif text == ")" then
            depth = depth - 1
            if depth == 0 then
                close_index = i
                break
            end
        end
    end
    -- Require a non-empty argument and a matching close paren.
    if close_index == nil or close_index <= 3 then
        return part, false
    end
    local rewritten = {}
    for i = 3, close_index - 1 do
        rewritten[#rewritten + 1] = part[i]
    end
    for i = close_index + 1, #part do
        rewritten[#rewritten + 1] = part[i]
    end
    return rewritten, true
end

local function identifier_from_part(part)
    part = unwrap_measure_part(part)
    if #part == 0 then
        return nil
    end
    local end_index = #part
    for i, token in ipairs(part) do
        if token_upper(token) == "AS" then
            end_index = i - 1
            break
        end
    end
    if end_index >= 3 and part[end_index - 1].text == "." then
        return token_identifier_value(part[end_index])
    end
    if end_index == 1 then
        return token_identifier_value(part[1])
    end
    if end_index >= 1 and (part[1].kind == "word" or part[1].kind == "identifier") then
        if end_index == 2 and (part[2].kind == "word" or part[2].kind == "identifier") then
            return token_identifier_value(part[1])
        end
    end
    return nil
end

local function alias_from_select_part(part)
    for i, token in ipairs(part) do
        if token_upper(token) == "AS" and part[i + 1] ~= nil then
            return token_identifier_value(part[i + 1])
        end
    end
    if #part == 2 and (part[1].kind == "word" or part[1].kind == "identifier") and (part[2].kind == "word" or part[2].kind == "identifier") then
        return token_identifier_value(part[2])
    end
    return nil
end

local function literal_from_tokens(tokens)
    if #tokens == 1 then
        local token = tokens[1]
        if token.kind == "literal" then
            local raw = string.sub(token.text, 2, -2)
            return string.gsub(raw, "''", "'")
        elseif token.kind == "number" then
            return tonumber(token.text) or token.text
        elseif token.kind == "word" then
            return token.value
        end
    elseif #tokens == 2 and token_upper(tokens[1]) == "DATE" and tokens[2].kind == "literal" then
        local raw = string.sub(tokens[2].text, 2, -2)
        return string.gsub(raw, "''", "'")
    elseif #tokens == 2 and token_upper(tokens[1]) == "TIMESTAMP" and tokens[2].kind == "literal" then
        local raw = string.sub(tokens[2].text, 2, -2)
        return string.gsub(raw, "''", "'")
    end
    return nil
end

local function find_top_level_clauses(tokens)
    local clauses = {}
    local depth = 0
    for i, token in ipairs(tokens) do
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif depth == 0 then
            local u = token_upper(token)
            if u == "FROM" or u == "WHERE" or u == "LIMIT" or u == "HAVING" then
                clauses[u] = clauses[u] or i
            elseif u == "GROUP" and token_upper(tokens[i + 1]) == "BY" then
                clauses.GROUP_BY = clauses.GROUP_BY or i
            elseif u == "ORDER" and token_upper(tokens[i + 1]) == "BY" then
                clauses.ORDER_BY = clauses.ORDER_BY or i
            end
        end
    end
    return clauses
end

local function clause_end(tokens, clauses, current_name)
    local start_index = clauses[current_name]
    local best = #tokens + 1
    for _, candidate in ipairs({"FROM", "WHERE", "GROUP_BY", "HAVING", "ORDER_BY", "LIMIT"}) do
        local pos = clauses[candidate]
        if pos ~= nil and pos > start_index and pos < best then
            best = pos
        end
    end
    return best - 1
end

local function token_slice(tokens, first, last)
    local out = {}
    for i = first, last do
        out[#out + 1] = tokens[i]
    end
    return out
end

local function render_token_slice(tokens)
    local parts = {}
    for _, token in ipairs(tokens or {}) do
        parts[#parts + 1] = token.text
    end
    return table.concat(parts, " ")
end

local binary_predicate_operators = {
    ["IN"] = true, ["BETWEEN"] = true, ["LIKE"] = true,
    ["="] = true, ["!="] = true, ["<>"] = true,
    [">"] = true, [">="] = true, ["<"] = true, ["<="] = true,
}

local function predicate_operator_at(tokens, index)
    local current = token_upper(tokens[index])
    if current == "IS" then
        if token_upper(tokens[index + 1]) == "NULL" then
            return "IS NULL"
        end
        if token_upper(tokens[index + 1]) == "NOT"
            and token_upper(tokens[index + 2]) == "NULL" then
            return "IS NOT NULL"
        end
        return "IS"
    end
    if binary_predicate_operators[current] then
        return current
    end
    return nil
end

local function parse_where_filters(tokens, start_index, end_index)
    local filters = {}
    local chunks = {}
    -- Split on top-level AND conjunctions, but skip the AND that belongs to a
    -- BETWEEN...AND range (e.g. "field BETWEEN v1 AND v2").
    local current_start = start_index
    local depth = 0
    local after_between = false
    local i = start_index
    while i <= end_index do
        local token = tokens[i]
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif depth == 0 then
            local u = token_upper(token)
            if u == "BETWEEN" then
                after_between = true
            elseif u == "AND" then
                if after_between then
                    after_between = false
                else
                    chunks[#chunks + 1] = {current_start, i - 1}
                    current_start = i + 1
                end
            end
        end
        i = i + 1
    end
    chunks[#chunks + 1] = {current_start, end_index}

    for _, chunk in ipairs(chunks) do
        local first = chunk[1]
        local last = chunk[2]
        local op_index = nil
        local op = nil
        for idx = first, last do
            local candidate = predicate_operator_at(tokens, idx)
            if candidate ~= nil then
                op_index = idx
                op = candidate
                break
            end
        end
        if op_index == nil then
            return nil, error_result("SEMANTIC_QUERY_030", "Unsupported WHERE predicate.")
        end
        local field = identifier_from_part(token_slice(tokens, first, op_index - 1))
        if field == nil then
            return nil, error_result("SEMANTIC_QUERY_031", "WHERE predicate must start with a semantic dimension.")
        end
        if op == "IS NULL" or op == "IS NOT NULL" then
            local expected_last = op_index + (op == "IS NULL" and 1 or 2)
            if last ~= expected_last then
                return nil, error_result("SEMANTIC_QUERY_036",
                    "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
            end
            filters[#filters + 1] = {field = field, op = op}
        elseif op == "IS" then
            return nil, error_result("SEMANTIC_QUERY_036",
                "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
        elseif op == "IN" then
            if tokens[op_index + 1] == nil or tokens[op_index + 1].text ~= "(" or tokens[last].text ~= ")" then
                return nil, error_result("SEMANTIC_QUERY_032", "IN predicate requires a literal list.")
            end
            local values = {}
            for _, part in ipairs(split_top_level(tokens, op_index + 2, last - 1, ",")) do
                local value = literal_from_tokens(part)
                if value == nil then
                    return nil, error_result("SEMANTIC_QUERY_033", "IN predicate supports literal values only.")
                end
                values[#values + 1] = value
            end
            filters[#filters + 1] = {field = field, op = "IN", value = values}
        elseif op == "BETWEEN" then
            local and_index = nil
            for idx = op_index + 1, last do
                if token_upper(tokens[idx]) == "AND" then
                    and_index = idx
                    break
                end
            end
            if and_index == nil then
                return nil, error_result("SEMANTIC_QUERY_034", "BETWEEN predicate requires 'field BETWEEN value1 AND value2'.")
            end
            local v1 = literal_from_tokens(token_slice(tokens, op_index + 1, and_index - 1))
            local v2 = literal_from_tokens(token_slice(tokens, and_index + 1, last))
            if v1 == nil or v2 == nil then
                return nil, error_result("SEMANTIC_QUERY_035", "BETWEEN predicate requires two literal values.")
            end
            filters[#filters + 1] = {field = field, op = "BETWEEN", value = {v1, v2}}
        else
            local value_tokens = token_slice(tokens, op_index + 1, last)
            local value = literal_from_tokens(value_tokens)
            if value == nil then
                local value_sql = trim(render_token_slice(value_tokens))
                if value_sql == "" then
                    return nil, error_result("SEMANTIC_QUERY_033", "WHERE predicate requires a right-hand value.")
                end
                filters[#filters + 1] = {field = field, op = op, value = null, value_sql = value_sql}
            else
                filters[#filters + 1] = {field = field, op = op, value = value}
            end
        end
    end
    return filters, nil
end

local function parse_having_filters(ctx, tokens, start_index, end_index)
    local filters = {}
    local chunks = {}
    local current_start = start_index
    local depth = 0
    local after_between = false
    local i = start_index
    while i <= end_index do
        local token = tokens[i]
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif depth == 0 then
            local u = token_upper(token)
            if u == "BETWEEN" then
                after_between = true
            elseif u == "AND" then
                if after_between then
                    after_between = false
                else
                    chunks[#chunks + 1] = {current_start, i - 1}
                    current_start = i + 1
                end
            end
        end
        i = i + 1
    end
    chunks[#chunks + 1] = {current_start, end_index}

    for _, chunk in ipairs(chunks) do
        local first = chunk[1]
        local last = chunk[2]
        local op_index = nil
        local op = nil
        for idx = first, last do
            local candidate = predicate_operator_at(tokens, idx)
            if candidate ~= nil then
                op_index = idx
                op = candidate
                break
            end
        end
        if op_index == nil then
            return nil, error_result("SEMANTIC_QUERY_030", "Unsupported HAVING predicate.")
        end
        local field = identifier_from_part(token_slice(tokens, first, op_index - 1))
        if field == nil then
            return nil, error_result("SEMANTIC_QUERY_031", "HAVING predicate must start with a semantic metric.")
        end
        local resolved, resolve_err = resolve_field(ctx, field, nil)
        if resolve_err ~= nil then
            return nil, recode_error_prefix(resolve_err, "SEMANTIC_QUERY")
        end
        if resolved.kind ~= "METRIC" then
            return nil, error_result("SEMANTIC_QUERY_040", "HAVING supports metric predicates only. Use WHERE for dimension filters.")
        end
        if op == "IS NULL" or op == "IS NOT NULL" then
            local expected_last = op_index + (op == "IS NULL" and 1 or 2)
            if last ~= expected_last then
                return nil, error_result("SEMANTIC_QUERY_036",
                    "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
            end
            filters[#filters + 1] = {field = resolved.name, op = op}
        elseif op == "IS" then
            return nil, error_result("SEMANTIC_QUERY_036",
                "Null predicate requires exactly 'field IS NULL' or 'field IS NOT NULL'.")
        elseif op == "IN" then
            if tokens[op_index + 1] == nil or tokens[op_index + 1].text ~= "(" or tokens[last].text ~= ")" then
                return nil, error_result("SEMANTIC_QUERY_032", "IN predicate requires a literal list.")
            end
            local values = {}
            for _, part in ipairs(split_top_level(tokens, op_index + 2, last - 1, ",")) do
                local value = literal_from_tokens(part)
                if value == nil then
                    return nil, error_result("SEMANTIC_QUERY_033", "IN predicate supports literal values only.")
                end
                values[#values + 1] = value
            end
            filters[#filters + 1] = {field = resolved.name, op = "IN", value = values}
        elseif op == "BETWEEN" then
            local and_index = nil
            for idx = op_index + 1, last do
                if token_upper(tokens[idx]) == "AND" then
                    and_index = idx
                    break
                end
            end
            if and_index == nil then
                return nil, error_result("SEMANTIC_QUERY_034", "BETWEEN predicate requires 'field BETWEEN value1 AND value2'.")
            end
            local v1 = literal_from_tokens(token_slice(tokens, op_index + 1, and_index - 1))
            local v2 = literal_from_tokens(token_slice(tokens, and_index + 1, last))
            if v1 == nil or v2 == nil then
                return nil, error_result("SEMANTIC_QUERY_035", "BETWEEN predicate requires two literal values.")
            end
            filters[#filters + 1] = {field = resolved.name, op = "BETWEEN", value = {v1, v2}}
        else
            local value_tokens = token_slice(tokens, op_index + 1, last)
            local value = literal_from_tokens(value_tokens)
            if value == nil then
                local value_sql = trim(render_token_slice(value_tokens))
                if value_sql == "" then
                    return nil, error_result("SEMANTIC_QUERY_033", "HAVING predicate requires a right-hand value.")
                end
                filters[#filters + 1] = {field = resolved.name, op = op, value = null, value_sql = value_sql}
            else
                filters[#filters + 1] = {field = resolved.name, op = op, value = value}
            end
        end
    end
    return filters, nil
end

local function parse_order_by(tokens, start_index, end_index, select_aliases, selected_output)
    local order_by = {}
    for _, part in ipairs(split_top_level(tokens, start_index, end_index, ",")) do
        local direction = "ASC"
        if #part > 1 then
            local last = token_upper(part[#part])
            if last == "ASC" or last == "DESC" then
                direction = last
                table.remove(part, #part)
            end
        end
        local field = identifier_from_part(part)
        if field == nil and #part == 1 and part[1].kind == "number" then
            local ordinal = tonumber(part[1].text)
            if selected_output ~= nil then
                field = selected_output[ordinal]
            end
        end
        if field == nil then
            return nil, error_result("SEMANTIC_QUERY_060", "ORDER BY supports selected semantic fields only.")
        end
        if select_aliases ~= nil and select_aliases[upper(field)] ~= nil then
            field = select_aliases[upper(field)]
        end
        order_by[#order_by + 1] = {field = field, direction = direction}
    end
    return order_by, nil
end

local function parse_semantic_sql(sql_text, options)
    options = options or {}
    local tokens = sql_tokens(sql_text)
    if #tokens == 0 then
        if options.unchanged_nonsemantic then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_001", "SQL text is required.")
    end
    if token_upper(tokens[1]) ~= "SELECT" then
        if options.unchanged_nonsemantic then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_009", "Only top-level SELECT semantic SQL is supported.")
    end
    local clauses = find_top_level_clauses(tokens)
    if clauses.FROM == nil then
        return nil, error_result("SEMANTIC_QUERY_002", "Semantic SQL requires a FROM clause.")
    end
    local select_end = clauses.FROM - 1
    local from_end = clause_end(tokens, clauses, "FROM")
    local from_tokens = token_slice(tokens, clauses.FROM + 1, from_end)
    if #from_tokens < 3 or from_tokens[2].text ~= "." then
        if options.unchanged_unknown_schema then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
    end
    local published_schema = token_identifier_value(from_tokens[1])
    local object_name = token_identifier_value(from_tokens[3])
    if published_schema == nil or object_name == nil then
        if options.unchanged_unknown_schema then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
    end
    local model = load_model_by_published_schema(published_schema)
    if model == nil then
        if options.unchanged_unknown_schema then
            return unchanged_result(sql_text), nil, nil
        end
        return nil, error_result("SEMANTIC_QUERY_004", "No semantic model is published to schema " .. tostring(published_schema) .. ".")
    end
    if options.unchanged_unknown_schema and upper(object_name) == "SEMANTIC_DISCOVERY" then
        return unchanged_result(sql_text), nil, model
    end
    if #from_tokens > 3 then
        local alias_ok = #from_tokens == 4 and token_identifier_value(from_tokens[4]) ~= nil
        local as_alias_ok = #from_tokens == 5 and token_upper(from_tokens[4]) == "AS" and token_identifier_value(from_tokens[5]) ~= nil
        if not alias_ok and not as_alias_ok then
            return nil, error_result("SEMANTIC_QUERY_003", "FROM must reference one published semantic object as schema.object.")
        end
    end

    local ctx, load_code, load_message = load_catalog(model, object_name)
    if ctx == nil then
        return nil, recode_error_prefix(error_result(load_code, load_message), "SEMANTIC_QUERY")
    end

    local request = {
        model = model.model_name,
        object = object_name,
        metrics = {},
        dimensions = {},
        filters = {},
        having = {},
        order_by = {},
        client = "semantic-sql",
        purpose = "semantic_sql",
    }
    local selected_output = {}
    local select_aliases = {}
    local selected_dimension_seen = {}
    local selected_metric_seen = {}
    local select_parts = split_top_level(tokens, 2, select_end, ",")
    local wildcard_select = #select_parts == 1 and #select_parts[1] == 1 and select_parts[1][1].text == "*"
    if wildcard_select then
        for _, field in ipairs(ctx.dimensions) do
            selected_output[#selected_output + 1] = field.name
            request.dimensions[#request.dimensions + 1] = field.name
            selected_dimension_seen[upper(field.name)] = true
        end
        for _, field in ipairs(ctx.metrics) do
            selected_output[#selected_output + 1] = field.name
            request.metrics[#request.metrics + 1] = field.name
            selected_metric_seen[upper(field.name)] = true
        end
    end
    for _, part in ipairs(wildcard_select and {} or select_parts) do
        local _, measure_wrapped = unwrap_measure_part(part)
        local field_name = identifier_from_part(part)
        if field_name == nil then
            return nil, error_result("SEMANTIC_QUERY_005", "SELECT supports semantic field names, MEASURE(metric), or *.")
        end
        local field, bind_err = resolve_field(ctx, field_name, nil)
        if bind_err ~= nil then
            return nil, recode_error_prefix(bind_err, "SEMANTIC_QUERY")
        end
        if measure_wrapped and field.kind ~= "METRIC" then
            return nil, error_result("SEMANTIC_QUERY_006", "MEASURE()/agg() may only wrap a metric, not '" .. tostring(field.name) .. "'.")
        end
        selected_output[#selected_output + 1] = field.name
        local output_alias = alias_from_select_part(part)
        if output_alias ~= nil then
            select_aliases[upper(output_alias)] = field.name
        end
        if field.kind == "DIMENSION" then
            if not selected_dimension_seen[upper(field.name)] then
                request.dimensions[#request.dimensions + 1] = field.name
                selected_dimension_seen[upper(field.name)] = true
            end
        elseif field.kind == "METRIC" then
            if not selected_metric_seen[upper(field.name)] then
                request.metrics[#request.metrics + 1] = field.name
                selected_metric_seen[upper(field.name)] = true
            end
        else
            return nil, error_result("SEMANTIC_QUERY_006", "Unsupported semantic field kind in SELECT.")
        end
    end

    if clauses.WHERE ~= nil then
        local raw_filters, filter_err = parse_where_filters(tokens, clauses.WHERE + 1, clause_end(tokens, clauses, "WHERE"))
        if filter_err ~= nil then
            return nil, filter_err
        end
        for _, filter in ipairs(raw_filters) do
            local field, _ = resolve_field(ctx, filter.field, nil)
            if field ~= nil and field.kind == "METRIC" then
                request.having[#request.having + 1] = filter
            else
                request.filters[#request.filters + 1] = filter
            end
        end
    end

    -- Databricks idiom: GROUP BY ALL groups by every non-aggregated SELECT column.
    -- Detect the single-token ALL form and let the selected dimensions stand in for
    -- the explicit grouping list.
    local is_group_by_all = false
    if clauses.GROUP_BY ~= nil then
        local gb_start = clauses.GROUP_BY + 2
        local gb_end = clause_end(tokens, clauses, "GROUP_BY")
        is_group_by_all = (gb_end == gb_start) and token_upper(tokens[gb_start]) == "ALL"
    end

    if #request.dimensions > 0 and not wildcard_select then
        -- GROUP BY is optional: when omitted, it is inferred from the selected
        -- dimensions (build_sql emits GROUP BY from request.dimensions regardless
        -- of the typed clause). When a GROUP BY *is* supplied, it must be either
        -- GROUP BY ALL or exactly cover the selected dimensions.
        if clauses.GROUP_BY ~= nil and not is_group_by_all then
            local grouped = {}
            for _, part in ipairs(split_top_level(tokens, clauses.GROUP_BY + 2, clause_end(tokens, clauses, "GROUP_BY"), ",")) do
                local field_name = identifier_from_part(part)
                if field_name == nil and #part == 1 and part[1].kind == "number" then
                    local ordinal = tonumber(part[1].text)
                    field_name = selected_output[ordinal]
                end
                if field_name == nil then
                    return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY supports selected dimensions by name or ordinal.")
                end
                local field, bind_err = resolve_field(ctx, field_name, "DIMENSION")
                if bind_err ~= nil then
                    return nil, recode_error_prefix(bind_err, "SEMANTIC_QUERY")
                end
                grouped[upper(field.name)] = true
            end
            for _, dimension_name in ipairs(request.dimensions) do
                if not grouped[upper(dimension_name)] then
                    return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY must cover selected dimension " .. tostring(dimension_name) .. ".")
                end
            end
            local group_count = 0
            for _, _ in pairs(grouped) do
                group_count = group_count + 1
            end
            if group_count ~= #request.dimensions then
                return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY must not contain dimensions outside the SELECT list.")
            end
        end
    elseif #request.dimensions == 0 and clauses.GROUP_BY ~= nil and not is_group_by_all then
        return nil, error_result("SEMANTIC_QUERY_008", "GROUP BY is only supported for selected dimensions.")
    end

    if clauses.HAVING ~= nil then
        local having_filters, having_err = parse_having_filters(ctx, tokens, clauses.HAVING + 1, clause_end(tokens, clauses, "HAVING"))
        if having_err ~= nil then
            return nil, having_err
        end
        for _, f in ipairs(having_filters) do
            request.having[#request.having + 1] = f
        end
    end

    if clauses.ORDER_BY ~= nil then
        local order_by, order_err = parse_order_by(tokens, clauses.ORDER_BY + 2, clause_end(tokens, clauses, "ORDER_BY"), select_aliases, selected_output)
        if order_err ~= nil then
            return nil, order_err
        end
        request.order_by = order_by
    end

    if clauses.LIMIT ~= nil then
        local limit_start = clauses.LIMIT + 1
        local limit_end = clause_end(tokens, clauses, "LIMIT")
        if limit_start ~= limit_end or tokens[limit_start].kind ~= "number" then
            return nil, error_result("SEMANTIC_QUERY_050", "LIMIT must be a positive integer literal.")
        end
        request.limit = tonumber(tokens[limit_start].text)
    end
    return request, nil, model
end

local function compile_sql_internal(sql_text, options)
    options = options or {}
    local request, parse_err, model = parse_semantic_sql(sql_text, {
        unchanged_nonsemantic = options.unchanged_nonsemantic,
        unchanged_unknown_schema = options.unchanged_unknown_schema,
    })
    if parse_err ~= nil then
        return parse_err, nil, nil
    end
    if request ~= nil and request.status == "UNCHANGED" then
        return request, nil, nil
    end
    local result, compiled_request, compiled_model = compile_request_table(request, {
        model = model,
        validate = options.validate,
        error_prefix = "SEMANTIC_QUERY",
        source = "SEMANTIC_SQL",
    })
    if result ~= nil and result.status ~= "OK" then
        recode_error_prefix(result, "SEMANTIC_QUERY")
    end
    return result, compiled_request, compiled_model
end

local function collision_error(msg)
    -- SEMANTIC_REQUEST_100 / SEMANTIC_QUERY_100: transient transaction collision - safe to retry.
    return string.find(msg, "GlobalTransactionRollback", 1, true) ~= nil
        or string.find(msg, "Transaction collision", 1, true) ~= nil
end

-- Bounded retry for transient transaction collisions. After the validator-skip
-- fix (BUG-001) the residual contention is the AGENT_REQUEST_LOG / QUERY_LOG
-- insert. Two retries with a tiny busy backoff are sufficient in practice.
-- Exasol Lua has no sleep, so we burn a small amount of CPU to let the
-- competing transaction commit before retrying.
local COLLISION_RETRIES = 2

local function busy_backoff()
    local budget = 0
    for _ = 1, 200000 do
        budget = budget + 1
    end
    return budget
end

function M.compile_sql(sql_text)
    -- See compile_internal: reuse the latest successful validation run instead of
    -- re-running the validator on every compile (BUG-001).
    local ok, result, request, model
    for attempt = 0, COLLISION_RETRIES do
        ok, result, request, model = pcall(compile_sql_internal, sql_text, {validate = false})
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_QUERY_100" or "SEMANTIC_QUERY_999"
        return error_result(code, msg), nil, nil
    end
    return result, request, model
end

function M.compile_sql_debug(sql_text, client_name)
    local result, request, model = M.compile_sql(sql_text)
    log_query_result(result, sql_text, request, model, client_name)
    return result, request, model
end

function M.compile_sql_for_preprocessor(sql_text)
    local upper_sql = upper(sql_text or "")
    if string.find(upper_sql, "SELECT", 1, true) == nil or string.find(upper_sql, "FROM", 1, true) == nil then
        return {status = "UNCHANGED", generated_sql = sql_text}
    end
    local options = {
        validate = false,
        unchanged_nonsemantic = true,
        unchanged_unknown_schema = true,
    }
    local ok, result
    for attempt = 0, COLLISION_RETRIES do
        ok, result = pcall(compile_sql_internal, sql_text, options)
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_QUERY_100" or "SEMANTIC_QUERY_999"
        return error_result(code, msg)
    end
    return result
end

function M.compile_request_json(request_json)
    local ok, result, request, model
    for attempt = 0, COLLISION_RETRIES do
        ok, result, request, model = pcall(compile_internal, request_json)
        if ok then break end
        if not collision_error(tostring(result)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    if not ok then
        local msg = tostring(result)
        local code = collision_error(msg) and "SEMANTIC_REQUEST_100" or "SEMANTIC_REQUEST_999"
        result = error_result(code, msg)
        request = nil
        model = nil
    end
    -- log_request inserts into AGENT_REQUEST_LOG and can itself collide under
    -- concurrent load. Retry the same way so the caller keeps STATUS=OK and a
    -- usable agent_request_id. If it still fails, leave the compile result
    -- intact - the generated SQL is still executable.
    for attempt = 0, COLLISION_RETRIES do
        local log_ok, log_err = pcall(log_request, result, request_json, request, model)
        if log_ok then break end
        if not collision_error(tostring(log_err)) then break end
        if attempt < COLLISION_RETRIES then busy_backoff() end
    end
    return result
end

-- Dry-run migration assistance for legacy primary-key and equality-join
-- metadata. Suggestions are deliberately limited to unambiguous column forms.
function M.suggest_grain_metadata(model_name)
    local model = load_model(normalize_name(model_name, "model"))
    if model == nil then
        return {{"ERROR", tostring(model_name), "MODEL_NOT_FOUND", null}}
    end
    local suggestions = {}
    local entities = query([[
        SELECT e.ENTITY_ID, e.ENTITY_NAME, er.SOURCE_ALIAS, e.PRIMARY_KEY_EXPR
        FROM SYS_SEMANTIC.ENTITIES e
        JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
          ON er.ENTITY_ID = e.ENTITY_ID
         AND er.MODEL_ID = e.MODEL_ID
         AND er.VERSION_ID = e.VERSION_ID
         AND er.REPRESENTATION_ROLE = 'PRIMARY'
         AND er.STATUS = 'ACTIVE'
        WHERE e.MODEL_ID = :model_id
          AND e.VERSION_ID = :version_id
          AND e.STATUS = 'ACTIVE'
        ORDER BY e.ENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    local alias_by_id = {}
    for _, row in ipairs(entities or {}) do
        local entity_id = row_value(row, "ENTITY_ID", 1)
        local entity_name = row_value(row, "ENTITY_NAME", 2)
        local alias = row_value(row, "SOURCE_ALIAS", 3)
        local expression = row_value(row, "PRIMARY_KEY_EXPR", 4)
        alias_by_id[key(entity_id)] = alias
        local clean = tostring(expression or ""):gsub('"', "")
        local expression_alias, column_name =
            string.match(clean, "^%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*$")
        if expression_alias ~= nil and upper(expression_alias) == upper(alias) then
            local existing = scalar([[
                SELECT COUNT(*)
                FROM SYS_SEMANTIC.UNIQUE_KEYS
                WHERE MODEL_ID = :model_id
                  AND VERSION_ID = :version_id
                  AND ENTITY_ID = :entity_id
                  AND STATUS = 'ACTIVE'
            ]], {
                model_id = model.model_id,
                version_id = model.version_id,
                entity_id = entity_id,
            })
            if tonumber(existing or 0) == 0 then
                suggestions[#suggestions + 1] = {
                    "UNIQUE_KEY",
                    entity_name,
                    "LEGACY_PRIMARY_KEY_EXPR",
                    json_encode({
                        key_name = tostring(entity_name) .. "_pk",
                        key_kind = "PRIMARY",
                        columns = {{ordinal_position = 1, column_name = column_name}},
                    }),
                }
            end
        end
    end

    local relationships = query([[
        SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
               JOIN_CONDITION
        FROM SYS_SEMANTIC.RELATIONSHIPS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY RELATIONSHIP_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(relationships or {}) do
        local relationship_id = row_value(row, "RELATIONSHIP_ID", 1)
        local relationship_name = row_value(row, "RELATIONSHIP_NAME", 2)
        local from_entity_id = row_value(row, "FROM_ENTITY_ID", 3)
        local to_entity_id = row_value(row, "TO_ENTITY_ID", 4)
        local condition = tostring(row_value(row, "JOIN_CONDITION", 5) or ""):gsub('"', "")
        local left_alias, left_column, right_alias, right_column =
            string.match(condition,
                "^%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*=%s*([A-Za-z_][A-Za-z0-9_]*)%.([A-Za-z_][A-Za-z0-9_]*)%s*$")
        if left_alias ~= nil then
            local from_alias = alias_by_id[key(from_entity_id)]
            local to_alias = alias_by_id[key(to_entity_id)]
            local from_column
            local to_column
            if upper(left_alias) == upper(from_alias) and upper(right_alias) == upper(to_alias) then
                from_column, to_column = left_column, right_column
            elseif upper(right_alias) == upper(from_alias) and upper(left_alias) == upper(to_alias) then
                from_column, to_column = right_column, left_column
            end
            local existing = scalar([[
                SELECT COUNT(*)
                FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
                WHERE RELATIONSHIP_ID = :relationship_id
            ]], {relationship_id = relationship_id})
            if from_column ~= nil and tonumber(existing or 0) == 0 then
                suggestions[#suggestions + 1] = {
                    "RELATIONSHIP_MAPPING",
                    relationship_name,
                    "SIMPLE_EQUALITY_JOIN",
                    json_encode({
                        ordinal_position = 1,
                        from_column_name = from_column,
                        to_column_name = to_column,
                    }),
                }
            end
        end
    end
    if #suggestions == 0 then
        suggestions[1] = {"NONE", model.model_name, "NO_SAFE_SUGGESTIONS", null}
    end
    return suggestions
end

compile_request_json = M.compile_request_json
compile_sql = M.compile_sql
compile_sql_debug = M.compile_sql_debug
compile_sql_for_preprocessor = M.compile_sql_for_preprocessor
suggest_grain_metadata = M.suggest_grain_metadata

-- Database-free tests opt into this deliberately small pure-function surface.
-- Exasol never defines ESV_TEST_MODE, so the installed runtime's public API is
-- unchanged. Keeping the seam here lets the unit suite exercise parser,
-- normalization, expression, and predicate behavior without mocking a whole
-- database catalog.
if rawget(_G, "ESV_TEST_MODE") then
    ESV_COMPILER_TEST_API = {
        json_encode = json_encode,
        json_decode = json_decode,
        canonical_request_text = canonical_request_text,
        compile_cache_key = compile_cache_key,
        quote_ident = quote_ident,
        quote_qualified = quote_qualified,
        sql_literal = sql_literal,
        resolve_field = resolve_field,
        relationship_edges = relationship_edges,
        find_path = find_path,
        strip_string_literals = strip_string_literals,
        aliases_in_expression = aliases_in_expression,
        replace_identifiers = replace_identifiers,
        expand_metric = expand_metric,
        apply_metric_filter = apply_metric_filter,
        build_dimension_predicate = build_dimension_predicate,
        build_filters = build_filters,
        plan_joins = plan_joins,
        build_order_by = build_order_by,
        build_sql = build_sql,
        build_materialized_sql = build_materialized_sql,
        sql_tokens = sql_tokens,
        split_top_level = split_top_level,
        unwrap_measure_part = unwrap_measure_part,
        identifier_from_part = identifier_from_part,
        alias_from_select_part = alias_from_select_part,
        literal_from_tokens = literal_from_tokens,
        find_top_level_clauses = find_top_level_clauses,
        render_token_slice = render_token_slice,
        parse_where_filters = parse_where_filters,
        parse_having_filters = parse_having_filters,
        parse_order_by = parse_order_by,
        collision_error = collision_error,
        typed_failure_message = typed_failure_message,
    }
end
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  REQUEST_JSON
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_request_json(REQUEST_JSON)

exit({
    {
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.agent_request_id or null,
    }
}, [[
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

exit({
    {
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        ORIGINAL_SQL or null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.agent_request_id or null,
    }
}, [[
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

exit({
    {
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        ORIGINAL_SQL or null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.query_log_id or null,
    }
}, [[
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

exit(rows or {}, [[
  SUGGESTION_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(512),
  REASON_CODE VARCHAR(128),
  PROPOSED_METADATA_JSON VARCHAR(2000000)
]])
/
-- END GENERATED COMPILER_RUNTIME

-- BEGIN GENERATED SEMANTIC_DEFINITION_RUNTIME
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME AS
local M = {}

local JSON_NULL = {}

local function missing(value)
    return value == nil or value == null or value == JSON_NULL or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function upper(value)
    return string.upper(tostring(value))
end

local function key(value)
    return tostring(value)
end

local function row_value(row, name, position)
    if row == nil then
        return nil
    end
    return row[name] or row[string.lower(name)] or row[position]
end

local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then
        return nil
    end
    return row_value(rows[1], "VALUE", 1) or row_value(rows[1], "COUNT", 1) or row_value(rows[1], "MAX", 1) or rows[1][1]
end

local function sql_string(value)
    if missing(value) then
        return "NULL"
    end
    local text = tostring(value)
    text = string.gsub(text, "'", "''")
    return "'" .. text .. "'"
end

local function sql_boolean(value)
    return value and "TRUE" or "FALSE"
end

local function sql_bool(value)
    if value == true or tostring(value) == "true" or tostring(value) == "TRUE" or tostring(value) == "1" then
        return true
    end
    return false
end

local function null_if_missing(value)
    if missing(value) then
        return null
    end
    return value
end

local function is_array(value)
    if type(value) ~= "table" or value == JSON_NULL then
        return false
    end
    local max_index = 0
    local count = 0
    for k, _ in pairs(value) do
        if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then
            return false
        end
        if k > max_index then
            max_index = k
        end
        count = count + 1
    end
    return max_index == count
end

local function json_escape(value)
    local text = tostring(value)
    text = string.gsub(text, "\\", "\\\\")
    text = string.gsub(text, '"', '\\"')
    text = string.gsub(text, "\n", "\\n")
    text = string.gsub(text, "\r", "\\r")
    text = string.gsub(text, "\t", "\\t")
    return text
end

local function json_encode(value)
    local value_type = type(value)
    if value == nil or value == null or value == JSON_NULL then
        return "null"
    elseif value_type == "string" then
        return '"' .. json_escape(value) .. '"'
    elseif value_type == "number" then
        return tostring(value)
    elseif value_type == "boolean" then
        return value and "true" or "false"
    elseif value_type == "table" then
        local parts = {}
        if is_array(value) then
            for i = 1, #value do
                parts[#parts + 1] = json_encode(value[i])
            end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        local keys = {}
        for k, _ in pairs(value) do
            keys[#keys + 1] = tostring(k)
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            parts[#parts + 1] = json_encode(k) .. ":" .. json_encode(value[k])
        end
        return "{" .. table.concat(parts, ",") .. "}"
    end
    return json_encode(tostring(value))
end

local function json_decode(text)
    if missing(text) then
        error("empty JSON payload")
    end
    text = tostring(text)
    local pos = 1

    local function peek()
        return string.sub(text, pos, pos)
    end

    local function skip_ws()
        while pos <= #text do
            local c = peek()
            if c == " " or c == "\n" or c == "\r" or c == "\t" then
                pos = pos + 1
            else
                return
            end
        end
    end

    local function parse_string()
        if peek() ~= '"' then
            error("expected string at byte " .. tostring(pos))
        end
        pos = pos + 1
        local out = {}
        while pos <= #text do
            local c = peek()
            if c == '"' then
                pos = pos + 1
                return table.concat(out)
            elseif c == "\\" then
                local e = string.sub(text, pos + 1, pos + 1)
                if e == '"' or e == "\\" or e == "/" then
                    out[#out + 1] = e
                    pos = pos + 2
                elseif e == "b" then
                    out[#out + 1] = "\b"
                    pos = pos + 2
                elseif e == "f" then
                    out[#out + 1] = "\f"
                    pos = pos + 2
                elseif e == "n" then
                    out[#out + 1] = "\n"
                    pos = pos + 2
                elseif e == "r" then
                    out[#out + 1] = "\r"
                    pos = pos + 2
                elseif e == "t" then
                    out[#out + 1] = "\t"
                    pos = pos + 2
                elseif e == "u" then
                    out[#out + 1] = "?"
                    pos = pos + 6
                else
                    error("invalid escape at byte " .. tostring(pos))
                end
            else
                out[#out + 1] = c
                pos = pos + 1
            end
        end
        error("unterminated string")
    end

    local parse_value

    local function parse_number()
        local start_pos = pos
        local c = peek()
        if c == "-" then
            pos = pos + 1
        end
        while string.match(peek(), "%d") do
            pos = pos + 1
        end
        if peek() == "." then
            pos = pos + 1
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        c = peek()
        if c == "e" or c == "E" then
            pos = pos + 1
            c = peek()
            if c == "+" or c == "-" then
                pos = pos + 1
            end
            while string.match(peek(), "%d") do
                pos = pos + 1
            end
        end
        local raw = string.sub(text, start_pos, pos - 1)
        local value = tonumber(raw)
        if value == nil then
            error("invalid number at byte " .. tostring(start_pos))
        end
        return value
    end

    local function parse_array()
        pos = pos + 1
        local out = {}
        skip_ws()
        if peek() == "]" then
            pos = pos + 1
            return out
        end
        while true do
            out[#out + 1] = parse_value()
            skip_ws()
            local c = peek()
            if c == "]" then
                pos = pos + 1
                return out
            elseif c == "," then
                pos = pos + 1
            else
                error("expected array comma or close at byte " .. tostring(pos))
            end
        end
    end

    local function parse_object()
        pos = pos + 1
        local out = {}
        skip_ws()
        if peek() == "}" then
            pos = pos + 1
            return out
        end
        while true do
            skip_ws()
            local name = parse_string()
            skip_ws()
            if peek() ~= ":" then
                error("expected object colon at byte " .. tostring(pos))
            end
            pos = pos + 1
            out[name] = parse_value()
            skip_ws()
            local c = peek()
            if c == "}" then
                pos = pos + 1
                return out
            elseif c == "," then
                pos = pos + 1
            else
                error("expected object comma or close at byte " .. tostring(pos))
            end
        end
    end

    function parse_value()
        skip_ws()
        local c = peek()
        if c == '"' then
            return parse_string()
        elseif c == "{" then
            return parse_object()
        elseif c == "[" then
            return parse_array()
        elseif c == "-" or string.match(c, "%d") then
            return parse_number()
        elseif string.sub(text, pos, pos + 3) == "true" then
            pos = pos + 4
            return true
        elseif string.sub(text, pos, pos + 4) == "false" then
            pos = pos + 5
            return false
        elseif string.sub(text, pos, pos + 3) == "null" then
            pos = pos + 4
            return JSON_NULL
        end
        error("unexpected JSON token at byte " .. tostring(pos))
    end

    local value = parse_value()
    skip_ws()
    if pos <= #text then
        error("unexpected trailing JSON at byte " .. tostring(pos))
    end
    return value
end

local function normalize_name(value, label)
    if missing(value) then
        error("SEMANTIC_DDL_001: " .. label .. " is required")
    end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_DDL_002: invalid " .. label .. ": " .. name)
    end
    return name
end

local function decode_quoted_identifier(token_text)
    local raw = string.sub(token_text, 2, -2)
    return string.gsub(raw, '""', '"')
end

local function tokenize(text)
    local tokens = {}
    local i = 1
    local depth = 0
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if string.match(c, "%s") then
            i = i + 1
        elseif c == "-" and n == "-" then
            i = i + 2
            while i <= #text and string.sub(text, i, i) ~= "\n" do
                i = i + 1
            end
        elseif c == "/" and n == "*" then
            i = i + 2
            while i <= #text - 1 and string.sub(text, i, i + 1) ~= "*/" do
                i = i + 1
            end
            i = math.min(i + 2, #text + 1)
        elseif c == "'" then
            local start_pos = i
            i = i + 1
            while i <= #text do
                c = string.sub(text, i, i)
                n = string.sub(text, i + 1, i + 1)
                if c == "'" and n == "'" then
                    i = i + 2
                elseif c == "'" then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1), kind = "literal", start_pos = start_pos, end_pos = i - 1, depth = depth}
        elseif c == '"' then
            local start_pos = i
            i = i + 1
            while i <= #text do
                c = string.sub(text, i, i)
                n = string.sub(text, i + 1, i + 1)
                if c == '"' and n == '"' then
                    i = i + 2
                elseif c == '"' then
                    i = i + 1
                    break
                else
                    i = i + 1
                end
            end
            local token_text = string.sub(text, start_pos, i - 1)
            tokens[#tokens + 1] = {text = token_text, kind = "identifier", value = decode_quoted_identifier(token_text), upper = upper(decode_quoted_identifier(token_text)), start_pos = start_pos, end_pos = i - 1, depth = depth}
        elseif string.match(c, "[A-Za-z_]") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[A-Za-z0-9_]") do
                i = i + 1
            end
            local token_text = string.sub(text, start_pos, i - 1)
            tokens[#tokens + 1] = {text = token_text, kind = "word", value = token_text, upper = upper(token_text), start_pos = start_pos, end_pos = i - 1, depth = depth}
        elseif string.match(c, "%d") then
            local start_pos = i
            i = i + 1
            while i <= #text and string.match(string.sub(text, i, i), "[0-9.]") do
                i = i + 1
            end
            tokens[#tokens + 1] = {text = string.sub(text, start_pos, i - 1), kind = "number", start_pos = start_pos, end_pos = i - 1, depth = depth}
        else
            local token_depth = depth
            if c == ")" then
                depth = math.max(depth - 1, 0)
                token_depth = depth
            end
            tokens[#tokens + 1] = {text = c, kind = "symbol", upper = c, start_pos = i, end_pos = i, depth = token_depth}
            if c == "(" then
                depth = depth + 1
            end
            i = i + 1
        end
    end
    if #tokens > 0 and tokens[#tokens].text == ";" then
        table.remove(tokens, #tokens)
    end
    return tokens
end

local function token_upper(token)
    if token == nil then
        return nil
    end
    return token.upper or upper(token.text)
end

local function token_identifier(token)
    if token == nil then
        return nil
    end
    if token.kind == "word" or token.kind == "identifier" then
        return token.value or token.text
    end
    return nil
end

local function text_from_tokens(source, tokens, first, last)
    if first == nil or last == nil or first > last then
        return nil
    end
    return trim(string.sub(source, tokens[first].start_pos, tokens[last].end_pos))
end

local function find_sequence(tokens, words, start_index, depth)
    start_index = start_index or 1
    for i = start_index, #tokens - #words + 1 do
        local ok = true
        if depth ~= nil and tokens[i].depth ~= depth then
            ok = false
        end
        if ok then
            for j, word in ipairs(words) do
                if token_upper(tokens[i + j - 1]) ~= word then
                    ok = false
                    break
                end
            end
        end
        if ok then
            return i
        end
    end
    return nil
end

local function split_top_level_text(text)
    local parts = {}
    local depth = 0
    local in_quote = false
    local start_pos = 1
    local i = 1
    while i <= #text do
        local c = string.sub(text, i, i)
        local n = string.sub(text, i + 1, i + 1)
        if c == "'" then
            if in_quote and n == "'" then
                i = i + 2
            else
                in_quote = not in_quote
                i = i + 1
            end
        elseif not in_quote then
            if c == "(" then
                depth = depth + 1
            elseif c == ")" then
                depth = depth - 1
            elseif c == "," and depth == 0 then
                parts[#parts + 1] = trim(string.sub(text, start_pos, i - 1))
                start_pos = i + 1
            end
            i = i + 1
        else
            i = i + 1
        end
    end
    local tail = trim(string.sub(text, start_pos))
    if tail ~= "" then
        parts[#parts + 1] = tail
    end
    return parts
end

local CLAUSES = {
    {"ON", "ENTITY"},
    {"AS"},
    {"FILTER"},
    {"RETURNS"},
    {"FORMAT"},
    {"DISPLAY"},
    {"COMMENT"},
    {"SYNONYMS"},
    {"DISTINCT_KEY"},
    {"NON", "ADDITIVE", "BY"},
    {"WINDOW"},
    {"ADDITIVE"},
    {"DERIVED"},
    {"RATIO"},
    {"DISTINCT"},
    {"SEMI_ADDITIVE"},
    {"PUBLIC"},
    {"PRIVATE"},
    {"CERTIFIED"},
}

local function clause_key(words)
    return table.concat(words, "_")
end

local function clause_positions(tokens, start_index)
    local positions = {}
    local ordered = {}
    local occupied_until = start_index - 1
    for i = start_index, #tokens do
        if i > occupied_until and tokens[i].depth == 0 then
            for _, words in ipairs(CLAUSES) do
                local ok = true
                for j, word in ipairs(words) do
                    if token_upper(tokens[i + j - 1]) ~= word then
                        ok = false
                        break
                    end
                end
                if ok then
                    local key_name = clause_key(words)
                    if positions[key_name] == nil then
                        positions[key_name] = {index = i, words = words}
                        ordered[#ordered + 1] = {index = i, words = words, key = key_name}
                    end
                    -- Longer clauses such as NON ADDITIVE BY contain tokens
                    -- that are also valid shorter clauses. Once the longest
                    -- ordered match wins, do not reinterpret its interior.
                    occupied_until = i + #words - 1
                    break
                end
            end
        end
    end
    table.sort(ordered, function(a, b) return a.index < b.index end)
    return positions, ordered
end

local function clause_text(source, tokens, positions, ordered, key_name)
    local entry = positions[key_name]
    if entry == nil then
        return nil
    end
    local value_first = entry.index + #entry.words
    local next_index = #tokens + 1
    for _, candidate in ipairs(ordered) do
        if candidate.index > entry.index and candidate.index < next_index then
            next_index = candidate.index
        end
    end
    return text_from_tokens(source, tokens, value_first, next_index - 1)
end

local function parse_literal_list(text)
    if missing(text) then
        return {}
    end
    local inside = trim(text)
    if string.sub(inside, 1, 1) == "(" and string.sub(inside, -1) == ")" then
        inside = string.sub(inside, 2, -2)
    end
    local values = {}
    for _, part in ipairs(split_top_level_text(inside)) do
        local p = trim(part)
        if string.sub(p, 1, 1) == "'" and string.sub(p, -1) == "'" then
            p = string.sub(p, 2, -2)
            p = string.gsub(p, "''", "'")
        end
        values[#values + 1] = p
    end
    return values
end

local function parse_filter(text)
    if missing(text) then
        return nil
    end
    local value = trim(text)
    if string.sub(value, 1, 1) == "(" and string.sub(value, -1) == ")" then
        value = trim(string.sub(value, 2, -2))
    end
    if string.sub(upper(value), 1, 5) == "WHERE" then
        value = trim(string.sub(value, 6))
    end
    return value
end

local function parse_clause_scalar(text)
    if missing(text) then
        return nil
    end
    local value = trim(text)
    if string.sub(value, 1, 1) == "'" and string.sub(value, -1) == "'" then
        value = string.sub(value, 2, -2)
        value = string.gsub(value, "''", "'")
    end
    return value
end

local function parse_fact(text)
    local tokens = tokenize(text)
    if token_upper(tokens[1]) ~= "FACT" then
        error("SEMANTIC_DDL_020: expected FACT entry")
    end
    local name = normalize_name(token_identifier(tokens[2]), "FACT_NAME")
    local positions, ordered = clause_positions(tokens, 3)
    local entity = normalize_name(clause_text(text, tokens, positions, ordered, "ON_ENTITY"), "ENTITY_NAME")
    local expression = clause_text(text, tokens, positions, ordered, "AS")
    local data_type = clause_text(text, tokens, positions, ordered, "RETURNS")
    if missing(expression) then
        error("SEMANTIC_DDL_021: FACT " .. name .. " requires AS")
    end
    if missing(data_type) then
        error("SEMANTIC_DDL_022: FACT " .. name .. " requires RETURNS")
    end
    local policy = "ADDITIVE"
    if positions.SEMI_ADDITIVE ~= nil then
        policy = "SEMI_ADDITIVE"
    elseif positions.NON_ADDITIVE_BY ~= nil then
        policy = "NON_ADDITIVE"
    end
    return {
        kind = "FACT",
        name = name,
        entity = entity,
        expression = expression,
        data_type = data_type,
        additive_policy = policy,
        display_name = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "DISPLAY")),
        description = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "COMMENT")),
        is_private = positions.PRIVATE ~= nil,
        is_certified = positions.CERTIFIED ~= nil,
    }
end

local function aggregate_parts(expression)
    local text = trim(expression)
    local tokens = tokenize(text)
    if #tokens < 3 or tokens[1].kind ~= "word" or tokens[2].text ~= "(" then
        return nil, nil
    end
    local depth = 0
    for i = 2, #tokens do
        if tokens[i].text == "(" then
            depth = depth + 1
        elseif tokens[i].text == ")" then
            depth = depth - 1
            if depth == 0 then
                local inner = string.sub(text, tokens[2].end_pos + 1, tokens[i].start_pos - 1)
                return upper(tokens[1].text), trim(inner)
            end
        end
    end
    return nil, nil
end

local function parse_metric(text, leading_metric_seen)
    local tokens = tokenize(text)
    local name_index = 2
    if not leading_metric_seen then
        local metric_index = find_sequence(tokens, {"METRIC"}, 1, 0)
        if metric_index == nil then
            error("SEMANTIC_DDL_030: expected METRIC entry")
        end
        name_index = metric_index + 1
    elseif token_upper(tokens[1]) ~= "METRIC" then
        error("SEMANTIC_DDL_030: expected METRIC entry")
    end
    local name = normalize_name(token_identifier(tokens[name_index]), "METRIC_NAME")
    local positions, ordered = clause_positions(tokens, name_index + 1)
    local expression = clause_text(text, tokens, positions, ordered, "AS")
    if missing(expression) then
        error("SEMANTIC_DDL_031: METRIC " .. name .. " requires AS")
    end
    local metric_kind = "SIMPLE"
    local metric_type = "ADDITIVE"
    if positions.RATIO ~= nil then
        metric_kind = "RATIO"
        metric_type = "RATIO"
    elseif positions.DERIVED ~= nil then
        metric_kind = "DERIVED"
        metric_type = "DERIVED"
    elseif positions.DISTINCT ~= nil then
        metric_kind = "DISTINCT"
        metric_type = "DISTINCT"
    elseif positions.SEMI_ADDITIVE ~= nil or positions.NON_ADDITIVE_BY ~= nil then
        metric_kind = "SEMI_ADDITIVE"
        metric_type = "SEMI_ADDITIVE"
    elseif positions.WINDOW ~= nil then
        metric_kind = "WINDOW"
        metric_type = "WINDOW"
    end
    local agg_func, measure_expr = aggregate_parts(expression)
    local semantic_filter = parse_filter(clause_text(text, tokens, positions, ordered, "FILTER"))
    if metric_kind == "SIMPLE" and not missing(semantic_filter) then
        metric_kind = "FILTERED"
    end
    local data_type = clause_text(text, tokens, positions, ordered, "RETURNS")
    if missing(data_type) then
        error("SEMANTIC_DDL_032: METRIC " .. name .. " requires RETURNS")
    end
    return {
        kind = "METRIC",
        name = name,
        expression = expression,
        semantic_filter_expr = semantic_filter,
        metric_type = metric_type,
        metric_kind = metric_kind,
        aggregation_function = agg_func,
        measure_expr = measure_expr,
        base_entity = normalize_name(clause_text(text, tokens, positions, ordered, "ON_ENTITY"), "BASE_ENTITY_NAME"),
        data_type = data_type,
        display_name = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "DISPLAY")),
        description = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "COMMENT")),
        format_hint = parse_clause_scalar(clause_text(text, tokens, positions, ordered, "FORMAT")),
        synonyms = parse_literal_list(clause_text(text, tokens, positions, ordered, "SYNONYMS")),
        is_private = positions.PRIVATE ~= nil,
        is_certified = positions.CERTIFIED ~= nil,
        distinct_key_expr = clause_text(text, tokens, positions, ordered, "DISTINCT_KEY"),
        non_additive_dimension = clause_text(text, tokens, positions, ordered, "NON_ADDITIVE_BY"),
        window_spec_json = clause_text(text, tokens, positions, ordered, "WINDOW"),
    }
end

local function matching_close(tokens, open_index)
    local depth = 0
    for i = open_index, #tokens do
        if tokens[i].text == "(" then
            depth = depth + 1
        elseif tokens[i].text == ")" then
            depth = depth - 1
            if depth == 0 then
                return i
            end
        end
    end
    return nil
end

local function parse_qualified(tokens, start_index)
    local model_name = token_identifier(tokens[start_index])
    local object_name = nil
    local metric_name = nil
    local index = start_index + 1
    if tokens[index] ~= nil and tokens[index].text == "." then
        object_name = token_identifier(tokens[index + 1])
        index = index + 2
    end
    if tokens[index] ~= nil and tokens[index].text == "." then
        metric_name = token_identifier(tokens[index + 1])
        index = index + 2
    end
    return normalize_name(model_name, "MODEL_NAME"), object_name and normalize_name(object_name, "OBJECT_NAME") or nil, metric_name and normalize_name(metric_name, "METRIC_NAME") or nil, index
end

local function parse_definition(definition_sql)
    local source = tostring(definition_sql or "")
    local tokens = tokenize(source)
    if #tokens == 0 then
        error("SEMANTIC_DDL_001: definition SQL is required")
    end
    if token_upper(tokens[1]) ~= "ALTER" or token_upper(tokens[2]) ~= "SEMANTIC" or token_upper(tokens[3]) ~= "VIEW" then
        error("SEMANTIC_DDL_010: expected ALTER SEMANTIC VIEW")
    end
    local model_name, object_name, _, next_index = parse_qualified(tokens, 4)
    if object_name == nil then
        error("SEMANTIC_DDL_011: semantic view name must be model.object")
    end
    local definition = {
        statement_kind = "ALTER_SEMANTIC_VIEW",
        operation = "UPSERT",
        model_name = model_name,
        object_name = object_name,
        facts = {},
        metrics = {},
        replace_facts = false,
        replace_metrics = false,
    }

    local replace_facts = find_sequence(tokens, {"REPLACE", "FACTS"}, next_index, 0)
    local replace_metrics = find_sequence(tokens, {"REPLACE", "METRICS"}, next_index, 0)
    local add_metric = find_sequence(tokens, {"ADD", "OR", "REPLACE", "METRIC"}, next_index, 0)
    local drop_metric = find_sequence(tokens, {"DROP", "METRIC"}, next_index, 0)
    local rename_metric = find_sequence(tokens, {"RENAME", "METRIC"}, next_index, 0)

    if drop_metric ~= nil then
        local metric_name = token_identifier(tokens[drop_metric + 2])
        if metric_name == nil or tokens[drop_metric + 3] ~= nil then
            error("SEMANTIC_DDL_035: DROP METRIC requires exactly one metric name")
        end
        definition.operation = "DROP_METRIC"
        definition.metric_name = normalize_name(metric_name, "METRIC_NAME")
        return definition
    end

    if rename_metric ~= nil then
        local old_name = token_identifier(tokens[rename_metric + 2])
        local to_keyword = token_upper(tokens[rename_metric + 3])
        local new_name = token_identifier(tokens[rename_metric + 4])
        if old_name == nil or to_keyword ~= "TO" or new_name == nil or tokens[rename_metric + 5] ~= nil then
            error("SEMANTIC_DDL_036: RENAME METRIC requires <old_name> TO <new_name>")
        end
        definition.operation = "RENAME_METRIC"
        definition.metric_name = normalize_name(old_name, "METRIC_NAME")
        definition.new_metric_name = normalize_name(new_name, "NEW_METRIC_NAME")
        if upper(definition.metric_name) == upper(definition.new_metric_name) then
            error("SEMANTIC_DDL_083: old and new metric names must differ")
        end
        return definition
    end

    if replace_facts ~= nil then
        definition.replace_facts = true
        local open = replace_facts + 2
        if tokens[open] == nil or tokens[open].text ~= "(" then
            error("SEMANTIC_DDL_023: REPLACE FACTS requires a parenthesized block")
        end
        local close = matching_close(tokens, open)
        if close == nil then
            error("SEMANTIC_DDL_024: unterminated FACTS block")
        end
        local block = string.sub(source, tokens[open].end_pos + 1, tokens[close].start_pos - 1)
        for _, part in ipairs(split_top_level_text(block)) do
            definition.facts[#definition.facts + 1] = parse_fact(part)
        end
    end

    if replace_metrics ~= nil then
        definition.replace_metrics = true
        local open = replace_metrics + 2
        if tokens[open] == nil or tokens[open].text ~= "(" then
            error("SEMANTIC_DDL_033: REPLACE METRICS requires a parenthesized block")
        end
        local close = matching_close(tokens, open)
        if close == nil then
            error("SEMANTIC_DDL_034: unterminated METRICS block")
        end
        local block = string.sub(source, tokens[open].end_pos + 1, tokens[close].start_pos - 1)
        for _, part in ipairs(split_top_level_text(block)) do
            definition.metrics[#definition.metrics + 1] = parse_metric(part, true)
        end
    elseif add_metric ~= nil then
        local metric_text = string.sub(source, tokens[add_metric + 3].start_pos)
        definition.metrics[#definition.metrics + 1] = parse_metric(metric_text, false)
    else
        error("SEMANTIC_DDL_012: expected REPLACE FACTS, REPLACE METRICS, ADD OR REPLACE METRIC, DROP METRIC, or RENAME METRIC")
    end

    return definition
end

local function load_model(model_name)
    local rows = query([[
        SELECT MODEL_ID, ACTIVE_VERSION_ID
        FROM SYS_SEMANTIC.MODELS
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_DDL_040: model not found: " .. tostring(model_name))
    end
    return {model_id = row_value(rows[1], "MODEL_ID", 1), version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2), model_name = model_name}
end

local function object_id(model, object_name)
    local id = scalar([[
        SELECT OBJECT_ID
        FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
    ]], {model_id = model.model_id, version_id = model.version_id, object_name = object_name})
    if id == nil then
        error("SEMANTIC_DDL_041: semantic view not found: " .. tostring(object_name))
    end
    return id
end

local function entity_id(model, entity_name)
    local id = scalar([[
        SELECT ENTITY_ID
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(ENTITY_NAME) = UPPER(:entity_name)
    ]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name})
    if id == nil then
        error("SEMANTIC_DDL_042: entity not found: " .. tostring(entity_name))
    end
    return id
end

local function dimension_by_name(model, name)
    if missing(name) then
        return nil
    end
    local rows = query([[
        SELECT DIMENSION_ID, ENTITY_ID, EXPRESSION
        FROM SYS_SEMANTIC.DIMENSIONS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(DIMENSION_NAME) = UPPER(:name)
    ]], {model_id = model.model_id, version_id = model.version_id, name = name})
    if rows == nil or #rows == 0 then
        return nil
    end
    return {id = row_value(rows[1], "DIMENSION_ID", 1), entity_id = row_value(rows[1], "ENTITY_ID", 2), expression = row_value(rows[1], "EXPRESSION", 3)}
end

local function replace_semantic_identifiers(model, expression)
    if missing(expression) then
        return nil
    end
    local tokens = tokenize(expression)
    local out = {}
    local last = 1
    for _, token in ipairs(tokens) do
        if token.kind == "word" or token.kind == "identifier" then
            local dim = dimension_by_name(model, token.value or token.text)
            if dim ~= nil then
                out[#out + 1] = string.sub(expression, last, token.start_pos - 1)
                out[#out + 1] = tostring(dim.expression)
                last = token.end_pos + 1
            end
        end
    end
    out[#out + 1] = string.sub(expression, last)
    return trim(table.concat(out))
end

local function source_hash(text)
    local hash = 5381
    for i = 1, #text do
        hash = (hash * 33 + string.byte(text, i)) % 4294967296
    end
    return tostring(hash)
end

local function insert_source(model, definition, definition_sql, normalized_json, status)
    query([[
        INSERT INTO SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES (
          MODEL_ID, VERSION_ID, SOURCE_KIND, SOURCE_NAME, DEFINITION_SQL,
          NORMALIZED_JSON, DEFINITION_HASH, APPLY_STATUS
        ) VALUES (
          :model_id, :version_id, :source_kind, :source_name, :definition_sql,
          :normalized_json, :definition_hash, :apply_status
        )
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        source_kind = definition.statement_kind,
        source_name = definition.model_name .. "." .. definition.object_name,
        definition_sql = definition_sql,
        normalized_json = normalized_json,
        definition_hash = source_hash(definition_sql),
        apply_status = status,
    })
    return scalar([[
        SELECT MAX(DEFINITION_SOURCE_ID)
        FROM SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND DEFINITION_HASH = :definition_hash
    ]], {model_id = model.model_id, version_id = model.version_id, definition_hash = source_hash(definition_sql)})
end

local function add_object_column(object_id_value, kind, ref_id, column_name, is_visible)
    local visible = true
    if is_visible == false then
        visible = false
    end
    local existing = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND COLUMN_KIND = :kind
          AND OBJECT_REF_ID = :ref_id
    ]], {object_id = object_id_value, kind = kind, ref_id = ref_id})
    if tonumber(existing or 0) > 0 then
        return
    end
    local ordinal = scalar([[
        SELECT COALESCE(MAX(ORDINAL_POSITION), 0) + 1
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
    ]], {object_id = object_id_value})
    query([[
        INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
          OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
        ) VALUES (
          :object_id, :kind, :ref_id, :column_name, :ordinal, :is_visible
        )
    ]], {object_id = object_id_value, kind = kind, ref_id = ref_id, column_name = column_name, ordinal = ordinal, is_visible = visible})
end

local function upsert_fact(model, object_id_value, fact)
    local entity = entity_id(model, fact.entity)
    local existing_id = scalar([[
        SELECT FACT_ID
        FROM SYS_SEMANTIC.FACTS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(FACT_NAME) = UPPER(:fact_name)
    ]], {model_id = model.model_id, version_id = model.version_id, fact_name = fact.name})
    if existing_id ~= nil then
        query([[
            UPDATE SYS_SEMANTIC.FACTS
            SET ENTITY_ID = :entity_id,
                EXPRESSION = :expression,
                DATA_TYPE = :data_type,
                ADDITIVE_POLICY = :additive_policy,
                DISPLAY_NAME = :display_name,
                DESCRIPTION = :description,
                IS_PRIVATE = :is_private,
                IS_CERTIFIED = :is_certified,
                STATUS = 'ACTIVE'
            WHERE FACT_ID = :fact_id
        ]], {
            fact_id = existing_id,
            entity_id = entity,
            expression = fact.expression,
            data_type = fact.data_type,
            additive_policy = fact.additive_policy,
            display_name = null_if_missing(fact.display_name),
            description = null_if_missing(fact.description),
            is_private = fact.is_private,
            is_certified = fact.is_certified,
        })
    else
        query([[
            INSERT INTO SYS_SEMANTIC.FACTS (
              MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
              ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, IS_PRIVATE, IS_CERTIFIED, STATUS
            ) VALUES (
              :model_id, :version_id, :entity_id, :fact_name, :expression, :data_type,
              :additive_policy, :display_name, :description, :is_private, :is_certified, 'ACTIVE'
            )
        ]], {
            model_id = model.model_id,
            version_id = model.version_id,
            entity_id = entity,
            fact_name = fact.name,
            expression = fact.expression,
            data_type = fact.data_type,
            additive_policy = fact.additive_policy,
            display_name = null_if_missing(fact.display_name),
            description = null_if_missing(fact.description),
            is_private = fact.is_private,
            is_certified = fact.is_certified,
        })
        existing_id = scalar([[
            SELECT FACT_ID FROM SYS_SEMANTIC.FACTS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(FACT_NAME) = UPPER(:fact_name)
        ]], {model_id = model.model_id, version_id = model.version_id, fact_name = fact.name})
    end
    local primary_representation_id = scalar([[
        SELECT REPRESENTATION_ID
        FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        WHERE ENTITY_ID = :entity_id
          AND REPRESENTATION_ROLE = 'PRIMARY'
          AND STATUS = 'ACTIVE'
    ]], {entity_id = entity})
    local default_binding_id = scalar([[
        SELECT ATTRIBUTE_BINDING_ID
        FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE ATTRIBUTE_TYPE = 'FACT'
          AND ATTRIBUTE_ID = :fact_id
          AND IS_DEFAULT = TRUE
          AND STATUS = 'ACTIVE'
    ]], {fact_id = existing_id})
    if default_binding_id == nil then
        query([[
            INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
              MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
              REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
              BINDING_PRIORITY, IS_DEFAULT, STATUS
            ) VALUES (
              :model_id, :version_id, :entity_id, 'FACT', :fact_id,
              :representation_id, :expression, 'PREFER', 1, TRUE, 'ACTIVE'
            )
        ]], {model_id = model.model_id, version_id = model.version_id,
            entity_id = entity, fact_id = existing_id,
            representation_id = primary_representation_id, expression = fact.expression})
    else
        query([[
            UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
            SET ENTITY_ID = :entity_id, REPRESENTATION_ID = :representation_id,
                SOURCE_EXPRESSION = :expression,
                UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
            WHERE ATTRIBUTE_BINDING_ID = :binding_id
        ]], {entity_id = entity, representation_id = primary_representation_id,
            expression = fact.expression, binding_id = default_binding_id})
    end
    add_object_column(object_id_value, "FACT", existing_id, fact.name, false)
    return existing_id
end

local function object_id_by_name(model, object_type, name)
    if object_type == "FACT" then
        return scalar("SELECT FACT_ID FROM SYS_SEMANTIC.FACTS WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(FACT_NAME) = UPPER(:name)",
            {model_id = model.model_id, version_id = model.version_id, name = name})
    elseif object_type == "METRIC" then
        return scalar("SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(METRIC_NAME) = UPPER(:name)",
            {model_id = model.model_id, version_id = model.version_id, name = name})
    elseif object_type == "DIMENSION" then
        return scalar("SELECT DIMENSION_ID FROM SYS_SEMANTIC.DIMENSIONS WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(DIMENSION_NAME) = UPPER(:name)",
            {model_id = model.model_id, version_id = model.version_id, name = name})
    end
    return nil
end

local SQL_WORDS = {
    SUM = true, COUNT = true, AVG = true, MIN = true, MAX = true, NULLIF = true,
    CASE = true, WHEN = true, THEN = true, ELSE = true, END = true, DISTINCT = true,
    DATE = true, TIMESTAMP = true, TRUE = true, FALSE = true, NULL = true,
}

local function identifiers_in_expression(expression)
    local identifiers = {}
    local seen = {}
    for _, token in ipairs(tokenize(expression or "")) do
        if token.kind == "word" or token.kind == "identifier" then
            local name = token.value or token.text
            local normalized = upper(name)
            if not SQL_WORDS[normalized] and not seen[normalized] then
                identifiers[#identifiers + 1] = name
                seen[normalized] = true
            end
        end
    end
    return identifiers
end

local AGGREGATE_FUNCTIONS = {
    SUM = true, COUNT = true, AVG = true, MIN = true, MAX = true,
}

local function contains_aggregate_call(expression)
    local tokens = tokenize(expression or "")
    for index, token in ipairs(tokens) do
        if token.kind == "word"
                and AGGREGATE_FUNCTIONS[upper(token.text)]
                and tokens[index + 1] ~= nil
                and tokens[index + 1].text == "(" then
            return true
        end
    end
    return false
end

local function inline_ratio_parts(expression)
    local text = tostring(expression or "")
    local tokens = tokenize(text)
    local depth = 0
    local division = nil
    local division_depth = nil
    for _, token in ipairs(tokens) do
        if token.text == "(" then
            depth = depth + 1
        elseif token.text == ")" then
            depth = depth - 1
        elseif token.text == "/" and (division_depth == nil or depth < division_depth) then
            division = token
            division_depth = depth
        end
    end
    if division == nil then
        return nil, nil
    end
    local numerator = trim(string.sub(text, 1, division.start_pos - 1))
    local denominator = trim(string.sub(text, division.end_pos + 1))
    if not contains_aggregate_call(numerator) or not contains_aggregate_call(denominator) then
        return nil, nil
    end
    return numerator, denominator
end

local function validate_metric_shape(model, metric)
    if metric.metric_type == "RATIO" then
        local metric_input_count = 0
        for _, identifier in ipairs(identifiers_in_expression(metric.expression)) do
            if object_id_by_name(model, "METRIC", identifier) ~= nil then
                metric_input_count = metric_input_count + 1
            end
        end
        local numerator, denominator = inline_ratio_parts(metric.expression)
        if metric_input_count < 2 and (numerator == nil or denominator == nil) then
            error("SEMANTIC_DDL_070: RATIO metric " .. metric.name .. " must reference at least two aggregate metrics or divide two aggregate expressions")
        end
    elseif metric.metric_kind == "DISTINCT" then
        if missing(metric.distinct_key_expr) then
            error("SEMANTIC_DDL_071: DISTINCT metric " .. metric.name .. " requires DISTINCT KEY")
        end
    elseif metric.metric_type == "SEMI_ADDITIVE" then
        if missing(metric.non_additive_dimension) then
            error("SEMANTIC_DDL_072: SEMI ADDITIVE metric " .. metric.name .. " requires NON ADDITIVE BY")
        end
        local dim_name = tostring(metric.non_additive_dimension):match("^%s*([A-Za-z_][A-Za-z0-9_]*)")
        if dimension_by_name(model, dim_name) == nil then
            error("SEMANTIC_DDL_073: SEMI ADDITIVE metric " .. metric.name .. " references unknown non-additive dimension")
        end
    elseif metric.metric_kind == "WINDOW" then
        if missing(metric.window_spec_json) then
            error("SEMANTIC_DDL_074: WINDOW metric " .. metric.name .. " requires WINDOW metadata")
        end
    end
end

local function refresh_metric_inputs(model, metric_id, metric)
    query("DELETE FROM SYS_SEMANTIC.METRIC_INPUTS WHERE METRIC_ID = :metric_id", {metric_id = metric_id})
    query("DELETE FROM SYS_SEMANTIC.METRIC_FILTERS WHERE METRIC_ID = :metric_id", {metric_id = metric_id})
    local ordinal = 1
    local ratio_numerator, ratio_denominator = inline_ratio_parts(metric.expression)
    local numerator_identifiers = {}
    local denominator_identifiers = {}
    for _, identifier in ipairs(identifiers_in_expression(ratio_numerator)) do
        numerator_identifiers[upper(identifier)] = true
    end
    for _, identifier in ipairs(identifiers_in_expression(ratio_denominator)) do
        denominator_identifiers[upper(identifier)] = true
    end
    for _, identifier in ipairs(identifiers_in_expression(metric.expression)) do
        local object_type = nil
        local object_id_value = object_id_by_name(model, "FACT", identifier)
        local input_role = "MEASURE"
        if object_id_value ~= nil then
            object_type = "FACT"
            if metric.metric_type == "RATIO" then
                if numerator_identifiers[upper(identifier)] then
                    input_role = "NUMERATOR"
                elseif denominator_identifiers[upper(identifier)] then
                    input_role = "DENOMINATOR"
                end
            end
        else
            object_id_value = object_id_by_name(model, "METRIC", identifier)
            if object_id_value ~= nil then
                object_type = "METRIC"
                input_role = metric.metric_type == "RATIO" and (ordinal == 1 and "NUMERATOR" or "DENOMINATOR") or "INPUT_METRIC"
            end
        end
        if object_type ~= nil then
            query([[
                INSERT INTO SYS_SEMANTIC.METRIC_INPUTS (
                  METRIC_ID, INPUT_ROLE, INPUT_OBJECT_TYPE, INPUT_OBJECT_ID,
                  EXPRESSION_ALIAS, ORDINAL_POSITION
                ) VALUES (
                  :metric_id, :input_role, :object_type, :object_id, :alias, :ordinal
                )
            ]], {metric_id = metric_id, input_role = input_role, object_type = object_type, object_id = object_id_value, alias = identifier, ordinal = ordinal})
            ordinal = ordinal + 1
        end
    end
    if not missing(metric.semantic_filter_expr) then
        local resolved = replace_semantic_identifiers(model, metric.semantic_filter_expr)
        local required_dimension_id = nil
        local required_entity_id = nil
        for _, identifier in ipairs(identifiers_in_expression(metric.semantic_filter_expr)) do
            local dim = dimension_by_name(model, identifier)
            if dim ~= nil then
                required_dimension_id = dim.id
                required_entity_id = dim.entity_id
                break
            end
        end
        query([[
            INSERT INTO SYS_SEMANTIC.METRIC_FILTERS (
              METRIC_ID, FILTER_KIND, FILTER_EXPR, RESOLVED_SQL_EXPR,
              REQUIRED_DIMENSION_ID, REQUIRED_ENTITY_ID, ORDINAL_POSITION
            ) VALUES (
              :metric_id, 'SEMANTIC_SQL', :filter_expr, :resolved_sql,
              :required_dimension_id, :required_entity_id, 1
            )
        ]], {
            metric_id = metric_id,
            filter_expr = metric.semantic_filter_expr,
            resolved_sql = resolved,
            required_dimension_id = null_if_missing(required_dimension_id),
            required_entity_id = null_if_missing(required_entity_id),
        })
        metric.sql_filter_expr = resolved
    end
end

local function upsert_synonyms(model, metric_id, synonyms)
    query([[
        DELETE FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE = 'METRIC'
          AND OBJECT_ID = :metric_id
    ]], {model_id = model.model_id, version_id = model.version_id, metric_id = metric_id})
    for _, synonym in ipairs(synonyms or {}) do
        if not missing(synonym) then
            query([[
                INSERT INTO SYS_SEMANTIC.SYNONYMS (
                  MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE
                ) VALUES (
                  :model_id, :version_id, 'METRIC', :metric_id, :synonym, 'SEMANTIC_SQL'
                )
            ]], {model_id = model.model_id, version_id = model.version_id, metric_id = metric_id, synonym = synonym})
        end
    end
end

local function prepare_replacement_synonyms(model, metrics)
    local requested = {}
    for _, metric in ipairs(metrics or {}) do
        for _, synonym in ipairs(metric.synonyms or {}) do
            local normalized = upper(trim(synonym))
            if normalized ~= "" and not requested[normalized] then
                requested[normalized] = true
                query([[
                    DELETE FROM SYS_SEMANTIC.SYNONYMS
                    WHERE MODEL_ID = :model_id
                      AND VERSION_ID = :version_id
                      AND OBJECT_TYPE = 'METRIC'
                      AND UPPER(SYNONYM) = :synonym
                ]], {
                    model_id = model.model_id,
                    version_id = model.version_id,
                    synonym = normalized,
                })
            end
        end
    end
end

local function upsert_metric(model, object_id_value, metric, definition_source_id)
    local base_entity = entity_id(model, metric.base_entity)
    validate_metric_shape(model, metric)
    local existing_id = scalar([[
        SELECT METRIC_ID
        FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(METRIC_NAME) = UPPER(:metric_name)
    ]], {model_id = model.model_id, version_id = model.version_id, metric_name = metric.name})
    local filter_expr = metric.sql_filter_expr or (not missing(metric.semantic_filter_expr) and replace_semantic_identifiers(model, metric.semantic_filter_expr) or nil)
    local non_additive_dimension_id = nil
    if not missing(metric.non_additive_dimension) then
        local dim_name = tostring(metric.non_additive_dimension):match("^%s*([A-Za-z_][A-Za-z0-9_]*)")
        local dim = dimension_by_name(model, dim_name)
        if dim ~= nil then
            non_additive_dimension_id = dim.id
        end
    end
    if existing_id ~= nil then
        query([[
            UPDATE SYS_SEMANTIC.METRICS
            SET EXPRESSION = :expression,
                FILTER_EXPR = :filter_expr,
                METRIC_TYPE = :metric_type,
                BASE_ENTITY_ID = :base_entity_id,
                DATA_TYPE = :data_type,
                DISPLAY_NAME = :display_name,
                DESCRIPTION = :description,
                FORMAT_HINT = :format_hint,
                IS_PRIVATE = :is_private,
                IS_CERTIFIED = :is_certified,
                METRIC_KIND = :metric_kind,
                AGGREGATION_FUNCTION = :aggregation_function,
                MEASURE_EXPR = :measure_expr,
                SEMANTIC_FILTER_EXPR = :semantic_filter_expr,
                SQL_FILTER_EXPR = :sql_filter_expr,
                DISTINCT_KEY_EXPR = :distinct_key_expr,
                NON_ADDITIVE_DIMENSION_ID = :non_additive_dimension_id,
                WINDOW_SPEC_JSON = :window_spec_json,
                TYPE_PARAMS_JSON = :type_params_json,
                DEFINITION_SOURCE_ID = :definition_source_id,
                STATUS = 'ACTIVE'
            WHERE METRIC_ID = :metric_id
        ]], {
            metric_id = existing_id,
            expression = metric.expression,
            filter_expr = null_if_missing(filter_expr),
            metric_type = metric.metric_type,
            base_entity_id = base_entity,
            data_type = metric.data_type,
            display_name = null_if_missing(metric.display_name),
            description = null_if_missing(metric.description),
            format_hint = null_if_missing(metric.format_hint),
            is_private = metric.is_private,
            is_certified = metric.is_certified,
            metric_kind = metric.metric_kind,
            aggregation_function = null_if_missing(metric.aggregation_function),
            measure_expr = null_if_missing(metric.measure_expr),
            semantic_filter_expr = null_if_missing(metric.semantic_filter_expr),
            sql_filter_expr = null_if_missing(filter_expr),
            distinct_key_expr = null_if_missing(metric.distinct_key_expr),
            non_additive_dimension_id = null_if_missing(non_additive_dimension_id),
            window_spec_json = null_if_missing(metric.window_spec_json),
            type_params_json = json_encode({metric_type = metric.metric_type}),
            definition_source_id = null_if_missing(definition_source_id),
        })
    else
        query([[
            INSERT INTO SYS_SEMANTIC.METRICS (
              MODEL_ID, VERSION_ID, METRIC_NAME, EXPRESSION, FILTER_EXPR,
              METRIC_TYPE, BASE_ENTITY_ID, DATA_TYPE, DISPLAY_NAME, DESCRIPTION,
              FORMAT_HINT, IS_PRIVATE, IS_CERTIFIED, METRIC_KIND,
              AGGREGATION_FUNCTION, MEASURE_EXPR, SEMANTIC_FILTER_EXPR,
              SQL_FILTER_EXPR, DISTINCT_KEY_EXPR, NON_ADDITIVE_DIMENSION_ID,
              WINDOW_SPEC_JSON, TYPE_PARAMS_JSON, DEFINITION_SOURCE_ID, STATUS
            ) VALUES (
              :model_id, :version_id, :metric_name, :expression, :filter_expr,
              :metric_type, :base_entity_id, :data_type, :display_name, :description,
              :format_hint, :is_private, :is_certified, :metric_kind,
              :aggregation_function, :measure_expr, :semantic_filter_expr,
              :sql_filter_expr, :distinct_key_expr, :non_additive_dimension_id,
              :window_spec_json, :type_params_json, :definition_source_id, 'ACTIVE'
            )
        ]], {
            model_id = model.model_id,
            version_id = model.version_id,
            metric_name = metric.name,
            expression = metric.expression,
            filter_expr = null_if_missing(filter_expr),
            metric_type = metric.metric_type,
            base_entity_id = base_entity,
            data_type = metric.data_type,
            display_name = null_if_missing(metric.display_name),
            description = null_if_missing(metric.description),
            format_hint = null_if_missing(metric.format_hint),
            is_private = metric.is_private,
            is_certified = metric.is_certified,
            metric_kind = metric.metric_kind,
            aggregation_function = null_if_missing(metric.aggregation_function),
            measure_expr = null_if_missing(metric.measure_expr),
            semantic_filter_expr = null_if_missing(metric.semantic_filter_expr),
            sql_filter_expr = null_if_missing(filter_expr),
            distinct_key_expr = null_if_missing(metric.distinct_key_expr),
            non_additive_dimension_id = null_if_missing(non_additive_dimension_id),
            window_spec_json = null_if_missing(metric.window_spec_json),
            type_params_json = json_encode({metric_type = metric.metric_type}),
            definition_source_id = null_if_missing(definition_source_id),
        })
        existing_id = scalar([[
            SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(METRIC_NAME) = UPPER(:metric_name)
        ]], {model_id = model.model_id, version_id = model.version_id, metric_name = metric.name})
    end
    add_object_column(object_id_value, "METRIC", existing_id, metric.name,
        not metric.is_private)
    refresh_metric_inputs(model, existing_id, metric)
    upsert_synonyms(model, existing_id, metric.synonyms)
    return existing_id
end

local function replace_object_columns(object_id_value, column_kind)
    query([[
        DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND COLUMN_KIND = :column_kind
    ]], {object_id = object_id_value, column_kind = column_kind})
end

local function rewrite_identifier(expression, old_name, new_name)
    if missing(expression) then
        return expression
    end
    local source = tostring(expression)
    local replacements = {}
    for _, token in ipairs(tokenize(source)) do
        if (token.kind == "word" or token.kind == "identifier")
                and upper(token.value or token.text) == upper(old_name) then
            local replacement = new_name
            if token.kind == "identifier" then
                replacement = '"' .. string.gsub(new_name, '"', '""') .. '"'
            end
            replacements[#replacements + 1] = {
                start_pos = token.start_pos,
                end_pos = token.end_pos,
                text = replacement,
            }
        end
    end
    for index = #replacements, 1, -1 do
        local replacement = replacements[index]
        source = string.sub(source, 1, replacement.start_pos - 1)
            .. replacement.text
            .. string.sub(source, replacement.end_pos + 1)
    end
    return source
end

local function metric_id_for_object(model, object_id_value, metric_name)
    local metric_id = scalar([[
        SELECT mt.METRIC_ID
        FROM SYS_SEMANTIC.METRICS mt
        JOIN SYS_SEMANTIC.OBJECT_COLUMNS oc
          ON oc.OBJECT_REF_ID = mt.METRIC_ID
         AND oc.COLUMN_KIND = 'METRIC'
        WHERE mt.MODEL_ID = :model_id
          AND mt.VERSION_ID = :version_id
          AND mt.STATUS = 'ACTIVE'
          AND oc.OBJECT_ID = :object_id
          AND UPPER(mt.METRIC_NAME) = UPPER(:metric_name)
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        object_id = object_id_value,
        metric_name = metric_name,
    })
    if metric_id == nil then
        error("SEMANTIC_DDL_080: metric not found in semantic view: " .. metric_name)
    end
    return metric_id
end

local function drop_metric(model, object_id_value, metric_name)
    local metric_id = metric_id_for_object(model, object_id_value, metric_name)
    query([[
        DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id
          AND COLUMN_KIND = 'METRIC'
          AND OBJECT_REF_ID = :metric_id
    ]], {object_id = object_id_value, metric_id = metric_id})
    local remaining_memberships = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE COLUMN_KIND = 'METRIC'
          AND OBJECT_REF_ID = :metric_id
    ]], {metric_id = metric_id})
    if tonumber(remaining_memberships or 0) == 0 then
        query("UPDATE SYS_SEMANTIC.METRICS SET STATUS = 'INACTIVE' WHERE METRIC_ID = :metric_id",
            {metric_id = metric_id})
    end
end

local function rename_metric(model, object_id_value, old_name, new_name)
    local metric_id = metric_id_for_object(model, object_id_value, old_name)
    local duplicate = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(METRIC_NAME) = UPPER(:new_name)
          AND METRIC_ID <> :metric_id
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        new_name = new_name,
        metric_id = metric_id,
    })
    if tonumber(duplicate or 0) > 0 then
        error("SEMANTIC_DDL_081: metric already exists: " .. new_name)
    end
    local column_collision = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.OBJECT_COLUMNS candidate
        WHERE UPPER(candidate.COLUMN_NAME) = UPPER(:new_name)
          AND candidate.OBJECT_REF_ID <> :metric_id
          AND candidate.OBJECT_ID IN (
            SELECT OBJECT_ID
            FROM SYS_SEMANTIC.OBJECT_COLUMNS
            WHERE COLUMN_KIND = 'METRIC'
              AND OBJECT_REF_ID = :metric_id
          )
    ]], {new_name = new_name, metric_id = metric_id})
    if tonumber(column_collision or 0) > 0 then
        error("SEMANTIC_DDL_082: semantic object column already exists: " .. new_name)
    end

    local dependent_rows = query([[
        SELECT METRIC_ID, EXPRESSION, MEASURE_EXPR
        FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
    ]], {model_id = model.model_id, version_id = model.version_id}) or {}
    for _, row in ipairs(dependent_rows) do
        local dependent_id = row_value(row, "METRIC_ID", 1)
        local expression = row_value(row, "EXPRESSION", 2)
        local measure_expr = row_value(row, "MEASURE_EXPR", 3)
        local rewritten_expression = rewrite_identifier(expression, old_name, new_name)
        local rewritten_measure = rewrite_identifier(measure_expr, old_name, new_name)
        if rewritten_expression ~= expression or rewritten_measure ~= measure_expr then
            query([[
                UPDATE SYS_SEMANTIC.METRICS
                SET EXPRESSION = :expression,
                    MEASURE_EXPR = :measure_expr
                WHERE METRIC_ID = :metric_id
            ]], {
                metric_id = dependent_id,
                expression = rewritten_expression,
                measure_expr = null_if_missing(rewritten_measure),
            })
        end
    end

    query("UPDATE SYS_SEMANTIC.METRICS SET METRIC_NAME = :new_name WHERE METRIC_ID = :metric_id",
        {new_name = new_name, metric_id = metric_id})
    query([[
        UPDATE SYS_SEMANTIC.OBJECT_COLUMNS
        SET COLUMN_NAME = :new_name
        WHERE COLUMN_KIND = 'METRIC'
          AND OBJECT_REF_ID = :metric_id
    ]], {new_name = new_name, metric_id = metric_id})
    query([[
        UPDATE SYS_SEMANTIC.METRIC_INPUTS
        SET EXPRESSION_ALIAS = :new_name
        WHERE INPUT_OBJECT_TYPE = 'METRIC'
          AND INPUT_OBJECT_ID = :metric_id
          AND UPPER(EXPRESSION_ALIAS) = UPPER(:old_name)
    ]], {new_name = new_name, old_name = old_name, metric_id = metric_id})
    query([[
        DELETE FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE = 'METRIC'
          AND OBJECT_ID = :metric_id
          AND UPPER(SYNONYM) = UPPER(:new_name)
    ]], {model_id = model.model_id, version_id = model.version_id, metric_id = metric_id, new_name = new_name})
    local old_synonym = scalar([[
        SELECT COUNT(*)
        FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND OBJECT_TYPE = 'METRIC'
          AND OBJECT_ID = :metric_id
          AND UPPER(SYNONYM) = UPPER(:old_name)
    ]], {model_id = model.model_id, version_id = model.version_id, metric_id = metric_id, old_name = old_name})
    if tonumber(old_synonym or 0) == 0 then
        query([[
            INSERT INTO SYS_SEMANTIC.SYNONYMS (
              MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE
            ) VALUES (
              :model_id, :version_id, 'METRIC', :metric_id, :old_name, 'RENAME'
            )
        ]], {model_id = model.model_id, version_id = model.version_id, metric_id = metric_id, old_name = old_name})
    end
end

local function definition_operation_count(definition)
    if definition.operation == "DROP_METRIC" or definition.operation == "RENAME_METRIC" then
        return 1
    end
    return #definition.facts + #definition.metrics
end

local function validation_error_message(validation_rows)
    local details = {}
    for _, row in ipairs(validation_rows or {}) do
        if row_value(row, "SEVERITY", 1) == "ERROR" then
            local rule_code = row_value(row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR"
            local object_type = row_value(row, "OBJECT_TYPE", 2) or "OBJECT"
            local object_name = row_value(row, "OBJECT_NAME", 3) or "unknown"
            local message = row_value(row, "MESSAGE", 5) or "model validation failed"
            details[#details + 1] = tostring(rule_code) .. " [" .. tostring(object_type)
                .. " " .. tostring(object_name) .. "]: " .. tostring(message)
            if #details == 5 then
                break
            end
        end
    end
    if #details == 0 then
        return "model validation failed"
    end
    return table.concat(details, "; ")
end

local function apply_definition_changes(definition, model, object_id_value, definition_source_id)
    if definition.operation == "DROP_METRIC" then
        drop_metric(model, object_id_value, definition.metric_name)
    elseif definition.operation == "RENAME_METRIC" then
        rename_metric(model, object_id_value, definition.metric_name, definition.new_metric_name)
    else
        if definition.replace_facts then
            replace_object_columns(object_id_value, "FACT")
        end
        if definition.replace_metrics then
            replace_object_columns(object_id_value, "METRIC")
            prepare_replacement_synonyms(model, definition.metrics)
        end
        for _, fact in ipairs(definition.facts) do
            upsert_fact(model, object_id_value, fact)
        end
        for _, metric in ipairs(definition.metrics) do
            upsert_metric(model, object_id_value, metric, definition_source_id)
        end
    end
end

local function validate_definition_model(model, model_name)
    local validation_rows = query(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
        {model_name = model_name}) or {}
    local error_count = 0
    local warning_count = 0
    for _, row in ipairs(validation_rows) do
        local severity = row_value(row, "SEVERITY", 1)
        if severity == "ERROR" then
            error_count = error_count + 1
        elseif severity == "WARNING" then
            warning_count = warning_count + 1
        end
    end
    local validation_run_id = scalar([[
        SELECT MAX(VALIDATION_RUN_ID)
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    return validation_rows, error_count, warning_count, validation_run_id
end

local function snapshot_model_state(model)
    return {
        attribute_bindings = query([[
            SELECT ATTRIBUTE_BINDING_ID, MODEL_ID, VERSION_ID, ENTITY_ID,
                   ATTRIBUTE_TYPE, ATTRIBUTE_ID, REPRESENTATION_ID,
                   SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY,
                   IS_DEFAULT, STATUS, CREATED_AT, CREATED_BY, UPDATED_AT, UPDATED_BY
            FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        facts = query([[
            SELECT FACT_ID, MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
                   ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, UNIT_HINT,
                   SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE, IS_CERTIFIED, STATUS
            FROM SYS_SEMANTIC.FACTS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        metrics = query([[
            SELECT METRIC_ID, MODEL_ID, VERSION_ID, METRIC_NAME, EXPRESSION, FILTER_EXPR,
                   METRIC_TYPE, BASE_ENTITY_ID, DATA_TYPE, DISPLAY_NAME, DESCRIPTION,
                   FORMAT_HINT, UNIT_HINT, SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE,
                   IS_CERTIFIED, OWNER_ROLE, METRIC_KIND, AGGREGATION_FUNCTION, MEASURE_EXPR,
                   SEMANTIC_FILTER_EXPR, SQL_FILTER_EXPR, DISTINCT_KEY_EXPR,
                   NON_ADDITIVE_DIMENSION_ID, WINDOW_SPEC_JSON, TYPE_PARAMS_JSON,
                   DEFINITION_SOURCE_ID, STATUS
            FROM SYS_SEMANTIC.METRICS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        object_columns = query([[
            SELECT oc.OBJECT_ID, oc.COLUMN_KIND, oc.OBJECT_REF_ID, oc.COLUMN_NAME,
                   oc.ORDINAL_POSITION, oc.IS_VISIBLE
            FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
            JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
              ON so.OBJECT_ID = oc.OBJECT_ID
            WHERE so.MODEL_ID = :model_id
              AND so.VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        metric_inputs = query([[
            SELECT mi.METRIC_ID, mi.INPUT_ROLE, mi.INPUT_OBJECT_TYPE, mi.INPUT_OBJECT_ID,
                   mi.EXPRESSION_ALIAS, mi.OFFSET_WINDOW, mi.FILTER_EXPR, mi.ORDINAL_POSITION
            FROM SYS_SEMANTIC.METRIC_INPUTS mi
            JOIN SYS_SEMANTIC.METRICS mt
              ON mt.METRIC_ID = mi.METRIC_ID
            WHERE mt.MODEL_ID = :model_id
              AND mt.VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        metric_filters = query([[
            SELECT mf.METRIC_ID, mf.FILTER_KIND, mf.FILTER_EXPR, mf.RESOLVED_SQL_EXPR,
                   mf.REQUIRED_DIMENSION_ID, mf.REQUIRED_ENTITY_ID, mf.ORDINAL_POSITION
            FROM SYS_SEMANTIC.METRIC_FILTERS mf
            JOIN SYS_SEMANTIC.METRICS mt
              ON mt.METRIC_ID = mf.METRIC_ID
            WHERE mt.MODEL_ID = :model_id
              AND mt.VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
        synonyms = query([[
            SELECT SYNONYM_ID, MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE
            FROM SYS_SEMANTIC.SYNONYMS
            WHERE MODEL_ID = :model_id
              AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or {},
    }
end

local function clear_model_state(model)
    query([[
        DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_INPUTS
        WHERE METRIC_ID IN (
          SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
          WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        )
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_FILTERS
        WHERE METRIC_ID IN (
          SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
          WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        )
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES
        WHERE METRIC_ID IN (
          SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
          WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        )
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.SYNONYMS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID IN (
          SELECT OBJECT_ID FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
          WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
        )
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.METRICS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
    query([[
        DELETE FROM SYS_SEMANTIC.FACTS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
    ]], {model_id = model.model_id, version_id = model.version_id})
end

local function restore_model_state(model, snapshot)
    clear_model_state(model)
    for _, row in ipairs(snapshot.facts or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.FACTS (
              FACT_ID, MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
              ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, UNIT_HINT,
              SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE, IS_CERTIFIED, STATUS
            ) VALUES (
              :fact_id, :model_id, :version_id, :entity_id, :fact_name, :expression, :data_type,
              :additive_policy, :display_name, :description, :format_hint, :unit_hint,
              :sensitivity_label, :display_policy, :is_private, :is_certified, :status
            )
        ]], {
            fact_id = row_value(row, "FACT_ID", 1),
            model_id = row_value(row, "MODEL_ID", 2),
            version_id = row_value(row, "VERSION_ID", 3),
            entity_id = row_value(row, "ENTITY_ID", 4),
            fact_name = row_value(row, "FACT_NAME", 5),
            expression = row_value(row, "EXPRESSION", 6),
            data_type = row_value(row, "DATA_TYPE", 7),
            additive_policy = row_value(row, "ADDITIVE_POLICY", 8),
            display_name = null_if_missing(row_value(row, "DISPLAY_NAME", 9)),
            description = null_if_missing(row_value(row, "DESCRIPTION", 10)),
            format_hint = null_if_missing(row_value(row, "FORMAT_HINT", 11)),
            unit_hint = null_if_missing(row_value(row, "UNIT_HINT", 12)),
            sensitivity_label = null_if_missing(row_value(row, "SENSITIVITY_LABEL", 13)),
            display_policy = null_if_missing(row_value(row, "DISPLAY_POLICY", 14)),
            is_private = row_value(row, "IS_PRIVATE", 15),
            is_certified = row_value(row, "IS_CERTIFIED", 16),
            status = row_value(row, "STATUS", 17),
        })
    end
    for _, row in ipairs(snapshot.attribute_bindings or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
              ATTRIBUTE_BINDING_ID, MODEL_ID, VERSION_ID, ENTITY_ID,
              ATTRIBUTE_TYPE, ATTRIBUTE_ID, REPRESENTATION_ID,
              SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY,
              IS_DEFAULT, STATUS, CREATED_AT, CREATED_BY, UPDATED_AT, UPDATED_BY
            ) VALUES (
              :binding_id, :model_id, :version_id, :entity_id,
              :attribute_type, :attribute_id, :representation_id,
              :source_expression, :binding_role, :binding_priority,
              :is_default, :status, :created_at, :created_by, :updated_at, :updated_by
            )
        ]], {
            binding_id = row_value(row, "ATTRIBUTE_BINDING_ID", 1),
            model_id = row_value(row, "MODEL_ID", 2),
            version_id = row_value(row, "VERSION_ID", 3),
            entity_id = row_value(row, "ENTITY_ID", 4),
            attribute_type = row_value(row, "ATTRIBUTE_TYPE", 5),
            attribute_id = row_value(row, "ATTRIBUTE_ID", 6),
            representation_id = row_value(row, "REPRESENTATION_ID", 7),
            source_expression = row_value(row, "SOURCE_EXPRESSION", 8),
            binding_role = row_value(row, "BINDING_ROLE", 9),
            binding_priority = row_value(row, "BINDING_PRIORITY", 10),
            is_default = row_value(row, "IS_DEFAULT", 11),
            status = row_value(row, "STATUS", 12),
            created_at = null_if_missing(row_value(row, "CREATED_AT", 13)),
            created_by = null_if_missing(row_value(row, "CREATED_BY", 14)),
            updated_at = null_if_missing(row_value(row, "UPDATED_AT", 15)),
            updated_by = null_if_missing(row_value(row, "UPDATED_BY", 16)),
        })
    end
    for _, row in ipairs(snapshot.metrics or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.METRICS (
              METRIC_ID, MODEL_ID, VERSION_ID, METRIC_NAME, EXPRESSION, FILTER_EXPR,
              METRIC_TYPE, BASE_ENTITY_ID, DATA_TYPE, DISPLAY_NAME, DESCRIPTION,
              FORMAT_HINT, UNIT_HINT, SENSITIVITY_LABEL, DISPLAY_POLICY, IS_PRIVATE,
              IS_CERTIFIED, OWNER_ROLE, METRIC_KIND, AGGREGATION_FUNCTION, MEASURE_EXPR,
              SEMANTIC_FILTER_EXPR, SQL_FILTER_EXPR, DISTINCT_KEY_EXPR,
              NON_ADDITIVE_DIMENSION_ID, WINDOW_SPEC_JSON, TYPE_PARAMS_JSON,
              DEFINITION_SOURCE_ID, STATUS
            ) VALUES (
              :metric_id, :model_id, :version_id, :metric_name, :expression, :filter_expr,
              :metric_type, :base_entity_id, :data_type, :display_name, :description,
              :format_hint, :unit_hint, :sensitivity_label, :display_policy, :is_private,
              :is_certified, :owner_role, :metric_kind, :aggregation_function, :measure_expr,
              :semantic_filter_expr, :sql_filter_expr, :distinct_key_expr,
              :non_additive_dimension_id, :window_spec_json, :type_params_json,
              :definition_source_id, :status
            )
        ]], {
            metric_id = row_value(row, "METRIC_ID", 1),
            model_id = row_value(row, "MODEL_ID", 2),
            version_id = row_value(row, "VERSION_ID", 3),
            metric_name = row_value(row, "METRIC_NAME", 4),
            expression = row_value(row, "EXPRESSION", 5),
            filter_expr = null_if_missing(row_value(row, "FILTER_EXPR", 6)),
            metric_type = row_value(row, "METRIC_TYPE", 7),
            base_entity_id = null_if_missing(row_value(row, "BASE_ENTITY_ID", 8)),
            data_type = row_value(row, "DATA_TYPE", 9),
            display_name = null_if_missing(row_value(row, "DISPLAY_NAME", 10)),
            description = null_if_missing(row_value(row, "DESCRIPTION", 11)),
            format_hint = null_if_missing(row_value(row, "FORMAT_HINT", 12)),
            unit_hint = null_if_missing(row_value(row, "UNIT_HINT", 13)),
            sensitivity_label = null_if_missing(row_value(row, "SENSITIVITY_LABEL", 14)),
            display_policy = null_if_missing(row_value(row, "DISPLAY_POLICY", 15)),
            is_private = row_value(row, "IS_PRIVATE", 16),
            is_certified = row_value(row, "IS_CERTIFIED", 17),
            owner_role = null_if_missing(row_value(row, "OWNER_ROLE", 18)),
            metric_kind = null_if_missing(row_value(row, "METRIC_KIND", 19)),
            aggregation_function = null_if_missing(row_value(row, "AGGREGATION_FUNCTION", 20)),
            measure_expr = null_if_missing(row_value(row, "MEASURE_EXPR", 21)),
            semantic_filter_expr = null_if_missing(row_value(row, "SEMANTIC_FILTER_EXPR", 22)),
            sql_filter_expr = null_if_missing(row_value(row, "SQL_FILTER_EXPR", 23)),
            distinct_key_expr = null_if_missing(row_value(row, "DISTINCT_KEY_EXPR", 24)),
            non_additive_dimension_id = null_if_missing(row_value(row, "NON_ADDITIVE_DIMENSION_ID", 25)),
            window_spec_json = null_if_missing(row_value(row, "WINDOW_SPEC_JSON", 26)),
            type_params_json = null_if_missing(row_value(row, "TYPE_PARAMS_JSON", 27)),
            definition_source_id = null_if_missing(row_value(row, "DEFINITION_SOURCE_ID", 28)),
            status = row_value(row, "STATUS", 29),
        })
    end
    for _, row in ipairs(snapshot.object_columns or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
              OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
            ) VALUES (
              :object_id, :column_kind, :object_ref_id, :column_name, :ordinal_position, :is_visible
            )
        ]], {
            object_id = row_value(row, "OBJECT_ID", 1),
            column_kind = row_value(row, "COLUMN_KIND", 2),
            object_ref_id = row_value(row, "OBJECT_REF_ID", 3),
            column_name = row_value(row, "COLUMN_NAME", 4),
            ordinal_position = row_value(row, "ORDINAL_POSITION", 5),
            is_visible = row_value(row, "IS_VISIBLE", 6),
        })
    end
    for _, row in ipairs(snapshot.metric_inputs or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.METRIC_INPUTS (
              METRIC_ID, INPUT_ROLE, INPUT_OBJECT_TYPE, INPUT_OBJECT_ID,
              EXPRESSION_ALIAS, OFFSET_WINDOW, FILTER_EXPR, ORDINAL_POSITION
            ) VALUES (
              :metric_id, :input_role, :input_object_type, :input_object_id,
              :expression_alias, :offset_window, :filter_expr, :ordinal_position
            )
        ]], {
            metric_id = row_value(row, "METRIC_ID", 1),
            input_role = row_value(row, "INPUT_ROLE", 2),
            input_object_type = row_value(row, "INPUT_OBJECT_TYPE", 3),
            input_object_id = null_if_missing(row_value(row, "INPUT_OBJECT_ID", 4)),
            expression_alias = null_if_missing(row_value(row, "EXPRESSION_ALIAS", 5)),
            offset_window = null_if_missing(row_value(row, "OFFSET_WINDOW", 6)),
            filter_expr = null_if_missing(row_value(row, "FILTER_EXPR", 7)),
            ordinal_position = row_value(row, "ORDINAL_POSITION", 8),
        })
    end
    for _, row in ipairs(snapshot.metric_filters or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.METRIC_FILTERS (
              METRIC_ID, FILTER_KIND, FILTER_EXPR, RESOLVED_SQL_EXPR,
              REQUIRED_DIMENSION_ID, REQUIRED_ENTITY_ID, ORDINAL_POSITION
            ) VALUES (
              :metric_id, :filter_kind, :filter_expr, :resolved_sql_expr,
              :required_dimension_id, :required_entity_id, :ordinal_position
            )
        ]], {
            metric_id = row_value(row, "METRIC_ID", 1),
            filter_kind = row_value(row, "FILTER_KIND", 2),
            filter_expr = row_value(row, "FILTER_EXPR", 3),
            resolved_sql_expr = null_if_missing(row_value(row, "RESOLVED_SQL_EXPR", 4)),
            required_dimension_id = null_if_missing(row_value(row, "REQUIRED_DIMENSION_ID", 5)),
            required_entity_id = null_if_missing(row_value(row, "REQUIRED_ENTITY_ID", 6)),
            ordinal_position = row_value(row, "ORDINAL_POSITION", 7),
        })
    end
    for _, row in ipairs(snapshot.synonyms or {}) do
        query([[
            INSERT INTO SYS_SEMANTIC.SYNONYMS (
              SYNONYM_ID, MODEL_ID, VERSION_ID, OBJECT_TYPE, OBJECT_ID, SYNONYM, SYNONYM_SOURCE
            ) VALUES (
              :synonym_id, :model_id, :version_id, :object_type, :object_id, :synonym, :synonym_source
            )
        ]], {
            synonym_id = row_value(row, "SYNONYM_ID", 1),
            model_id = row_value(row, "MODEL_ID", 2),
            version_id = row_value(row, "VERSION_ID", 3),
            object_type = row_value(row, "OBJECT_TYPE", 4),
            object_id = row_value(row, "OBJECT_ID", 5),
            synonym = row_value(row, "SYNONYM", 6),
            synonym_source = null_if_missing(row_value(row, "SYNONYM_SOURCE", 7)),
        })
    end
end

local function batch_arg(args, name)
    if type(args) ~= "table" then
        return null
    end
    return null_if_missing(args[name])
end

local function batch_call(target, args)
    if target == "SEMANTIC_ADMIN.CREATE_MODEL" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(:model_name, :published_schema, :description, :owner_role)",
            {
                model_name = batch_arg(args, "model_name"),
                published_schema = batch_arg(args, "published_schema"),
                description = batch_arg(args, "description"),
                owner_role = batch_arg(args, "owner_role"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_ENTITY" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(:model_name, :entity_name, :source_schema, :source_object, :source_alias, :primary_key_expr, :grain_description, :description)",
            {
                model_name = batch_arg(args, "model_name"),
                entity_name = batch_arg(args, "entity_name"),
                source_schema = batch_arg(args, "source_schema"),
                source_object = batch_arg(args, "source_object"),
                source_alias = batch_arg(args, "source_alias"),
                primary_key_expr = batch_arg(args, "primary_key_expr"),
                grain_description = batch_arg(args, "grain_description"),
                description = batch_arg(args, "description"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(:model_name, :object_name, :root_entity_name, :description)",
            {
                model_name = batch_arg(args, "model_name"),
                object_name = batch_arg(args, "object_name"),
                root_entity_name = batch_arg(args, "root_entity_name"),
                description = batch_arg(args, "description"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_RELATIONSHIP" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(:model_name, :relationship_name, :from_entity_name, :to_entity_name, :join_condition, :cardinality, :join_type, :fanout_policy)",
            {
                model_name = batch_arg(args, "model_name"),
                relationship_name = batch_arg(args, "relationship_name"),
                from_entity_name = batch_arg(args, "from_entity_name"),
                to_entity_name = batch_arg(args, "to_entity_name"),
                join_condition = batch_arg(args, "join_condition"),
                cardinality = batch_arg(args, "cardinality"),
                join_type = batch_arg(args, "join_type"),
                fanout_policy = batch_arg(args, "fanout_policy"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING(:model_name, :relationship_name, :from_column_name, :from_expression, :to_column_name, :to_expression, :ordinal_position)",
            {
                model_name = batch_arg(args, "model_name"),
                relationship_name = batch_arg(args, "relationship_name"),
                from_column_name = batch_arg(args, "from_column_name"),
                from_expression = batch_arg(args, "from_expression"),
                to_column_name = batch_arg(args, "to_column_name"),
                to_expression = batch_arg(args, "to_expression"),
                ordinal_position = batch_arg(args, "ordinal_position"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_DIMENSION" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(:model_name, :object_name, :entity_name, :dimension_name, :expression, :data_type, :display_name, :description, :format_hint, :is_certified)",
            {
                model_name = batch_arg(args, "model_name"),
                object_name = batch_arg(args, "object_name"),
                entity_name = batch_arg(args, "entity_name"),
                dimension_name = batch_arg(args, "dimension_name"),
                expression = batch_arg(args, "expression"),
                data_type = batch_arg(args, "data_type"),
                display_name = batch_arg(args, "display_name"),
                description = batch_arg(args, "description"),
                format_hint = batch_arg(args, "format_hint"),
                is_certified = batch_arg(args, "is_certified"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_FACT" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(:model_name, :entity_name, :fact_name, :expression, :data_type, :additive_policy, :display_name, :description, :is_private, :is_certified)",
            {
                model_name = batch_arg(args, "model_name"),
                entity_name = batch_arg(args, "entity_name"),
                fact_name = batch_arg(args, "fact_name"),
                expression = batch_arg(args, "expression"),
                data_type = batch_arg(args, "data_type"),
                additive_policy = batch_arg(args, "additive_policy"),
                display_name = batch_arg(args, "display_name"),
                description = batch_arg(args, "description"),
                is_private = batch_arg(args, "is_private"),
                is_certified = batch_arg(args, "is_certified"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_METRIC" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(:model_name, :object_name, :metric_name, :expression, :filter_expr, :metric_type, :base_entity_name, :data_type, :display_name, :description, :format_hint, :is_private, :is_certified)",
            {
                model_name = batch_arg(args, "model_name"),
                object_name = batch_arg(args, "object_name"),
                metric_name = batch_arg(args, "metric_name"),
                expression = batch_arg(args, "expression"),
                filter_expr = batch_arg(args, "filter_expr"),
                metric_type = batch_arg(args, "metric_type"),
                base_entity_name = batch_arg(args, "base_entity_name"),
                data_type = batch_arg(args, "data_type"),
                display_name = batch_arg(args, "display_name"),
                description = batch_arg(args, "description"),
                format_hint = batch_arg(args, "format_hint"),
                is_private = batch_arg(args, "is_private"),
                is_certified = batch_arg(args, "is_certified"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION(:model_name, :scope_type, :scope_name, :vendor_name, :data_json, :source_format, :extension_name)",
            {
                model_name = batch_arg(args, "model_name"),
                scope_type = batch_arg(args, "scope_type"),
                scope_name = batch_arg(args, "scope_name"),
                vendor_name = batch_arg(args, "vendor_name"),
                data_json = batch_arg(args, "data_json"),
                source_format = batch_arg(args, "source_format"),
                extension_name = batch_arg(args, "extension_name"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_UNIQUE_KEY" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY(:model_name, :entity_name, :key_name, :key_kind, :description, :source_format)",
            {
                model_name = batch_arg(args, "model_name"),
                entity_name = batch_arg(args, "entity_name"),
                key_name = batch_arg(args, "key_name"),
                key_kind = batch_arg(args, "key_kind"),
                description = batch_arg(args, "description"),
                source_format = batch_arg(args, "source_format"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN(:model_name, :entity_name, :key_name, :column_name, :expression, :ordinal_position)",
            {
                model_name = batch_arg(args, "model_name"),
                entity_name = batch_arg(args, "entity_name"),
                key_name = batch_arg(args, "key_name"),
                column_name = batch_arg(args, "column_name"),
                expression = batch_arg(args, "expression"),
                ordinal_position = batch_arg(args, "ordinal_position"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_SYNONYM" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(:model_name, :object_type, :object_name, :synonym, :source)",
            {
                model_name = batch_arg(args, "model_name"),
                object_type = batch_arg(args, "object_type"),
                object_name = batch_arg(args, "object_name"),
                synonym = batch_arg(args, "synonym"),
                source = batch_arg(args, "source"),
            }
        )
    elseif target == "SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION" then
        return query(
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(:model_name, :scope_type, :scope_name, :instruction_kind, :instruction_text, :applies_to_role, :priority)",
            {
                model_name = batch_arg(args, "model_name"),
                scope_type = batch_arg(args, "scope_type"),
                scope_name = batch_arg(args, "scope_name"),
                instruction_kind = batch_arg(args, "instruction_kind"),
                instruction_text = batch_arg(args, "instruction_text"),
                applies_to_role = batch_arg(args, "applies_to_role"),
                priority = batch_arg(args, "priority"),
            }
        )
    end
    error("SEMANTIC_OSI_010: unsupported normalized import target: " .. tostring(target))
end

local function metadata_of(operation)
    if type(operation) ~= "table" or type(operation.metadata) ~= "table" then
        return {}
    end
    return operation.metadata
end

local function ref_id_for_object_column(model, kind_value, name)
    local kind_name = upper(kind_value)
    local ref_id = object_id_by_name(model, kind_name, name)
    if ref_id == nil then
        error("SEMANTIC_OSI_020: object-column reference not found: " .. tostring(kind_value) .. " " .. tostring(name))
    end
    return kind_name, ref_id
end

local function visible_value(column, kind_name)
    if column.is_visible == false then
        return false
    end
    if column.is_visible == true then
        return true
    end
    return kind_name ~= "FACT"
end

local function insert_object_column(object_id_value, kind_name, ref_id, column_name, ordinal, is_visible)
    query([[
        INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
          OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
        ) VALUES (
          :object_id, :column_kind, :object_ref_id, :column_name, :ordinal_position, :is_visible
        )
    ]], {
        object_id = object_id_value,
        column_kind = kind_name,
        object_ref_id = ref_id,
        column_name = column_name,
        ordinal_position = ordinal,
        is_visible = is_visible,
    })
end

local function replace_semantic_object_columns(args, metadata)
    local columns = metadata.columns
    if type(columns) ~= "table" or #columns == 0 then
        return
    end
    local model = load_model(args.model_name)
    local object_id_value = object_id(model, args.object_name)
    query("DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE OBJECT_ID = :object_id", {object_id = object_id_value})
    for index, column in ipairs(columns) do
        local kind_name, ref_id = ref_id_for_object_column(model, column.kind, column.name)
        insert_object_column(
            object_id_value,
            kind_name,
            ref_id,
            column.name,
            column.ordinal or index,
            visible_value(column, kind_name)
        )
    end
end

local function patch_operation_object_columns(operation)
    local metadata = metadata_of(operation)
    local columns = metadata.object_columns
    if type(columns) ~= "table" or #columns == 0 then
        return
    end
    local args = operation.arguments or {}
    local kind_name = nil
    local ref_name = nil
    if operation.operation == "add_dimension" then
        kind_name = "DIMENSION"
        ref_name = args.dimension_name
    elseif operation.operation == "add_fact" then
        kind_name = "FACT"
        ref_name = args.fact_name
    elseif operation.operation == "add_metric" then
        kind_name = "METRIC"
        ref_name = args.metric_name
    else
        return
    end
    local model = load_model(args.model_name)
    local _, ref_id = ref_id_for_object_column(model, kind_name, ref_name)
    for index, column in ipairs(columns) do
        local object_id_value = object_id(model, column.object_name)
        query([[
            DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
            WHERE OBJECT_ID = :object_id
              AND COLUMN_KIND = :column_kind
              AND OBJECT_REF_ID = :object_ref_id
        ]], {object_id = object_id_value, column_kind = kind_name, object_ref_id = ref_id})
        insert_object_column(
            object_id_value,
            kind_name,
            ref_id,
            column.column_name or ref_name,
            column.ordinal or index,
            visible_value(column, kind_name)
        )
    end
end

local function patch_relationship_metadata(operation)
    local metadata = metadata_of(operation)
    local native = metadata.native
    if operation.operation ~= "add_relationship" or type(native) ~= "table" then
        return
    end
    if missing(native.description) and missing(native.path_priority) then
        return
    end
    local args = operation.arguments or {}
    local model = load_model(args.model_name)
    query([[
        UPDATE SYS_SEMANTIC.RELATIONSHIPS
        SET DESCRIPTION = COALESCE(:description, DESCRIPTION),
            PATH_PRIORITY = COALESCE(:path_priority, PATH_PRIORITY)
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND UPPER(RELATIONSHIP_NAME) = UPPER(:relationship_name)
    ]], {
        model_id = model.model_id,
        version_id = model.version_id,
        relationship_name = args.relationship_name,
        description = null_if_missing(native.description),
        path_priority = null_if_missing(native.path_priority),
    })
end

local function non_additive_dimension_id(model, native)
    if missing(native.non_additive_dimension) then
        return null
    end
    local dim_name = tostring(native.non_additive_dimension):match("^%s*([A-Za-z_][A-Za-z0-9_]*)")
    local dim = dimension_by_name(model, dim_name)
    if dim == nil then
        return null
    end
    return dim.id
end

local function patch_metric_metadata(operation)
    local metadata = metadata_of(operation)
    local native = metadata.native
    if operation.operation ~= "add_metric" or type(native) ~= "table" then
        return
    end
    local args = operation.arguments or {}
    local model = load_model(args.model_name)
    local metric_id = object_id_by_name(model, "METRIC", args.metric_name)
    if metric_id == nil then
        error("SEMANTIC_OSI_030: metric not found for metadata patch: " .. tostring(args.metric_name))
    end
    local metric_for_inputs = {
        name = args.metric_name,
        expression = args.expression,
        metric_type = native.metric_type or args.metric_type,
        semantic_filter_expr = native.semantic_filter_expr,
    }
    refresh_metric_inputs(model, metric_id, metric_for_inputs)
    local sql_filter_expr = native.sql_filter_expr or metric_for_inputs.sql_filter_expr
    query([[
        UPDATE SYS_SEMANTIC.METRICS
        SET METRIC_KIND = COALESCE(:metric_kind, METRIC_KIND),
            AGGREGATION_FUNCTION = COALESCE(:aggregation_function, AGGREGATION_FUNCTION),
            MEASURE_EXPR = COALESCE(:measure_expr, MEASURE_EXPR),
            SEMANTIC_FILTER_EXPR = COALESCE(:semantic_filter_expr, SEMANTIC_FILTER_EXPR),
            SQL_FILTER_EXPR = COALESCE(:sql_filter_expr, SQL_FILTER_EXPR),
            FILTER_EXPR = COALESCE(:sql_filter_expr, FILTER_EXPR),
            DISTINCT_KEY_EXPR = COALESCE(:distinct_key_expr, DISTINCT_KEY_EXPR),
            NON_ADDITIVE_DIMENSION_ID = COALESCE(:non_additive_dimension_id, NON_ADDITIVE_DIMENSION_ID),
            WINDOW_SPEC_JSON = COALESCE(:window_spec_json, WINDOW_SPEC_JSON),
            TYPE_PARAMS_JSON = COALESCE(:type_params_json, TYPE_PARAMS_JSON),
            UNIT_HINT = COALESCE(:unit_hint, UNIT_HINT),
            SENSITIVITY_LABEL = COALESCE(:sensitivity_label, SENSITIVITY_LABEL),
            DISPLAY_POLICY = COALESCE(:display_policy, DISPLAY_POLICY),
            OWNER_ROLE = COALESCE(:owner_role, OWNER_ROLE)
        WHERE METRIC_ID = :metric_id
    ]], {
        metric_id = metric_id,
        metric_kind = null_if_missing(native.metric_kind),
        aggregation_function = null_if_missing(native.aggregation_function),
        measure_expr = null_if_missing(native.measure_expr),
        semantic_filter_expr = null_if_missing(native.semantic_filter_expr),
        sql_filter_expr = null_if_missing(sql_filter_expr),
        distinct_key_expr = null_if_missing(native.distinct_key_expr),
        non_additive_dimension_id = non_additive_dimension_id(model, native),
        window_spec_json = null_if_missing(native.window_spec_json),
        type_params_json = null_if_missing(native.type_params_json),
        unit_hint = null_if_missing(native.unit_hint),
        sensitivity_label = null_if_missing(native.sensitivity_label),
        display_policy = null_if_missing(native.display_policy),
        owner_role = null_if_missing(native.owner_role),
    })
end

local function model_names_from_plan(plan)
    local names = {}
    local seen = {}
    for _, model in ipairs(plan.models or {}) do
        if type(model) == "table" and not missing(model.model_name) and not seen[model.model_name] then
            names[#names + 1] = model.model_name
            seen[model.model_name] = true
        end
    end
    for _, operation in ipairs(plan.operations or {}) do
        local args = operation.arguments or {}
        if operation.operation == "create_model" and not missing(args.model_name) and not seen[args.model_name] then
            names[#names + 1] = args.model_name
            seen[args.model_name] = true
        end
    end
    return names
end

local function validation_summary(plan, warnings, warnings_as_errors)
    local error_count = 0
    local warning_count = 0
    local validation_run_id = nil
    for _, model_name in ipairs(model_names_from_plan(plan)) do
        local rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name}) or {}
        local model = load_model(model_name)
        validation_run_id = scalar([[
            SELECT MAX(VALIDATION_RUN_ID)
            FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id
              AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id}) or validation_run_id
        for _, row in ipairs(rows) do
            local severity = row_value(row, "SEVERITY", 1)
            if severity == "ERROR" or severity == "WARNING" then
                warnings[#warnings + 1] = {
                    code = "OSI_APPLY_030",
                    severity = severity,
                    path = tostring(row_value(row, "OBJECT_NAME", 3) or row_value(row, "OBJECT_TYPE", 2) or "$"),
                    message = tostring(row_value(row, "RULE_CODE", 4) or "") .. ": " .. tostring(row_value(row, "MESSAGE", 5) or ""),
                }
            end
            if severity == "ERROR" then
                error_count = error_count + 1
            elseif severity == "WARNING" then
                warning_count = warning_count + 1
            end
        end
    end
    if error_count > 0 then
        return "ERROR", validation_run_id, tostring(error_count) .. " validation error(s)."
    end
    if sql_bool(warnings_as_errors) and warning_count > 0 then
        return "ERROR", validation_run_id, tostring(warning_count) .. " validation warning(s) promoted to errors."
    end
    return "OK", validation_run_id, "Normalized OSI import applied."
end

local function apply_metadata_patches(plan)
    for _, operation in ipairs(plan.operations or {}) do
        patch_relationship_metadata(operation)
        patch_metric_metadata(operation)
        patch_operation_object_columns(operation)
    end
    for _, operation in ipairs(plan.operations or {}) do
        if operation.operation == "add_semantic_object" then
            replace_semantic_object_columns(operation.arguments or {}, metadata_of(operation))
        end
    end
end

function M.apply_normalized_osi_import(plan_json, validate_after_apply, warnings_as_errors)
    local rows = {}
    local warnings = {}
    local current_operation = nil
    local ok, result = pcall(function()
        local plan = json_decode(plan_json)
        if type(plan) ~= "table" or type(plan.operations) ~= "table" then
            error("SEMANTIC_OSI_001: normalized import plan must contain operations")
        end
        for index, operation in ipairs(plan.operations) do
            if type(operation) ~= "table" then
                error("SEMANTIC_OSI_002: normalized operation must be an object")
            end
            current_operation = operation
            current_operation.index = index - 1
            local target = operation.target
            local result_rows = batch_call(target, operation.arguments or {}) or {}
            rows[#rows + 1] = {
                "OK",
                index - 1,
                operation.operation or null,
                target or null,
                operation.source_path or null,
                #result_rows,
                nil,
                nil,
                "Applied normalized operation.",
            }
        end
        apply_metadata_patches(plan)
        local status = "OK"
        local validation_run_id = nil
        local message = "Normalized OSI import applied."
        if sql_bool(validate_after_apply) then
            status, validation_run_id, message = validation_summary(plan, warnings, warnings_as_errors)
        end
        rows[#rows + 1] = {
            status,
            nil,
            "validate_model",
            "SEMANTIC_ADMIN.VALIDATE_MODEL",
            "$.models",
            nil,
            json_encode(warnings),
            validation_run_id or null,
            message,
        }
        return rows
    end)
    if ok then
        return result
    end
    rows[#rows + 1] = {
        "ERROR",
        current_operation and current_operation.index or nil,
        current_operation and current_operation.operation or "apply_normalized_osi_import",
        current_operation and current_operation.target or "SEMANTIC_ADMIN.APPLY_NORMALIZED_OSI_IMPORT",
        current_operation and current_operation.source_path or "$",
        nil,
        json_encode(warnings),
        nil,
        tostring(result),
    }
    return rows
end

function M.apply_semantic_definition(definition_sql, dry_run)
    local source_id = nil
    local snapshot = nil
    local restore_model = nil
    local ok, result = pcall(function()
        local definition = parse_definition(definition_sql)
        local normalized_json = json_encode(definition)
        local operation_count = definition_operation_count(definition)
        local is_dry_run = sql_bool(dry_run)
        local model = load_model(definition.model_name)
        restore_model = model
        local object_id_value = object_id(model, definition.object_name)
        snapshot = snapshot_model_state(model)
        if not is_dry_run then
            source_id = insert_source(model, definition, definition_sql, normalized_json, "APPLYING")
        end
        apply_definition_changes(definition, model, object_id_value, source_id)
        local validation_rows, error_count, warning_count, validation_run_id =
            validate_definition_model(model, definition.model_name)
        if is_dry_run then
            local validation_details = error_count > 0 and validation_error_message(validation_rows) or nil
            restore_model_state(model, snapshot)
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = definition.model_name})
            restore_model = nil
            snapshot = nil
            if error_count > 0 then
                return {{"ERROR", "SEMANTIC_DDL_090", "Dry-run rejected; validation failed: "
                    .. validation_details .. ". No catalog changes were committed.",
                    normalized_json, operation_count, validation_run_id}}
            end
            local message = "Dry-run parsed and validated the Semantic SQL definition; no catalog changes were committed."
            if warning_count > 0 then
                message = message .. " Validation returned " .. tostring(warning_count) .. " warning(s)."
            end
            return {{"DRY_RUN", nil, message, normalized_json, operation_count, validation_run_id}}
        end
        query([[
            UPDATE SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES
            SET APPLY_STATUS = :status,
                VALIDATION_RUN_ID = :validation_run_id
            WHERE DEFINITION_SOURCE_ID = :source_id
        ]], {status = error_count > 0 and "VALIDATION_FAILED" or "APPLIED", validation_run_id = validation_run_id, source_id = source_id})
        if error_count > 0 then
            local validation_details = validation_error_message(validation_rows)
            restore_model_state(model, snapshot)
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = definition.model_name})
            return {{"ERROR", "SEMANTIC_DDL_090", "Definition rejected; validation failed: "
                .. validation_details .. ". Catalog state was restored.", normalized_json, operation_count, validation_run_id}}
        end
        return {{"OK", nil, "Semantic definition applied.", normalized_json, operation_count, validation_run_id}}
    end)
    if ok then
        return result
    end
    if source_id ~= nil then
        query([[
            UPDATE SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES
            SET APPLY_STATUS = 'ERROR'
            WHERE DEFINITION_SOURCE_ID = :source_id
        ]], {source_id = source_id})
    end
    if restore_model ~= nil and snapshot ~= nil then
        restore_model_state(restore_model, snapshot)
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = restore_model.model_name})
    end
    local message = tostring(result)
    local error_code = string.match(message, "(SEMANTIC_DDL_%d+)")
    return {{"ERROR", error_code or "SEMANTIC_DDL_999", message, nil, nil, nil}}
end

local function parse_metric_ref(ref)
    local parts = {}
    for part in string.gmatch(tostring(ref or ""), "[^.]+") do
        parts[#parts + 1] = part
    end
    if #parts ~= 3 then
        error("SEMANTIC_DDL_050: metric reference must be model.object.metric")
    end
    return normalize_name(parts[1], "MODEL_NAME"), normalize_name(parts[2], "OBJECT_NAME"), normalize_name(parts[3], "METRIC_NAME")
end

local function load_metric(model_name, object_name, metric_name)
    local rows = query([[
        SELECT mo.MODEL_NAME, mo.OBJECT_NAME, mo.METRIC_ID, mo.METRIC_NAME,
               mo.DISPLAY_NAME, mo.METRIC_KIND, mo.METRIC_TYPE, mo.BASE_ENTITY_NAME,
               mo.FORMAT_HINT, mo.IS_CERTIFIED, mo.IS_PRIVATE, mo.OWNER_ROLE,
               mo.DESCRIPTION, mo.SYNONYMS, mt.EXPRESSION, mt.SEMANTIC_FILTER_EXPR,
               mt.FILTER_EXPR, mt.DATA_TYPE, mt.DEFINITION_SOURCE_ID
        FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo
        JOIN SYS_SEMANTIC.METRICS mt
          ON mt.METRIC_ID = mo.METRIC_ID
        WHERE UPPER(mo.MODEL_NAME) = UPPER(:model_name)
          AND UPPER(mo.OBJECT_NAME) = UPPER(:object_name)
          AND UPPER(mo.METRIC_NAME) = UPPER(:metric_name)
          AND mo.STATUS = 'ACTIVE'
          AND mo.IS_PRIVATE = FALSE
          AND EXISTS (
            SELECT 1
            FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af
            WHERE af.FIELD_KIND = 'METRIC'
              AND af.MODEL_NAME = mo.MODEL_NAME
              AND af.OBJECT_NAME = mo.OBJECT_NAME
              AND af.FIELD_ID = mo.METRIC_ID
          )
    ]], {model_name = model_name, object_name = object_name, metric_name = metric_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_DDL_051: metric not found: " .. model_name .. "." .. object_name .. "." .. metric_name)
    end
    return rows[1]
end

function M.describe_semantic_metric(model_name, object_name, metric_name)
    local row = load_metric(model_name, object_name, metric_name)
    local rows = {}
    local function add(section, name, value)
        rows[#rows + 1] = {section, name, missing(value) and null or tostring(value)}
    end
    add("Identity", "model_name", row_value(row, "MODEL_NAME", 1))
    add("Identity", "object_name", row_value(row, "OBJECT_NAME", 2))
    add("Identity", "metric_name", row_value(row, "METRIC_NAME", 4))
    add("Identity", "display_name", row_value(row, "DISPLAY_NAME", 5))
    add("Meaning", "description", row_value(row, "DESCRIPTION", 13))
    add("Meaning", "synonyms", row_value(row, "SYNONYMS", 14))
    add("Computation", "metric_kind", row_value(row, "METRIC_KIND", 6))
    add("Computation", "metric_type", row_value(row, "METRIC_TYPE", 7))
    add("Computation", "expression", row_value(row, "EXPRESSION", 15))
    add("Computation", "semantic_filter", row_value(row, "SEMANTIC_FILTER_EXPR", 16))
    add("Computation", "sql_filter", row_value(row, "FILTER_EXPR", 17))
    add("Computation", "base_entity", row_value(row, "BASE_ENTITY_NAME", 8))
    add("Governance", "visibility", row_value(row, "IS_PRIVATE", 11) and "PRIVATE" or "PUBLIC")
    add("Governance", "certified", row_value(row, "IS_CERTIFIED", 10))
    add("Governance", "owner_role", row_value(row, "OWNER_ROLE", 12))
    add("Presentation", "format", row_value(row, "FORMAT_HINT", 9))
    add("Presentation", "data_type", row_value(row, "DATA_TYPE", 18))
    return rows
end

function M.explain_semantic_metric(model_name, object_name, metric_name)
    local metric = load_metric(model_name, object_name, metric_name)
    local metric_id = row_value(metric, "METRIC_ID", 3)
    local rows = {}
    local function add(section, item, detail)
        rows[#rows + 1] = {section, item, missing(detail) and null or tostring(detail)}
    end
    add("Definition", "expression", row_value(metric, "EXPRESSION", 15))
    add("Definition", "semantic_filter", row_value(metric, "SEMANTIC_FILTER_EXPR", 16))
    add("Aggregation", "base_entity", row_value(metric, "BASE_ENTITY_NAME", 8))
    for _, dep in ipairs(query([[
        SELECT INPUT_ROLE, INPUT_OBJECT_TYPE, INPUT_OBJECT_NAME
        FROM SEMANTIC_CATALOG.METRIC_LINEAGE
        WHERE METRIC_ID = :metric_id
        ORDER BY ORDINAL_POSITION
    ]], {metric_id = metric_id}) or {}) do
        add("Lineage", tostring(row_value(dep, "INPUT_ROLE", 1)) .. ":" .. tostring(row_value(dep, "INPUT_OBJECT_TYPE", 2)), row_value(dep, "INPUT_OBJECT_NAME", 3))
    end
    for _, dim in ipairs(query([[
        SELECT DIMENSION_NAME
        FROM SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS
        WHERE METRIC_ID = :metric_id
          AND IS_VALID = TRUE
        ORDER BY DIMENSION_NAME
    ]], {metric_id = metric_id}) or {}) do
        add("Compatibility", "valid_dimension", row_value(dim, "DIMENSION_NAME", 1))
    end
    local validation_status = scalar([[
        SELECT STATUS
        FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE VALIDATION_RUN_ID = (
          SELECT MAX(VALIDATION_RUN_ID)
          FROM SYS_SEMANTIC.VALIDATION_RUNS
          WHERE MODEL_NAME = :model_name
        )
    ]], {model_name = model_name})
    add("Validation", "latest_status", validation_status)
    return rows
end

local function canonical_metric_sql(model_name, object_name, metric_name)
    local row = load_metric(model_name, object_name, metric_name)
    local lines = {}
    lines[#lines + 1] = "ALTER SEMANTIC VIEW " .. model_name .. "." .. object_name
    lines[#lines + 1] = "  ADD OR REPLACE METRIC " .. tostring(row_value(row, "METRIC_NAME", 4))
    lines[#lines + 1] = "  AS " .. tostring(row_value(row, "EXPRESSION", 15))
    lines[#lines + 1] = "  ON ENTITY " .. tostring(row_value(row, "BASE_ENTITY_NAME", 8))
    lines[#lines + 1] = "  RETURNS " .. tostring(row_value(row, "DATA_TYPE", 18))
    if not missing(row_value(row, "SEMANTIC_FILTER_EXPR", 16)) then
        lines[#lines + 1] = "  FILTER (WHERE " .. tostring(row_value(row, "SEMANTIC_FILTER_EXPR", 16)) .. ")"
    end
    if not missing(row_value(row, "FORMAT_HINT", 9)) then
        lines[#lines + 1] = "  FORMAT " .. sql_string(row_value(row, "FORMAT_HINT", 9))
    end
    if not missing(row_value(row, "DISPLAY_NAME", 5)) then
        lines[#lines + 1] = "  DISPLAY " .. sql_string(row_value(row, "DISPLAY_NAME", 5))
    end
    if not missing(row_value(row, "DESCRIPTION", 13)) then
        lines[#lines + 1] = "  COMMENT " .. sql_string(row_value(row, "DESCRIPTION", 13))
    end
    if not missing(row_value(row, "SYNONYMS", 14)) then
        local syn_literals = {}
        for synonym in string.gmatch(tostring(row_value(row, "SYNONYMS", 14)), "([^,]+)") do
            syn_literals[#syn_literals + 1] = sql_string(trim(synonym))
        end
        lines[#lines + 1] = "  SYNONYMS (" .. table.concat(syn_literals, ", ") .. ")"
    end
    lines[#lines + 1] = "  " .. tostring(row_value(row, "METRIC_TYPE", 7))
        .. (row_value(row, "IS_PRIVATE", 11) and " PRIVATE" or " PUBLIC")
        .. (row_value(row, "IS_CERTIFIED", 10) and " CERTIFIED" or "")
        .. ";"
    return table.concat(lines, "\n")
end

local function canonical_entity_sql(model_name, row)
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
        .. table.concat({
            sql_string(model_name),
            sql_string(row_value(row, "ENTITY_NAME", 1)),
            sql_string(row_value(row, "SOURCE_SCHEMA", 2)),
            sql_string(row_value(row, "SOURCE_OBJECT", 3)),
            sql_string(row_value(row, "SOURCE_ALIAS", 4)),
            sql_string(row_value(row, "PRIMARY_KEY_EXPR", 5)),
            sql_string(row_value(row, "GRAIN_DESCRIPTION", 6)),
            sql_string(row_value(row, "DESCRIPTION", 7)),
        }, ", ") .. ");"
end

local function canonical_relationship_sql(model_name, row, mappings)
    local lines = {}
    lines[#lines + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP("
        .. table.concat({
            sql_string(model_name),
            sql_string(row_value(row, "RELATIONSHIP_NAME", 1)),
            sql_string(row_value(row, "FROM_ENTITY_NAME", 2)),
            sql_string(row_value(row, "TO_ENTITY_NAME", 3)),
            sql_string(row_value(row, "JOIN_CONDITION", 4)),
            sql_string(row_value(row, "RELATIONSHIP_CARDINALITY", 5)),
            sql_string(row_value(row, "JOIN_TYPE", 6)),
            sql_string(row_value(row, "FANOUT_POLICY", 7)),
        }, ", ") .. ");"
    for _, mapping in ipairs(mappings or {}) do
        lines[#lines + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
            .. table.concat({
                sql_string(model_name),
                sql_string(row_value(row, "RELATIONSHIP_NAME", 1)),
                sql_string(row_value(mapping, "FROM_COLUMN_NAME", 2)),
                sql_string(row_value(mapping, "FROM_EXPRESSION", 3)),
                sql_string(row_value(mapping, "TO_COLUMN_NAME", 4)),
                sql_string(row_value(mapping, "TO_EXPRESSION", 5)),
                tostring(row_value(mapping, "ORDINAL_POSITION", 1)),
            }, ", ") .. ");"
    end
    return table.concat(lines, "\n")
end

local function canonical_fact_sql(model_name, row)
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT("
        .. table.concat({
            sql_string(model_name),
            sql_string(row_value(row, "ENTITY_NAME", 2)),
            sql_string(row_value(row, "FACT_NAME", 1)),
            sql_string(row_value(row, "EXPRESSION", 3)),
            sql_string(row_value(row, "DATA_TYPE", 4)),
            sql_string(row_value(row, "ADDITIVE_POLICY", 5)),
            sql_string(row_value(row, "DISPLAY_NAME", 6)),
            sql_string(row_value(row, "DESCRIPTION", 7)),
            sql_boolean(row_value(row, "IS_PRIVATE", 8)),
            sql_boolean(row_value(row, "IS_CERTIFIED", 9)),
        }, ", ") .. ");"
end

local function canonical_dimension_sql(model_name, object_name, row)
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
        .. table.concat({
            sql_string(model_name),
            sql_string(object_name),
            sql_string(row_value(row, "ENTITY_NAME", 2)),
            sql_string(row_value(row, "DIMENSION_NAME", 1)),
            sql_string(row_value(row, "EXPRESSION", 3)),
            sql_string(row_value(row, "DATA_TYPE", 4)),
            sql_string(row_value(row, "DISPLAY_NAME", 5)),
            sql_string(row_value(row, "DESCRIPTION", 6)),
            sql_string(row_value(row, "FORMAT_HINT", 7)),
            sql_boolean(row_value(row, "IS_CERTIFIED", 8)),
        }, ", ") .. ");"
end

function M.export_semantic_definition(model_name, object_name, metric_name)
    local filter_kind = nil
    if not missing(metric_name) then
        local maybe_kind = upper(trim(metric_name))
        if maybe_kind == "ENTITY" or maybe_kind == "RELATIONSHIP" or maybe_kind == "FACT" or maybe_kind == "DIMENSION" or maybe_kind == "METRIC" then
            filter_kind = maybe_kind
        end
    end
    if not missing(metric_name) and filter_kind == nil then
        return {{"METRIC", model_name .. "." .. object_name .. "." .. metric_name, canonical_metric_sql(model_name, object_name, metric_name)}}
    end
    local rows = {}
    local function add_export(kind, ref, definition_sql)
        if filter_kind == nil or filter_kind == kind then
            rows[#rows + 1] = {kind, ref, definition_sql}
        end
    end
    if missing(object_name) then
        for _, row in ipairs(query([[
            SELECT e.ENTITY_NAME, er.SOURCE_SCHEMA, er.SOURCE_OBJECT, er.SOURCE_ALIAS,
                   e.PRIMARY_KEY_EXPR, e.GRAIN_DESCRIPTION, e.DESCRIPTION
            FROM SYS_SEMANTIC.ENTITIES e
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = e.MODEL_ID
             AND m.ACTIVE_VERSION_ID = e.VERSION_ID
            JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
              ON er.ENTITY_ID = e.ENTITY_ID
             AND er.MODEL_ID = e.MODEL_ID
             AND er.VERSION_ID = e.VERSION_ID
             AND er.REPRESENTATION_ROLE = 'PRIMARY'
             AND er.STATUS = 'ACTIVE'
            WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
              AND e.STATUS = 'ACTIVE'
            ORDER BY ENTITY_ID
        ]], {model_name = model_name}) or {}) do
            local name = row_value(row, "ENTITY_NAME", 1)
            add_export("ENTITY", model_name .. "." .. name, canonical_entity_sql(model_name, row))
        end
        for _, row in ipairs(query([[
            SELECT r.RELATIONSHIP_NAME, fe.ENTITY_NAME AS FROM_ENTITY_NAME,
                   te.ENTITY_NAME AS TO_ENTITY_NAME, r.JOIN_CONDITION,
                   r.RELATIONSHIP_CARDINALITY, r.JOIN_TYPE, r.FANOUT_POLICY,
                   r.RELATIONSHIP_ID
            FROM SYS_SEMANTIC.RELATIONSHIPS r
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = r.MODEL_ID
             AND m.ACTIVE_VERSION_ID = r.VERSION_ID
            JOIN SYS_SEMANTIC.ENTITIES fe
              ON fe.ENTITY_ID = r.FROM_ENTITY_ID
            JOIN SYS_SEMANTIC.ENTITIES te
              ON te.ENTITY_ID = r.TO_ENTITY_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
              AND r.STATUS = 'ACTIVE'
            ORDER BY r.RELATIONSHIP_ID
        ]], {model_name = model_name}) or {}) do
            local name = row_value(row, "RELATIONSHIP_NAME", 1)
            local relationship_id = row_value(row, "RELATIONSHIP_ID", 8)
            local mappings = {}
            if not missing(relationship_id) then
                mappings = query([[
                    SELECT ORDINAL_POSITION, FROM_COLUMN_NAME, FROM_EXPRESSION,
                           TO_COLUMN_NAME, TO_EXPRESSION
                    FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
                    WHERE RELATIONSHIP_ID = :relationship_id
                    ORDER BY ORDINAL_POSITION
                ]], {relationship_id = relationship_id}) or {}
            end
            add_export("RELATIONSHIP", model_name .. "." .. name,
                canonical_relationship_sql(model_name, row, mappings))
        end
        for _, row in ipairs(query([[
            SELECT f.FACT_NAME, e.ENTITY_NAME, f.EXPRESSION, f.DATA_TYPE,
                   f.ADDITIVE_POLICY, f.DISPLAY_NAME, f.DESCRIPTION,
                   f.IS_PRIVATE, f.IS_CERTIFIED
            FROM SYS_SEMANTIC.FACTS f
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = f.MODEL_ID
             AND m.ACTIVE_VERSION_ID = f.VERSION_ID
            JOIN SYS_SEMANTIC.ENTITIES e
              ON e.ENTITY_ID = f.ENTITY_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
              AND f.STATUS = 'ACTIVE'
            ORDER BY f.FACT_ID
        ]], {model_name = model_name}) or {}) do
            local name = row_value(row, "FACT_NAME", 1)
            add_export("FACT", model_name .. "." .. name, canonical_fact_sql(model_name, row))
        end
        for _, row in ipairs(query([[
            SELECT so.OBJECT_NAME, d.DIMENSION_NAME, e.ENTITY_NAME,
                   d.EXPRESSION, d.DATA_TYPE, d.DISPLAY_NAME,
                   d.DESCRIPTION, d.FORMAT_HINT, d.IS_CERTIFIED
            FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
            JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
              ON so.OBJECT_ID = oc.OBJECT_ID
            JOIN SYS_SEMANTIC.DIMENSIONS d
              ON d.DIMENSION_ID = oc.OBJECT_REF_ID
            JOIN SYS_SEMANTIC.ENTITIES e
              ON e.ENTITY_ID = d.ENTITY_ID
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = so.MODEL_ID
             AND m.ACTIVE_VERSION_ID = so.VERSION_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
              AND oc.COLUMN_KIND = 'DIMENSION'
              AND oc.IS_VISIBLE = TRUE
              AND d.STATUS = 'ACTIVE'
              AND d.IS_HIDDEN = FALSE
            ORDER BY so.OBJECT_NAME, oc.ORDINAL_POSITION
        ]], {model_name = model_name}) or {}) do
            local current_object_name = row_value(row, "OBJECT_NAME", 1)
            local name = row_value(row, "DIMENSION_NAME", 2)
            add_export("DIMENSION", model_name .. "." .. current_object_name .. "." .. name, canonical_dimension_sql(model_name, current_object_name, row))
        end
        for _, row in ipairs(query([[
            SELECT OBJECT_NAME, METRIC_NAME
            FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo
            WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
              AND STATUS = 'ACTIVE'
              AND IS_PRIVATE = FALSE
              AND EXISTS (
                SELECT 1
                FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af
                WHERE af.FIELD_KIND = 'METRIC'
                  AND af.MODEL_NAME = mo.MODEL_NAME
                  AND af.OBJECT_NAME = mo.OBJECT_NAME
                  AND af.FIELD_ID = mo.METRIC_ID
              )
            ORDER BY OBJECT_NAME, METRIC_NAME
        ]], {model_name = model_name}) or {}) do
            local current_object_name = row_value(row, "OBJECT_NAME", 1)
            local name = row_value(row, "METRIC_NAME", 2)
            add_export("METRIC", model_name .. "." .. current_object_name .. "." .. name, canonical_metric_sql(model_name, current_object_name, name))
        end
        return rows
    end
    for _, row in ipairs(query([[
        SELECT d.DIMENSION_NAME, e.ENTITY_NAME, d.EXPRESSION, d.DATA_TYPE,
               d.DISPLAY_NAME, d.DESCRIPTION, d.FORMAT_HINT, d.IS_CERTIFIED
        FROM SYS_SEMANTIC.OBJECT_COLUMNS oc
        JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so
          ON so.OBJECT_ID = oc.OBJECT_ID
        JOIN SYS_SEMANTIC.DIMENSIONS d
          ON d.DIMENSION_ID = oc.OBJECT_REF_ID
        JOIN SYS_SEMANTIC.ENTITIES e
          ON e.ENTITY_ID = d.ENTITY_ID
        JOIN SYS_SEMANTIC.MODELS m
          ON m.MODEL_ID = so.MODEL_ID
         AND m.ACTIVE_VERSION_ID = so.VERSION_ID
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
          AND UPPER(so.OBJECT_NAME) = UPPER(:object_name)
          AND oc.COLUMN_KIND = 'DIMENSION'
          AND oc.IS_VISIBLE = TRUE
          AND d.STATUS = 'ACTIVE'
          AND d.IS_HIDDEN = FALSE
        ORDER BY oc.ORDINAL_POSITION
    ]], {model_name = model_name, object_name = object_name}) or {}) do
        local name = row_value(row, "DIMENSION_NAME", 1)
        add_export("DIMENSION", model_name .. "." .. object_name .. "." .. name, canonical_dimension_sql(model_name, object_name, row))
    end
    for _, row in ipairs(query([[
        SELECT METRIC_NAME
        FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo
        WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
          AND UPPER(OBJECT_NAME) = UPPER(:object_name)
          AND STATUS = 'ACTIVE'
          AND IS_PRIVATE = FALSE
          AND EXISTS (
            SELECT 1
            FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af
            WHERE af.FIELD_KIND = 'METRIC'
              AND af.MODEL_NAME = mo.MODEL_NAME
              AND af.OBJECT_NAME = mo.OBJECT_NAME
              AND af.FIELD_ID = mo.METRIC_ID
          )
        ORDER BY METRIC_NAME
    ]], {model_name = model_name, object_name = object_name}) or {}) do
        local name = row_value(row, "METRIC_NAME", 1)
        add_export("METRIC", model_name .. "." .. object_name .. "." .. name, canonical_metric_sql(model_name, object_name, name))
    end
    return rows
end

local function parse_show_metrics(sql_text)
    local certified = string.match(upper(sql_text), "^%s*SHOW%s+CERTIFIED%s+SEMANTIC%s+METRICS")
    local private = string.match(upper(sql_text), "^%s*SHOW%s+PRIVATE%s+SEMANTIC%s+METRICS")
    local ref = string.match(sql_text, "[Ii][Nn]%s+([A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*)")
    if ref == nil then
        return nil
    end
    ref = string.gsub(ref, "%s+", "")
    local model_name, object_name = string.match(ref, "^([^.]+)%.([^.]+)$")
    local like_value = string.match(sql_text, "[Ll][Ii][Kk][Ee]%s+'([^']*)'")
    local where_parts = {
        "UPPER(mo.MODEL_NAME) = UPPER(" .. sql_string(model_name) .. ")",
        "UPPER(mo.OBJECT_NAME) = UPPER(" .. sql_string(object_name) .. ")",
        "mo.STATUS = 'ACTIVE'",
        [[EXISTS (
    SELECT 1
    FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af
    WHERE af.FIELD_KIND = 'METRIC'
      AND af.MODEL_NAME = mo.MODEL_NAME
      AND af.OBJECT_NAME = mo.OBJECT_NAME
      AND af.FIELD_ID = mo.METRIC_ID
  )]],
    }
    if certified then
        where_parts[#where_parts + 1] = "mo.IS_CERTIFIED = TRUE"
    end
    if private then
        where_parts[#where_parts + 1] = "mo.IS_PRIVATE = TRUE"
    else
        where_parts[#where_parts + 1] = "mo.IS_PRIVATE = FALSE"
    end
    if like_value ~= nil then
        where_parts[#where_parts + 1] = "(UPPER(mo.METRIC_NAME) LIKE UPPER(" .. sql_string("%" .. like_value .. "%") .. ") OR UPPER(mo.DISPLAY_NAME) LIKE UPPER(" .. sql_string("%" .. like_value .. "%") .. "))"
    end
    return [[
SELECT mo.METRIC_NAME, mo.DISPLAY_NAME, mo.METRIC_KIND, mo.BASE_ENTITY_NAME, mo.FORMAT_HINT,
       mo.IS_CERTIFIED, mo.IS_PRIVATE, mo.OWNER_ROLE, mo.DESCRIPTION, mo.SYNONYMS
FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo
WHERE ]] .. table.concat(where_parts, "\n  AND ") .. "\nORDER BY METRIC_NAME"
end

local function parse_metric_ref_from_command(sql_text)
    local ref = string.match(sql_text, "([A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*)")
    if ref == nil then
        return nil
    end
    ref = string.gsub(ref, "%s+", "")
    local model_name, object_name, metric_name = string.match(ref, "^([^.]+)%.([^.]+)%.([^.]+)$")
    return model_name, object_name, metric_name
end

local function parse_object_ref_from_command(sql_text)
    local ref = string.match(sql_text, "([A-Za-z_][A-Za-z0-9_]*%s*%.%s*[A-Za-z_][A-Za-z0-9_]*)")
    if ref == nil then
        return nil
    end
    ref = string.gsub(ref, "%s+", "")
    local model_name, object_name = string.match(ref, "^([^.]+)%.([^.]+)$")
    return model_name, object_name
end

local function parse_model_ref_from_command(sql_text)
    return string.match(sql_text, "[Mm][Oo][Dd][Ee][Ll]%s+([A-Za-z_][A-Za-z0-9_]*)")
end

function M.preprocess_sql(sql_text)
    local text = tostring(sql_text or "")
    local u = upper(trim(text))
    if string.match(u, "^ALTER%s+SEMANTIC%s+VIEW") then
        local ok, parse_result = pcall(function()
            return parse_definition(text)
        end)
        if not ok then
            local message = tostring(parse_result)
            return {
                status = "ERROR",
                error_code = string.match(message, "(SEMANTIC_DDL_%d+)") or "SEMANTIC_DDL_999",
                error_message = message,
            }
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION_OR_FAIL(" .. sql_string(text) .. ", FALSE)"}
    elseif string.match(u, "^SHOW%s+SEMANTIC%s+VIEW%s+") then
        local model_name, object_name = parse_object_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_067", error_message = "SHOW SEMANTIC VIEW requires model.object."}
        end
        return {status = "OK", generated_sql = "SELECT FIELD_KIND, FIELD_NAME, SQL_COLUMN_NAME, DATA_TYPE, DISPLAY_NAME, DESCRIPTION, IS_CERTIFIED, AGENT_READINESS FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE UPPER(MODEL_NAME) = UPPER(" .. sql_string(model_name) .. ") AND UPPER(OBJECT_NAME) = UPPER(" .. sql_string(object_name) .. ") ORDER BY FIELD_KIND, ORDINAL_POSITION, FIELD_NAME"}
    elseif string.match(u, "^SHOW%s+SEMANTIC%s+VIEWS") then
        return {status = "OK", generated_sql = "SELECT MODEL_NAME, OBJECT_NAME, ROOT_ENTITY_NAME, DESCRIPTION, STATUS FROM SEMANTIC_CATALOG.SEMANTIC_OBJECTS WHERE STATUS = 'ACTIVE' ORDER BY MODEL_NAME, OBJECT_NAME"}
    elseif string.match(u, "^SHOW%s+.*SEMANTIC%s+METRICS") then
        local generated = parse_show_metrics(text)
        if generated == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_060", error_message = "SHOW SEMANTIC METRICS requires IN model.object."}
        end
        return {status = "OK", generated_sql = generated}
    elseif string.match(u, "^SHOW%s+ALL%s+SEMANTIC%s+DIMENSIONS%s+FOR%s+METRIC") or string.match(u, "^SHOW%s+SEMANTIC%s+DIMENSIONS%s+FOR%s+METRIC") then
        local model_name, object_name, metric_name = parse_metric_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_061", error_message = "SHOW SEMANTIC DIMENSIONS FOR METRIC requires model.object.metric."}
        end
        local only_valid = not string.match(u, "^SHOW%s+ALL%s+")
        local valid_filter = only_valid and " AND IS_VALID = TRUE" or ""
        return {status = "OK", generated_sql = "SELECT mcd.DIMENSION_NAME, mcd.DISPLAY_NAME, mcd.ENTITY_NAME, mcd.IS_VALID, mcd.REASON_CODE, mcd.REASON_MESSAGE, mcd.JOIN_PATH_NAME FROM SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS mcd WHERE UPPER(mcd.MODEL_NAME) = UPPER(" .. sql_string(model_name) .. ") AND UPPER(mcd.OBJECT_NAME) = UPPER(" .. sql_string(object_name) .. ") AND UPPER(mcd.METRIC_NAME) = UPPER(" .. sql_string(metric_name) .. ")" .. valid_filter .. " AND EXISTS (SELECT 1 FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT af WHERE af.FIELD_KIND = 'METRIC' AND af.MODEL_NAME = mcd.MODEL_NAME AND af.OBJECT_NAME = mcd.OBJECT_NAME AND af.FIELD_ID = mcd.METRIC_ID) AND EXISTS (SELECT 1 FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT df WHERE df.FIELD_KIND = 'DIMENSION' AND df.MODEL_NAME = mcd.MODEL_NAME AND df.OBJECT_NAME = mcd.OBJECT_NAME AND df.FIELD_ID = mcd.DIMENSION_ID) ORDER BY mcd.IS_VALID DESC, mcd.DIMENSION_NAME"}
    elseif string.match(u, "^DESCRIBE%s+SEMANTIC%s+METRIC") then
        local model_name, object_name, metric_name = parse_metric_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_062", error_message = "DESCRIBE SEMANTIC METRIC requires model.object.metric."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_METRIC(" .. sql_string(model_name) .. ", " .. sql_string(object_name) .. ", " .. sql_string(metric_name) .. ")"}
    elseif string.match(u, "^EXPLAIN%s+SEMANTIC%s+METRIC") then
        local model_name, object_name, metric_name = parse_metric_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_063", error_message = "EXPLAIN SEMANTIC METRIC requires model.object.metric."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_SEMANTIC_METRIC(" .. sql_string(model_name) .. ", " .. sql_string(object_name) .. ", " .. sql_string(metric_name) .. ")"}
    elseif string.match(u, "^EXPORT%s+SEMANTIC%s+METRIC") then
        local model_name, object_name, metric_name = parse_metric_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_064", error_message = "EXPORT SEMANTIC METRIC requires model.object.metric."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION(" .. sql_string(model_name) .. ", " .. sql_string(object_name) .. ", " .. sql_string(metric_name) .. ")"}
    elseif string.match(u, "^EXPORT%s+SEMANTIC%s+VIEW") then
        local model_name, object_name = parse_object_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_065", error_message = "EXPORT SEMANTIC VIEW requires model.object."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION(" .. sql_string(model_name) .. ", " .. sql_string(object_name) .. ", NULL)"}
    elseif string.match(u, "^EXPORT%s+SEMANTIC%s+MODEL") then
        local model_name = parse_model_ref_from_command(text)
        if model_name == nil then
            return {status = "ERROR", error_code = "SEMANTIC_DDL_066", error_message = "EXPORT SEMANTIC MODEL requires a model name."}
        end
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION(" .. sql_string(model_name) .. ", NULL, NULL)"}
    elseif string.match(u, "^EXPLAIN%s+SEMANTIC%s+QUERY") then
        local query_text = trim(string.sub(text, string.find(u, "QUERY") + 5))
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL_DEBUG(" .. sql_string(query_text) .. ", 'EXPLAIN_SEMANTIC_QUERY')"}
    end
    return {status = "UNCHANGED", generated_sql = sql_text}
end

-- =====================================================================
-- Databricks Unity Catalog Metric View (UCMV) import
--
-- Translates a Databricks metric-view YAML definition into the native
-- semantic DDL of this project (positional ADD_* scaffolding + an ALTER SEMANTIC VIEW
-- block for facts and metrics) and, optionally, applies it. The translation
-- is database-native (pure Lua). Only file I/O lives host-side.
--
-- See docs/databricks-metric-views.md for the supported subset and the
-- DBX_IMPORT_* diagnostics emitted for anything outside it.
-- =====================================================================

-- ---- Minimal YAML-subset parser (only the constructs UCMV emits) ----

local function dbx_split_lines(text)
    local lines = {}
    for line in string.gmatch(tostring(text) .. "\n", "([^\n]*)\n") do
        local normalized_line = string.gsub(line, "\r$", "")
        lines[#lines + 1] = normalized_line
    end
    return lines
end

local function dbx_indent(line)
    local spaces = string.match(line, "^( *)%S")
    if spaces == nil then
        return nil
    end
    return #spaces
end

-- Strip a YAML line comment (hash preceded by whitespace or line start),
-- honoring single and double quoted scalars so a hash inside a value survives.
local function dbx_strip_comment(s)
    local out = {}
    local in_single = false
    local in_double = false
    local i = 1
    while i <= #s do
        local c = string.sub(s, i, i)
        if c == "'" and not in_double then
            in_single = not in_single
        elseif c == '"' and not in_single then
            in_double = not in_double
        elseif c == "#" and not in_single and not in_double then
            local prev = i > 1 and string.sub(s, i - 1, i - 1) or " "
            if prev == " " or prev == "\t" then
                break
            end
        end
        out[#out + 1] = c
        i = i + 1
    end
    return table.concat(out)
end

local function dbx_unquote(s)
    s = trim(s)
    if #s >= 2 and string.sub(s, 1, 1) == '"' and string.sub(s, -1) == '"' then
        return (string.gsub(string.sub(s, 2, -2), '\\"', '"'))
    elseif #s >= 2 and string.sub(s, 1, 1) == "'" and string.sub(s, -1) == "'" then
        return (string.gsub(string.sub(s, 2, -2), "''", "'"))
    end
    return s
end

local function dbx_scalar(s)
    s = trim(s)
    if s == "" or s == "~" or s == "null" then
        return nil
    end
    if string.sub(s, 1, 1) == "[" and string.sub(s, -1) == "]" then
        local arr = {}
        for item in string.gmatch(string.sub(s, 2, -2), "[^,]+") do
            local v = dbx_unquote(trim(item))
            if v ~= "" then
                arr[#arr + 1] = v
            end
        end
        return arr
    end
    return dbx_unquote(s)
end

local function dbx_next_meaningful(cur)
    while cur.pos <= #cur.lines do
        local stripped = dbx_strip_comment(cur.lines[cur.pos])
        if dbx_indent(stripped) ~= nil then
            return cur.pos, stripped
        end
        cur.pos = cur.pos + 1
    end
    return nil, nil
end

local dbx_parse_mapping
local dbx_parse_sequence

-- Literal/folded block scalar: consume lines more indented than the key.
local function dbx_parse_block_scalar(cur, parent_indent, indicator)
    local collected = {}
    local base = nil
    while cur.pos <= #cur.lines do
        local raw = cur.lines[cur.pos]
        local ind = dbx_indent(raw)
        if ind == nil then
            collected[#collected + 1] = ""
            cur.pos = cur.pos + 1
        elseif ind > parent_indent then
            base = base or ind
            collected[#collected + 1] = string.sub(raw, base + 1)
            cur.pos = cur.pos + 1
        else
            break
        end
    end
    while #collected > 0 and collected[#collected] == "" do
        table.remove(collected, #collected)
    end
    if indicator == ">" or indicator == ">-" then
        return trim(table.concat(collected, " "))
    end
    return table.concat(collected, "\n")
end

local function dbx_parse_block_child(cur, parent_indent)
    local idx, line = dbx_next_meaningful(cur)
    if idx == nil then
        return nil
    end
    local li = dbx_indent(line)
    if li <= parent_indent then
        return nil
    end
    local content = trim(line)
    if string.sub(content, 1, 2) == "- " or content == "-" then
        return dbx_parse_sequence(cur, li)
    end
    return dbx_parse_mapping(cur, li)
end

local function dbx_assign(map, content, cur, item_indent)
    local k, rest = string.match(content, "^([^:]+):%s?(.*)$")
    if k == nil then
        error("DBX_IMPORT_004: invalid YAML mapping line: " .. content)
    end
    k = trim(k)
    rest = trim(rest)
    if rest == "" then
        map[k] = dbx_parse_block_child(cur, item_indent)
    elseif rest == "|" or rest == "|-" or rest == "|+" or rest == ">" or rest == ">-" then
        map[k] = dbx_parse_block_scalar(cur, item_indent, rest)
    else
        map[k] = dbx_scalar(rest)
    end
end

function dbx_parse_mapping(cur, indent)
    local map = {}
    while true do
        local idx, line = dbx_next_meaningful(cur)
        if idx == nil then
            break
        end
        local li = dbx_indent(line)
        if li < indent then
            break
        end
        if li > indent then
            error("DBX_IMPORT_002: unexpected indentation in YAML mapping")
        end
        local content = trim(line)
        if string.sub(content, 1, 2) == "- " or content == "-" then
            break
        end
        cur.pos = idx + 1
        dbx_assign(map, content, cur, indent)
    end
    return map
end

function dbx_parse_sequence(cur, indent)
    local arr = {}
    while true do
        local idx, line = dbx_next_meaningful(cur)
        if idx == nil then
            break
        end
        local li = dbx_indent(line)
        if li < indent then
            break
        end
        if li > indent then
            error("DBX_IMPORT_005: unexpected indentation in YAML sequence")
        end
        local content = trim(line)
        if string.sub(content, 1, 2) ~= "- " and content ~= "-" then
            break
        end
        local after = (content == "-") and "" or trim(string.sub(content, 3))
        cur.pos = idx + 1
        if after == "" then
            arr[#arr + 1] = dbx_parse_block_child(cur, li)
        elseif string.match(after, "^([^:]+):") then
            local item_indent = li + (#content - #after)
            local item = {}
            dbx_assign(item, after, cur, item_indent)
            local rest_map = dbx_parse_mapping(cur, item_indent)
            for mk, mv in pairs(rest_map) do
                if item[mk] == nil then
                    item[mk] = mv
                end
            end
            arr[#arr + 1] = item
        else
            arr[#arr + 1] = dbx_scalar(after)
        end
    end
    return arr
end

local function parse_databricks_yaml(yaml_text)
    if missing(yaml_text) then
        error("DBX_IMPORT_001: empty Databricks YAML payload")
    end
    local cur = {lines = dbx_split_lines(yaml_text), pos = 1}
    local idx, line = dbx_next_meaningful(cur)
    if idx == nil then
        error("DBX_IMPORT_001: empty Databricks YAML payload")
    end
    return dbx_parse_mapping(cur, dbx_indent(line))
end

-- ---- Identifier / alias helpers ----

local function dbx_ident(name)
    local s = string.lower(trim(tostring(name or "")))
    s = string.gsub(s, "[^a-z0-9_]", "_")
    s = string.gsub(s, "_+", "_")
    s = string.gsub(s, "^_", "")
    s = string.gsub(s, "_$", "")
    if s == "" then
        s = "field"
    end
    if string.match(s, "^%d") then
        s = "f_" .. s
    end
    return s
end

local function dbx_unique(seen, base)
    local name = base
    local n = 2
    while seen[name] do
        name = base .. "_" .. n
        n = n + 1
    end
    seen[name] = true
    return name
end

local function dbx_alias(name, seen)
    local initials = {}
    for w in string.gmatch(dbx_ident(name), "[^_]+") do
        initials[#initials + 1] = string.sub(w, 1, 1)
    end
    local a = table.concat(initials)
    if a == "" then
        a = "t"
    end
    local base = a
    local n = 2
    while seen[a] do
        a = base .. n
        n = n + 1
    end
    seen[a] = true
    return a
end

local function dbx_table_ref(source)
    local s = trim(tostring(source or ""))
    if s == "" or string.match(upper(s), "^%s*SELECT") or string.find(s, "%s") then
        return nil, nil, false
    end
    local segs = {}
    for seg in string.gmatch(s, "[^.]+") do
        segs[#segs + 1] = trim(seg)
    end
    if #segs >= 2 then
        return upper(segs[#segs - 1]), upper(segs[#segs]), true
    elseif #segs == 1 then
        return nil, upper(segs[1]), true
    end
    return nil, nil, false
end

-- ---- Expression rewriter: qualify Databricks column refs with entity aliases ----

local DBX_SQL_WORDS = {
    SUM = true, COUNT = true, AVG = true, MIN = true, MAX = true, MEDIAN = true,
    STDDEV = true, VARIANCE = true, PERCENTILE = true, APPROX_COUNT_DISTINCT = true,
    NULLIF = true, COALESCE = true, CAST = true, CASE = true, WHEN = true,
    THEN = true, ELSE = true, END = true, DISTINCT = true, AS = true, AND = true,
    OR = true, NOT = true, IN = true, LIKE = true, BETWEEN = true, IS = true,
    NULL = true, TRUE = true, FALSE = true, DATE = true, TIMESTAMP = true,
    INTERVAL = true, EXTRACT = true, FROM = true, FILTER = true, WHERE = true,
    OVER = true, PARTITION = true, BY = true, ORDER = true, ASC = true, DESC = true,
    YEAR = true, MONTH = true, DAY = true, QUARTER = true, WEEK = true, HOUR = true,
    MINUTE = true, SECOND = true, MEASURE = true, AGG = true, ON = true, USING = true,
}

-- alias_paths: lowercased dotted path -> entity alias (e.g. "source"->"o",
-- "customer"->"c", "customer.nation"->"n"). default_alias qualifies bare columns.
-- dimension_lookup (optional): uppercased qualified-expr -> semantic dimension
-- name. When present, a resolved column that matches is emitted as the
-- dimension name (used for FILTER predicates).
local function dbx_rewrite_expr(expr, alias_paths, default_alias, dimension_lookup, diags, path)
    local tokens = tokenize(tostring(expr or ""))
    local parts = {}
    local attach_next = false
    local function emit(text, tight)
        if #parts == 0 then
            parts[1] = text
        elseif tight then
            parts[#parts] = parts[#parts] .. text
        else
            parts[#parts + 1] = text
        end
    end
    local function emit_resolved(qualified, tight)
        if dimension_lookup ~= nil and dimension_lookup[upper(qualified)] ~= nil then
            emit(dimension_lookup[upper(qualified)], tight)
        else
            emit(qualified, tight)
        end
    end
    local i = 1
    while i <= #tokens do
        local tok = tokens[i]
        local is_word = tok.kind == "word" or tok.kind == "identifier"
        if is_word and tokens[i + 1] ~= nil and tokens[i + 1].text == "." then
            -- Dotted reference: gather the full a.b.c chain.
            local chain = {tok}
            local j = i + 1
            while tokens[j] ~= nil and tokens[j].text == "." and (tokens[j + 1] ~= nil)
                and (tokens[j + 1].kind == "word" or tokens[j + 1].kind == "identifier") do
                chain[#chain + 1] = tokens[j + 1]
                j = j + 2
            end
            local segs = {}
            for _, c in ipairs(chain) do
                segs[#segs + 1] = c.value or c.text
            end
            local alias = nil
            local column = nil
            for k = #segs - 1, 1, -1 do
                local prefix = {}
                for p = 1, k do
                    prefix[p] = string.lower(segs[p])
                end
                local mapped = alias_paths[table.concat(prefix, ".")]
                if mapped ~= nil then
                    alias = mapped
                    local rest = {}
                    for p = k + 1, #segs do
                        rest[#rest + 1] = segs[p]
                    end
                    column = table.concat(rest, ".")
                    break
                end
            end
            if alias == nil and string.lower(segs[1]) == "source" then
                alias = default_alias
                local rest = {}
                for p = 2, #segs do
                    rest[#rest + 1] = segs[p]
                end
                column = table.concat(rest, ".")
            end
            if alias == nil then
                if diags ~= nil then
                    diags[#diags + 1] = {code = "DBX_IMPORT_310", severity = "WARNING", path = path,
                        message = "Unresolved qualified reference '" .. table.concat(segs, ".") .. "'; emitted verbatim."}
                end
                emit(table.concat(segs, "."), attach_next)
            else
                emit_resolved(alias .. "." .. column, attach_next)
            end
            attach_next = false
            i = j
        elseif is_word then
            local word = tok.value or tok.text
            local is_func = tokens[i + 1] ~= nil and tokens[i + 1].text == "("
            local prev = tokens[i - 1]
            local after_dot = prev ~= nil and prev.text == "."
            if is_func or after_dot or DBX_SQL_WORDS[upper(word)] then
                emit(tok.text, attach_next)
            else
                emit_resolved(default_alias .. "." .. word, attach_next)
            end
            attach_next = false
            i = i + 1
        elseif tok.text == "." then
            emit(".", true)
            attach_next = true
            i = i + 1
        elseif tok.text == "(" or tok.text == ")" or tok.text == "," then
            emit(tok.text, true)
            attach_next = (tok.text == "(")
            i = i + 1
        else
            emit(tok.text, attach_next)
            attach_next = false
            i = i + 1
        end
    end
    return trim(table.concat(parts, " "))
end

-- ---- Measure expression classification ----

-- Split "<agg> FILTER (WHERE <pred>)" into the aggregate expression and the
-- raw predicate (or nil). Returns agg_expr, filter_pred.
local function dbx_split_filter(expr)
    local tokens = tokenize(expr)
    for i, tok in ipairs(tokens) do
        if (tok.upper == "FILTER") and tokens[i + 1] ~= nil and tokens[i + 1].text == "(" then
            local close = nil
            local depth = 0
            for j = i + 1, #tokens do
                if tokens[j].text == "(" then
                    depth = depth + 1
                elseif tokens[j].text == ")" then
                    depth = depth - 1
                    if depth == 0 then
                        close = j
                        break
                    end
                end
            end
            if close ~= nil then
                local agg_expr = trim(string.sub(expr, 1, tokens[i].start_pos - 1))
                -- inside parens: WHERE <pred>
                local inner = trim(string.sub(expr, tokens[i + 1].end_pos + 1, tokens[close].start_pos - 1))
                inner = string.gsub(inner, "^[Ww][Hh][Ee][Rr][Ee]%s+", "")
                return agg_expr, trim(inner)
            end
        end
    end
    return expr, nil
end

-- Detect a leading aggregate call: returns AGG_FUNC, inner_text, has_distinct.
local function dbx_aggregate(expr)
    local tokens = tokenize(expr)
    if #tokens < 3 or tokens[1].kind ~= "word" or tokens[2].text ~= "(" then
        return nil, nil, false
    end
    local depth = 0
    for i = 2, #tokens do
        if tokens[i].text == "(" then
            depth = depth + 1
        elseif tokens[i].text == ")" then
            depth = depth - 1
            if depth == 0 then
                -- The aggregate must wrap the whole expression.
                if i ~= #tokens then
                    return nil, nil, false
                end
                local inner = trim(string.sub(expr, tokens[2].end_pos + 1, tokens[i].start_pos - 1))
                local has_distinct = false
                if string.match(upper(inner), "^DISTINCT%s") then
                    has_distinct = true
                    inner = trim(string.sub(inner, 9))
                end
                return upper(tokens[1].text), inner, has_distinct
            end
        end
    end
    return nil, nil, false
end

-- Replace MEASURE(x)/agg(x) wrappers with the bare referenced name.
local function dbx_unwrap_measures(expr)
    local result = expr
    result = string.gsub(result, "[Mm][Ee][Aa][Ss][Uu][Rr][Ee]%s*%(%s*([%w_]+)%s*%)", "%1")
    result = string.gsub(result, "%f[%a][Aa][Gg][Gg]%s*%(%s*([%w_]+)%s*%)", "%1")
    return result
end

local function dbx_references_measure(expr)
    return string.match(expr, "[Mm][Ee][Aa][Ss][Uu][Rr][Ee]%s*%(") ~= nil
        or string.match(expr, "%f[%a][Aa][Gg][Gg]%s*%(") ~= nil
end

-- =====================================================================
-- Translation: parsed UCMV document -> internal plan
-- =====================================================================

local function dbx_quote_ddl(value)
    if missing(value) then
        return "NULL"
    end
    return "'" .. string.gsub(tostring(value), "'", "''") .. "'"
end

local function dbx_translate(doc, model_name, published_schema, diags)
    if type(doc) ~= "table" then
        error("DBX_IMPORT_006: Databricks metric view must be a YAML mapping")
    end
    if missing(doc.source) then
        error("DBX_IMPORT_010: metric view is missing the required 'source' key")
    end

    local model = dbx_ident(model_name)
    local object_name = upper(model)
    local plan = {
        model_name = model,
        object_name = object_name,
        published_schema = upper(published_schema),
        description = doc.comment,
        entities = {},
        relationships = {},
        dimensions = {},
        facts = {},
        metrics = {},
    }

    local entity_seen = {}
    local alias_seen = {}
    local rel_seen = {}
    local member_seen = {}
    local fact_seen = {}

    -- alias_paths maps a dotted YAML reference path to the entity alias.
    local alias_paths = {}
    -- entity_by_path maps a dotted path to the entity name (for member binding).
    local entity_by_path = {}
    -- entity_alias maps an entity name to its source alias.
    local entity_alias = {}

    -- Root entity from `source`.
    local src_schema, src_object, ref_ok = dbx_table_ref(doc.source)
    if not ref_ok then
        error("DBX_IMPORT_210: source '" .. tostring(doc.source)
            .. "' is an inline query or unsupported reference; wrap it in a view and import that instead")
    end
    local root_name = dbx_unique(entity_seen, dbx_ident(src_object))
    local root_alias = dbx_alias(src_object, alias_seen)
    plan.entities[#plan.entities + 1] = {
        name = root_name, source_schema = src_schema, source_object = src_object,
        alias = root_alias, primary_key_expr = nil,
        grain = "Imported from Databricks metric view source",
        description = doc.comment,
    }
    alias_paths["source"] = root_alias
    alias_paths[string.lower(root_name)] = root_alias
    entity_by_path["source"] = root_name
    entity_alias[root_name] = root_alias

    -- Joins (recursively) -> entities + relationships.
    local function add_join(join, parent_entity, parent_path)
        if type(join) ~= "table" or missing(join.name) then
            diags[#diags + 1] = {code = "DBX_IMPORT_230", severity = "WARNING", path = "joins",
                message = "Skipped a join without a name."}
            return
        end
        local jschema, jobject, jok = dbx_table_ref(join.source)
        if not jok then
            diags[#diags + 1] = {code = "DBX_IMPORT_211", severity = "WARNING", path = "joins." .. tostring(join.name),
                message = "Join source '" .. tostring(join.source) .. "' is not a plain table reference; join skipped."}
            return
        end
        local jname = dbx_unique(entity_seen, dbx_ident(join.name))
        local jalias = dbx_alias(join.name, alias_seen)
        local jpath = parent_path .. "." .. string.lower(join.name)
        local relative_jpath = string.gsub(jpath, "^source%.", "")
        alias_paths[string.lower(join.name)] = jalias
        alias_paths[jpath] = jalias
        alias_paths[relative_jpath] = jalias
        entity_by_path[string.lower(join.name)] = jname
        entity_by_path[jpath] = jname
        entity_by_path[relative_jpath] = jname
        entity_alias[jname] = jalias
        local cardinality = "MANY_TO_ONE"
        if not missing(join.cardinality) and upper(join.cardinality) == "ONE_TO_MANY" then
            cardinality = "ONE_TO_MANY"
        end
        plan.entities[#plan.entities + 1] = {
            name = jname, source_schema = jschema, source_object = jobject,
            alias = jalias, primary_key_expr = nil,
            grain = "Imported join: " .. tostring(join.name), description = join.comment,
        }
        local parent_alias = entity_alias[parent_entity] or root_alias
        local join_condition = nil
        if not missing(join["on"]) then
            join_condition = dbx_rewrite_expr(join["on"], alias_paths, parent_alias, nil, diags, "joins." .. tostring(join.name))
        elseif not missing(join.using) then
            diags[#diags + 1] = {code = "DBX_IMPORT_240", severity = "WARNING", path = "joins." .. tostring(join.name),
                message = "USING joins are not supported; provide an ON condition. Join skipped."}
            return
        else
            diags[#diags + 1] = {code = "DBX_IMPORT_241", severity = "WARNING", path = "joins." .. tostring(join.name),
                message = "Join has no ON condition; skipped."}
            return
        end
        plan.relationships[#plan.relationships + 1] = {
            name = dbx_unique(rel_seen, dbx_ident(parent_entity .. "_to_" .. jname)),
            from_entity = parent_entity, to_entity = jname,
            join_condition = join_condition, cardinality = cardinality,
            join_type = "LEFT", fanout_policy = nil,
        }
        if cardinality == "ONE_TO_MANY" then
            diags[#diags + 1] = {code = "DBX_IMPORT_250", severity = "INFO", path = "joins." .. tostring(join.name),
                message = "one_to_many join mapped to ONE_TO_MANY relationship; verify fan-out handling."}
        end
        for _, child in ipairs(join.joins or {}) do
            add_join(child, jname, jpath)
        end
    end
    for _, join in ipairs(doc.joins or {}) do
        add_join(join, root_name, "source")
    end

    -- Resolve which entity an expression primarily references (for member binding).
    local function entity_for_expr(expr)
        local tokens = tokenize(tostring(expr or ""))
        local best_entity = nil
        local best_depth = 0
        for i = 1, #tokens - 1 do
            local tok = tokens[i]
            if (tok.kind == "word" or tok.kind == "identifier") and tokens[i + 1].text == "." then
                local segs = {string.lower(tok.value or tok.text)}
                local j = i + 1
                while tokens[j] ~= nil and tokens[j].text == "." and tokens[j + 1] ~= nil
                    and (tokens[j + 1].kind == "word" or tokens[j + 1].kind == "identifier") do
                    segs[#segs + 1] = string.lower(tokens[j + 1].value or tokens[j + 1].text)
                    j = j + 2
                end
                for depth = #segs - 1, 1, -1 do
                    local prefix = {}
                    for p = 1, depth do
                        prefix[p] = segs[p]
                    end
                    local path = table.concat(prefix, ".")
                    if path ~= "source" and entity_by_path[path] ~= nil and depth > best_depth then
                        best_entity = entity_by_path[path]
                        best_depth = depth
                        break
                    end
                end
            end
        end
        return best_entity or root_name
    end

    -- Fields -> dimensions. Also build a lookup from qualified expr -> dim name
    -- so FILTER predicates can reference dimensions by name.
    local dimension_lookup = {}
    for _, field in ipairs(doc.fields or {}) do
        if type(field) == "table" and not missing(field.name) and not missing(field.expr) then
            local dim_name = dbx_unique(member_seen, dbx_ident(field.name))
            local entity = entity_for_expr(field.expr)
            local expr = dbx_rewrite_expr(field.expr, alias_paths, root_alias, nil, diags, "fields." .. tostring(field.name))
            local data_type = "VARCHAR(2000000)"
            if string.match(upper(expr), "DATE_TRUNC") or string.match(upper(expr), "TRUNC%s*%(") then
                data_type = "DATE"
            end
            plan.dimensions[#plan.dimensions + 1] = {
                object = object_name, entity = entity, name = dim_name, expression = expr,
                data_type = data_type, display_name = field.display_name,
                description = field.comment, format_hint = nil, is_certified = false,
            }
            dimension_lookup[upper(expr)] = dim_name
        elseif type(field) == "table" and not missing(field.name) then
            diags[#diags + 1] = {code = "DBX_IMPORT_320", severity = "WARNING", path = "fields." .. tostring(field.name),
                message = "Field has no expr; skipped."}
        end
    end

    -- Measures -> facts + metrics.
    local base_metrics = {}
    local derived_metrics = {}
    for _, measure in ipairs(doc.measures or {}) do
        if type(measure) ~= "table" or missing(measure.name) or missing(measure.expr) then
            diags[#diags + 1] = {code = "DBX_IMPORT_400", severity = "WARNING", path = "measures",
                message = "Skipped a measure without name/expr."}
        elseif not missing(measure.window) then
            diags[#diags + 1] = {code = "DBX_IMPORT_410", severity = "WARNING", path = "measures." .. tostring(measure.name),
                message = "Window measures are not supported and were skipped."}
        else
            local metric_name = dbx_unique(member_seen, dbx_ident(measure.name))
            local agg_expr, filter_pred = dbx_split_filter(measure.expr)
            local format_hint = nil
            if type(measure.format) == "table" and not missing(measure.format.type) then
                local ft = string.lower(tostring(measure.format.type))
                if ft == "currency" then
                    format_hint = "currency"
                elseif ft == "percent" or ft == "percentage" then
                    format_hint = "percentage"
                elseif ft == "number" then
                    format_hint = "number"
                end
            end
            local common = {
                name = metric_name, entity = root_name, display_name = measure.display_name,
                description = measure.comment, format_hint = format_hint,
                synonyms = type(measure.synonyms) == "table" and measure.synonyms or nil,
                data_type = "DECIMAL(36,6)", filter_pred = nil, kind = "ADDITIVE",
            }
            if dbx_references_measure(agg_expr) then
                -- Derived / ratio metric over other measures.
                local unwrapped = dbx_unwrap_measures(agg_expr)
                local lhs, rhs = string.match(trim(unwrapped), "^([%w_]+)%s*/%s*([%w_]+)$")
                if lhs ~= nil then
                    common.expression = lhs .. " / NULLIF(" .. rhs .. ", 0)"
                    common.kind = "RATIO"
                else
                    common.expression = unwrapped
                    common.kind = "DERIVED"
                end
                if filter_pred ~= nil then
                    diags[#diags + 1] = {code = "DBX_IMPORT_430", severity = "WARNING", path = "measures." .. tostring(measure.name),
                        message = "FILTER on a composed measure is not supported and was dropped."}
                end
                derived_metrics[#derived_metrics + 1] = common
            else
                local agg_func, inner, has_distinct = dbx_aggregate(agg_expr)
                if agg_func == nil then
                    diags[#diags + 1] = {code = "DBX_IMPORT_420", severity = "WARNING", path = "measures." .. tostring(measure.name),
                        message = "Measure expression '" .. tostring(measure.expr) .. "' is not a recognized aggregate; skipped."}
                else
                    -- Build a private fact for the aggregate input.
                    local fact_inner
                    if inner == "*" or inner == "1" or inner == "" then
                        fact_inner = "1"
                        common.data_type = "DECIMAL(18,0)"
                    else
                        fact_inner = dbx_rewrite_expr(inner, alias_paths, root_alias, nil, diags, "measures." .. tostring(measure.name))
                    end
                    local fact_name = dbx_unique(fact_seen, dbx_ident(measure.name) .. "_base")
                    member_seen[fact_name] = true
                    local fact_type = (common.data_type == "DECIMAL(18,0)") and "DECIMAL(18,0)" or "DECIMAL(36,6)"
                    plan.facts[#plan.facts + 1] = {
                        name = fact_name, entity = root_name, expression = fact_inner,
                        data_type = fact_type, additive = "ADDITIVE",
                        display_name = nil, description = "Imported base for measure " .. tostring(measure.name),
                        is_private = true, is_certified = false,
                    }
                    if agg_func == "COUNT" then
                        common.data_type = "DECIMAL(18,0)"
                    end
                    if has_distinct then
                        common.expression = agg_func .. "(DISTINCT " .. fact_name .. ")"
                    else
                        common.expression = agg_func .. "(" .. fact_name .. ")"
                    end
                    if filter_pred ~= nil then
                        common.filter_pred = dbx_rewrite_expr(filter_pred, alias_paths, root_alias, dimension_lookup, diags, "measures." .. tostring(measure.name))
                    end
                    base_metrics[#base_metrics + 1] = common
                end
            end
        end
    end
    for _, m in ipairs(base_metrics) do
        plan.metrics[#plan.metrics + 1] = m
    end
    for _, m in ipairs(derived_metrics) do
        plan.metrics[#plan.metrics + 1] = m
    end

    if not missing(doc.filter) then
        diags[#diags + 1] = {code = "DBX_IMPORT_500", severity = "WARNING", path = "filter",
            message = "View-level filter is not applied automatically; add it to individual metrics if needed."}
    end
    if not missing(doc.materialization) then
        diags[#diags + 1] = {code = "DBX_IMPORT_510", severity = "INFO", path = "materialization",
            message = "Databricks materialization config ignored; use this project's materialization selection."}
    end
    if #plan.metrics == 0 then
        diags[#diags + 1] = {code = "DBX_IMPORT_420", severity = "WARNING", path = "measures",
            message = "No metrics were produced from the metric view measures."}
    end

    return plan
end

-- ---- Render native DDL text for the plan (reviewable / re-runnable) ----

local function dbx_render_member_clauses(buf, m, is_fact)
    if is_fact then
        buf[#buf + 1] = "    ON ENTITY " .. m.entity
        buf[#buf + 1] = "    AS " .. m.expression
        buf[#buf + 1] = "    RETURNS " .. m.data_type
        buf[#buf + 1] = "    " .. m.additive
    else
        buf[#buf + 1] = "    AS " .. m.expression
        buf[#buf + 1] = "    ON ENTITY " .. m.entity
        if m.filter_pred ~= nil then
            buf[#buf + 1] = "    FILTER (WHERE " .. m.filter_pred .. ")"
        end
        buf[#buf + 1] = "    RETURNS " .. m.data_type
        if not missing(m.format_hint) then
            buf[#buf + 1] = "    FORMAT " .. dbx_quote_ddl(m.format_hint)
        end
    end
    if not missing(m.display_name) then
        buf[#buf + 1] = "    DISPLAY " .. dbx_quote_ddl(m.display_name)
    end
    if not missing(m.description) then
        buf[#buf + 1] = "    COMMENT " .. dbx_quote_ddl(m.description)
    end
    if not is_fact and type(m.synonyms) == "table" and #m.synonyms > 0 then
        local quoted = {}
        for _, s in ipairs(m.synonyms) do
            quoted[#quoted + 1] = dbx_quote_ddl(s)
        end
        buf[#buf + 1] = "    SYNONYMS (" .. table.concat(quoted, ", ") .. ")"
    end
    if not is_fact then
        buf[#buf + 1] = "    " .. m.kind
    end
    if is_fact then
        buf[#buf + 1] = "    PRIVATE"
    else
        buf[#buf + 1] = "    PUBLIC"
    end
end

local function dbx_alter_semantic_view(plan)
    if #plan.facts == 0 and #plan.metrics == 0 then
        return nil
    end
    local buf = {}
    buf[#buf + 1] = "ALTER SEMANTIC VIEW " .. plan.model_name .. "." .. plan.object_name
    if #plan.facts > 0 then
        buf[#buf + 1] = "REPLACE FACTS ("
        local entries = {}
        for _, f in ipairs(plan.facts) do
            local e = {"  FACT " .. f.name}
            dbx_render_member_clauses(e, f, true)
            entries[#entries + 1] = table.concat(e, "\n")
        end
        buf[#buf + 1] = table.concat(entries, ",\n\n")
        buf[#buf + 1] = ")"
    end
    if #plan.metrics > 0 then
        buf[#buf + 1] = "REPLACE METRICS ("
        local entries = {}
        for _, m in ipairs(plan.metrics) do
            local e = {"  METRIC " .. m.name}
            dbx_render_member_clauses(e, m, false)
            entries[#entries + 1] = table.concat(e, "\n")
        end
        buf[#buf + 1] = table.concat(entries, ",\n\n")
        buf[#buf + 1] = ")"
    end
    return table.concat(buf, "\n")
end

local function dbx_render_ddl(plan)
    local out = {}
    out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(" .. dbx_quote_ddl(plan.model_name)
        .. ", " .. dbx_quote_ddl(plan.published_schema) .. ", " .. dbx_quote_ddl(plan.description) .. ", NULL);"
    for _, e in ipairs(plan.entities) do
        out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(" .. dbx_quote_ddl(plan.model_name)
            .. ", " .. dbx_quote_ddl(e.name) .. ", " .. dbx_quote_ddl(e.source_schema)
            .. ", " .. dbx_quote_ddl(e.source_object) .. ", " .. dbx_quote_ddl(e.alias)
            .. ", " .. dbx_quote_ddl(e.primary_key_expr) .. ", " .. dbx_quote_ddl(e.grain)
            .. ", " .. dbx_quote_ddl(e.description) .. ");"
    end
    out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(" .. dbx_quote_ddl(plan.model_name)
        .. ", " .. dbx_quote_ddl(plan.object_name) .. ", " .. dbx_quote_ddl(plan.entities[1].name)
        .. ", " .. dbx_quote_ddl(plan.description) .. ");"
    for _, r in ipairs(plan.relationships) do
        out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(" .. dbx_quote_ddl(plan.model_name)
            .. ", " .. dbx_quote_ddl(r.name) .. ", " .. dbx_quote_ddl(r.from_entity)
            .. ", " .. dbx_quote_ddl(r.to_entity) .. ", " .. dbx_quote_ddl(r.join_condition)
            .. ", " .. dbx_quote_ddl(r.cardinality) .. ", " .. dbx_quote_ddl(r.join_type)
            .. ", " .. dbx_quote_ddl(r.fanout_policy) .. ");"
    end
    for _, d in ipairs(plan.dimensions) do
        out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(" .. dbx_quote_ddl(plan.model_name)
            .. ", " .. dbx_quote_ddl(d.object) .. ", " .. dbx_quote_ddl(d.entity)
            .. ", " .. dbx_quote_ddl(d.name) .. ", " .. dbx_quote_ddl(d.expression)
            .. ", " .. dbx_quote_ddl(d.data_type) .. ", " .. dbx_quote_ddl(d.display_name)
            .. ", " .. dbx_quote_ddl(d.description) .. ", " .. dbx_quote_ddl(d.format_hint)
            .. ", " .. (d.is_certified and "TRUE" or "FALSE") .. ");"
    end
    local alter = dbx_alter_semantic_view(plan)
    if alter ~= nil then
        out[#out + 1] = "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(\n"
            .. dbx_quote_ddl(alter) .. ",\n  FALSE);"
    end
    return table.concat(out, "\n\n")
end

-- ---- Apply the plan against the catalog ----

local function dbx_apply_plan(plan)
    if not missing(scalar("SELECT MAX(MODEL_ID) FROM SYS_SEMANTIC.MODELS WHERE UPPER(MODEL_NAME) = UPPER(:name)",
        {name = plan.model_name})) then
        error("DBX_IMPORT_200: model '" .. plan.model_name .. "' already exists; choose a different model name or reset it first")
    end
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(:model_name, :published_schema, :description, NULL)",
        {model_name = plan.model_name, published_schema = plan.published_schema, description = null_if_missing(plan.description)})
    for _, e in ipairs(plan.entities) do
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(:model_name, :entity_name, :source_schema, :source_object, :source_alias, :primary_key_expr, :grain_description, :description)",
            {model_name = plan.model_name, entity_name = e.name, source_schema = e.source_schema,
             source_object = e.source_object, source_alias = e.alias,
             primary_key_expr = null_if_missing(e.primary_key_expr),
             grain_description = null_if_missing(e.grain), description = null_if_missing(e.description)})
    end
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(:model_name, :object_name, :root_entity_name, :description)",
        {model_name = plan.model_name, object_name = plan.object_name, root_entity_name = plan.entities[1].name,
         description = null_if_missing(plan.description)})
    for _, r in ipairs(plan.relationships) do
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(:model_name, :relationship_name, :from_entity_name, :to_entity_name, :join_condition, :cardinality, :join_type, :fanout_policy)",
            {model_name = plan.model_name, relationship_name = r.name, from_entity_name = r.from_entity,
             to_entity_name = r.to_entity, join_condition = r.join_condition, cardinality = r.cardinality,
             join_type = r.join_type, fanout_policy = null_if_missing(r.fanout_policy)})
    end
    for _, d in ipairs(plan.dimensions) do
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(:model_name, :object_name, :entity_name, :dimension_name, :expression, :data_type, :display_name, :description, :format_hint, :is_certified)",
            {model_name = plan.model_name, object_name = d.object, entity_name = d.entity, dimension_name = d.name,
             expression = d.expression, data_type = d.data_type, display_name = null_if_missing(d.display_name),
             description = null_if_missing(d.description), format_hint = null_if_missing(d.format_hint),
             is_certified = d.is_certified})
    end
    local validation_run_id = nil
    local alter = dbx_alter_semantic_view(plan)
    if alter ~= nil then
        local rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(:ddl, FALSE)", {ddl = alter})
        local first = rows and rows[1] or nil
        local status = first and row_value(first, "STATUS", 1) or "OK"
        validation_run_id = first and row_value(first, "VALIDATION_RUN_ID", 6) or nil
        if status == "ERROR" then
            error((first and row_value(first, "ERROR_CODE", 2) or "DBX_IMPORT_600") .. ": "
                .. tostring(first and row_value(first, "MESSAGE", 3) or "fact/metric definition rejected"))
        end
    else
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = plan.model_name})
        validation_run_id = scalar([[
            SELECT MAX(vr.VALIDATION_RUN_ID)
            FROM SYS_SEMANTIC.VALIDATION_RUNS vr
            JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = vr.MODEL_ID
            WHERE UPPER(m.MODEL_NAME) = UPPER(:name)
        ]], {name = plan.model_name})
    end
    -- Validation passed (APPLY_SEMANTIC_DEFINITION raises on validation errors),
    -- so publish the model immediately, matching Databricks where a metric view
    -- is queryable as soon as it is created.
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL(:model_name)", {model_name = plan.model_name})
    return validation_run_id
end

function M.import_databricks_metric_view(yaml_text, model_name, published_schema, apply_flag)
    local diags = {}
    local ok, result = pcall(function()
        if missing(model_name) then
            error("DBX_IMPORT_020: a target model name is required")
        end
        local doc = parse_databricks_yaml(yaml_text)
        local schema = missing(published_schema) and ("SEMANTIC_" .. upper(dbx_ident(model_name))) or published_schema
        local plan = dbx_translate(doc, model_name, schema, diags)
        local ddl = dbx_render_ddl(plan)
        local validation_run_id = null
        if sql_bool(apply_flag) then
            validation_run_id = dbx_apply_plan(plan) or null
        end
        return {plan = plan, ddl = ddl, validation_run_id = validation_run_id}
    end)
    if ok then
        return {{
            "OK", null, "Databricks metric view translated" .. (sql_bool(apply_flag) and " and applied." or "."),
            result.plan.model_name, result.ddl, json_encode(diags), result.validation_run_id,
        }}
    end
    local message = tostring(result)
    local error_code = string.match(message, "(DBX_IMPORT_%d+)") or string.match(message, "(SEMANTIC_%w+_%d+)") or "DBX_IMPORT_999"
    return {{
        "ERROR", error_code, message, missing(model_name) and null or dbx_ident(model_name),
        null, json_encode(diags), null,
    }}
end

apply_semantic_definition = M.apply_semantic_definition
apply_normalized_osi_import = M.apply_normalized_osi_import
import_databricks_metric_view = M.import_databricks_metric_view
describe_semantic_metric = M.describe_semantic_metric
explain_semantic_metric = M.explain_semantic_metric
export_semantic_definition = M.export_semantic_definition
preprocess_sql = M.preprocess_sql

if rawget(_G, "ESV_TEST_MODE") then
    ESV_SEMANTIC_DEFINITION_TEST_API = {
        json_encode = json_encode,
        json_decode = json_decode,
        tokenize = tokenize,
        split_top_level_text = split_top_level_text,
        parse_literal_list = parse_literal_list,
        parse_filter = parse_filter,
        aggregate_parts = aggregate_parts,
        inline_ratio_parts = inline_ratio_parts,
        parse_definition = parse_definition,
        rewrite_identifier = rewrite_identifier,
        definition_operation_count = definition_operation_count,
        prepare_replacement_synonyms = prepare_replacement_synonyms,
        validation_error_message = validation_error_message,
        apply_definition_changes = apply_definition_changes,
        validate_definition_model = validate_definition_model,
        upsert_metric = upsert_metric,
        drop_metric = drop_metric,
        rename_metric = rename_metric,
        model_names_from_plan = model_names_from_plan,
        parse_databricks_yaml = parse_databricks_yaml,
        dbx_table_ref = dbx_table_ref,
        dbx_rewrite_expr = dbx_rewrite_expr,
        dbx_split_filter = dbx_split_filter,
        dbx_aggregate = dbx_aggregate,
        dbx_unwrap_measures = dbx_unwrap_measures,
        dbx_translate = dbx_translate,
        dbx_render_ddl = dbx_render_ddl,
    }
end
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  DEFINITION_SQL,
  DRY_RUN
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_semantic_definition(DEFINITION_SQL, DRY_RUN)

exit(rows or {}, [[
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

exit(rows or {}, [[
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

exit(rows or {}, [[
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

exit(rows or {}, [[
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

exit(rows or {}, [[
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

exit(rows or {}, [[
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

exit(rows or {}, [[
  DEFINITION_KIND VARCHAR(64),
  DEFINITION_REF VARCHAR(1024),
  DEFINITION_SQL VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()
RETURNS TABLE AS
query("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR")
exit({{"OK", "SESSION", "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR", "Semantic SQL enabled for this session."}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(512),
  MESSAGE VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()
RETURNS TABLE AS
query("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
exit({{"OK", "SESSION", null, "Semantic SQL disabled for this session."}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(512),
  MESSAGE VARCHAR(2000000)
]])
/
-- END GENERATED SEMANTIC_DEFINITION_RUNTIME
