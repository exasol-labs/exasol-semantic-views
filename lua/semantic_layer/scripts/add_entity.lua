--- Registers an entity over a source table or view and creates its PRIMARY representation; returns nothing.
-- @script SEMANTIC_ADMIN.ADD_ENTITY
-- @param MODEL_NAME
-- @param ENTITY_NAME New entity name (identifier: letter, then letters, digits, _); required, unique in the model.
-- @param SOURCE_SCHEMA Schema of the source relation; required identifier. A virtual schema makes the primary VIRTUAL_SCHEMA.
-- @param SOURCE_OBJECT Source table or view name; required identifier.
-- @param SOURCE_ALIAS Alias used in expressions; required identifier, unique in the model, not an Exasol reserved word.
-- @param PRIMARY_KEY_EXPR Optional primary-key expression stored as text; NULL leaves it unset.
-- @param GRAIN_DESCRIPTION Optional text describing one row of the entity; NULL leaves it unset.
-- @param DESCRIPTION Optional entity description; NULL leaves it unset.
-- @returns nothing

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
-- Derived, not declared: ADD_ENTITY takes no SOURCE_KIND, so the primary
-- representation of a federated entity used to be recorded as RELATION --
-- unrecordable truth in a model whose whole point is that the source is
-- federated. The catalog already knows, and the doc calls the distinction a
-- planning input, so a wrong label is a wrong plan input rather than a
-- cosmetic one.
local primary_source_kind = "RELATION"
if tonumber(scalar([[
    SELECT COUNT(*) FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS
    WHERE UPPER(SCHEMA_NAME) = UPPER(:source_schema)
]], {source_schema = source_schema}) or 0) > 0 then
    primary_source_kind = "VIRTUAL_SCHEMA"
end
query([[
    INSERT INTO SYS_SEMANTIC.ENTITY_REPRESENTATIONS (
      MODEL_ID, VERSION_ID, ENTITY_ID, REPRESENTATION_NAME, SOURCE_KIND,
      SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS, REPRESENTATION_ROLE,
      PRIORITY, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, 'primary', :source_kind,
      :source_schema, :source_object, :source_alias, 'PRIMARY', 1, 'ACTIVE'
    )
]], {source_kind = primary_source_kind,
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id,
    source_schema = source_schema,
    source_object = source_object,
    source_alias = source_alias,
})
