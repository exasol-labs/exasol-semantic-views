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

local validation_rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
local validation_error = validation_error_summary(validation_rows)
if validation_error ~= nil then
    if not was_update then
        query([[DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE OBJECT_ID = :object_id AND COLUMN_KIND = 'DIMENSION' AND OBJECT_REF_ID = :dimension_id]], {object_id = object_id_value, dimension_id = dimension_id})
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
local column_name = missing(COLUMN_NAME) and null or normalize_name(COLUMN_NAME, "COLUMN_NAME")
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
if dup_rows ~= nil and #dup_rows > 0 then
    return {{ model_name_actual, role_name, published_schema, 'ALREADY_GRANTED' }}
end

query([[
    INSERT INTO SYS_SEMANTIC.MODEL_ROLE_GRANTS (MODEL_ID, MODEL_NAME, ROLE_NAME, PUBLISHED_SCHEMA)
    VALUES (:model_id, :model_name, :role_name, :published_schema)
]], {model_id = model_id, model_name = model_name_actual, role_name = role_name, published_schema = published_schema})

if published_schema ~= nil and tostring(published_schema) ~= "" then
    query("GRANT SELECT ON SCHEMA " .. quote_ident(published_schema) .. " TO " .. quote_ident(role_name))
end

exit({{ model_name_actual, role_name, published_schema, 'GRANTED' }}, [[
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
local M = {}

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
    MAX = true,
    MIN = true,
    MONTH = true,
    NULLIF = true,
    ROUND = true,
    SUM = true,
    TO_CHAR = true,
    TO_DATE = true,
    YEAR = true,
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
          WHERE TABLE_SCHEMA = UPPER(:schema_name)
            AND TABLE_NAME = UPPER(:object_name)
          UNION ALL
          SELECT VIEW_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_VIEWS
          WHERE VIEW_SCHEMA = UPPER(:schema_name)
            AND VIEW_NAME = UPPER(:object_name)
        ) visible_objects
    ]], {schema_name = schema_name, object_name = object_name}) > 0
end

local function source_column_exists(schema_name, object_name, column_name)
    return count_query([[
        SELECT COUNT(*)
        FROM SYS.EXA_ALL_COLUMNS
        WHERE COLUMN_SCHEMA = UPPER(:schema_name)
          AND COLUMN_TABLE = UPPER(:object_name)
          AND COLUMN_NAME = UPPER(:column_name)
    ]], {schema_name = schema_name, object_name = object_name, column_name = column_name}) > 0
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
    local pos = 1
    while true do
        local start_pos, end_pos, alias = string.find(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.[%s]*[A-Za-z_][A-Za-z0-9_]*", pos)
        if start_pos == nil then
            break
        end
        local next_char = string.sub(text, end_pos + 1, end_pos + 1)
        if next_char ~= "(" then
            aliases[upper(alias)] = true
        end
        pos = end_pos + 1
    end
    return aliases
end

local function column_refs_in_expression(expression)
    local refs = {}
    if missing(expression) then
        return refs
    end
    local text = strip_string_literals(tostring(expression))
    for alias, column_name in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%.%s*([A-Za-z_][A-Za-z0-9_]*)") do
        local after = string.sub(text, string.find(text, alias .. "%s*%.%s*" .. column_name, 1) or 1)
        refs[#refs + 1] = {alias = upper(alias), column_name = upper(column_name)}
    end
    return refs
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
    local qualified = schema_qualified_functions(expression)
    for fn in string.gmatch(text, "([A-Za-z_][A-Za-z0-9_]*)%s*%(") do
        local normalized = upper(fn)
        local schema_qualified = false
        for qualified_name, _ in pairs(qualified) do
            if string.match(qualified_name, "%." .. normalized .. "$") then
                schema_qualified = true
                break
            end
        end
        if not schema_qualified and not ALLOWED_FUNCTIONS[normalized] then
            found[normalized] = true
        end
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
    ctx.entity_by_id = {}
    ctx.entity_alias_by_id = {}
    ctx.entity_name_by_id = {}
    ctx.entity_id_by_name = {}
    local entity_rows = query([[
        SELECT ENTITY_ID, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local id = row_value(row, "ENTITY_ID", 1)
        local entity = {
            id = id,
            name = row_value(row, "ENTITY_NAME", 2),
            source_schema = row_value(row, "SOURCE_SCHEMA", 3),
            source_object = row_value(row, "SOURCE_OBJECT", 4),
            alias = row_value(row, "SOURCE_ALIAS", 5),
        }
        table.insert(ctx.entities, entity)
        ctx.entity_by_id[key(id)] = entity
        ctx.entity_alias_by_id[key(id)] = upper(entity.alias)
        ctx.entity_name_by_id[key(id)] = tostring(entity.name)
        ctx.entity_id_by_name[upper(entity.name)] = id
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
        }
        table.insert(ctx.relationships, relationship)
        ctx.relationship_by_id[key(id)] = relationship
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

local function validate_structural_rules(ctx)
    for _, entity in ipairs(ctx.entities) do
        if not source_object_exists(entity.source_schema, entity.source_object) then
            add_issue(ctx, "ERROR", "ENTITY", entity.name, "SEMANTIC_MODEL_001",
                "Source object is not visible: " .. tostring(entity.source_schema) .. "." .. tostring(entity.source_object) .. ".")
        end
    end

    local duplicate_alias_rows = query([[
        SELECT UPPER(SOURCE_ALIAS) AS SOURCE_ALIAS, COUNT(*) AS ALIAS_COUNT
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        GROUP BY UPPER(SOURCE_ALIAS)
        HAVING COUNT(*) > 1
    ]], {model_id = ctx.model_id, version_id = ctx.version_id})
    for _, row in ipairs(duplicate_alias_rows or {}) do
        add_issue(ctx, "ERROR", "ENTITY", row_value(row, "SOURCE_ALIAS", 1), "SEMANTIC_MODEL_003",
            "Entity alias is not unique within the model version.")
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
        if ref.alias == owning_alias and not source_column_exists(entity.source_schema, entity.source_object, ref.column_name) then
            add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", object_name, "SEMANTIC_MODEL_029",
                "Unique key expression references unknown source column: " .. ref.alias .. "." .. ref.column_name .. ".")
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
                    if not source_column_exists(entity.source_schema, entity.source_object, column_name) then
                        add_issue(ctx, "ERROR", "UNIQUE_KEY_COLUMN", column_object_name, "SEMANTIC_MODEL_029",
                            "Unique key column references unknown source column: " .. tostring(column_name) .. ".")
                    end
                else
                    validate_unique_key_expression(ctx, unique_key, column, entity, owning_alias, column_object_name)
                end
            end
        end
    end
end

local function relationship_edges(ctx)
    local edges = {}
    local all_edges = {}
    local function add_edge(target, from_id, to_id, relationship, safe, reason)
        local from_key = key(from_id)
        target[from_key] = target[from_key] or {}
        table.insert(target[from_key], {
            to_id = to_id,
            name = relationship.name,
            safe = safe,
            reason = reason,
        })
    end

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

        if from_exists and to_exists and VALID_CARDINALITIES[cardinality] then
            if cardinality == "ONE_TO_ONE" then
                add_edge(edges, relationship.from_entity_id, relationship.to_entity_id, relationship, true, "OK")
                add_edge(edges, relationship.to_entity_id, relationship.from_entity_id, relationship, true, "OK")
            elseif cardinality == "MANY_TO_ONE" then
                add_edge(edges, relationship.from_entity_id, relationship.to_entity_id, relationship, true, "OK")
                add_edge(all_edges, relationship.to_entity_id, relationship.from_entity_id, relationship, false, "FANOUT_REQUIRES_POLICY")
            elseif cardinality == "ONE_TO_MANY" then
                add_edge(edges, relationship.to_entity_id, relationship.from_entity_id, relationship, true, "OK")
                add_edge(all_edges, relationship.from_entity_id, relationship.to_entity_id, relationship, false, "FANOUT_REQUIRES_POLICY")
            elseif cardinality == "MANY_TO_MANY" then
                local safe = not missing(relationship.fanout_policy)
                local reason = safe and "OK" or "MANY_TO_MANY_REQUIRES_FANOUT"
                if safe then
                    add_edge(edges, relationship.from_entity_id, relationship.to_entity_id, relationship, true, reason)
                    add_edge(edges, relationship.to_entity_id, relationship.from_entity_id, relationship, true, reason)
                end
                add_edge(all_edges, relationship.from_entity_id, relationship.to_entity_id, relationship, safe, reason)
                add_edge(all_edges, relationship.to_entity_id, relationship.from_entity_id, relationship, safe, reason)
            end

            if cardinality ~= "MANY_TO_MANY" then
                add_edge(all_edges, relationship.from_entity_id, relationship.to_entity_id, relationship, true, "OK")
                add_edge(all_edges, relationship.to_entity_id, relationship.from_entity_id, relationship, false, "FANOUT_REQUIRES_POLICY")
            end
        end
    end

    return edges, all_edges
end

local function find_path(edge_map, from_id, to_id, require_safe)
    if missing(from_id) or missing(to_id) then
        return false, "MISSING_ENTITY", nil
    end
    if key(from_id) == key(to_id) then
        return true, "OK", "SELF"
    end

    local queue = {{id = from_id, path = {}}}
    local seen = {[key(from_id)] = true}
    local first_blocked_reason = nil
    local index = 1
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        for _, edge in ipairs(edge_map[key(current.id)] or {}) do
            if require_safe and not edge.safe then
                first_blocked_reason = first_blocked_reason or edge.reason
            else
                local next_key = key(edge.to_id)
                if not seen[next_key] then
                    local next_path = {}
                    for _, name in ipairs(current.path) do
                        table.insert(next_path, name)
                    end
                    table.insert(next_path, edge.name)
                    if next_key == key(to_id) then
                        return true, "OK", table.concat(next_path, " > ")
                    end
                    seen[next_key] = true
                    table.insert(queue, {id = edge.to_id, path = next_path})
                end
            end
        end
    end
    return false, first_blocked_reason or "NO_RELATIONSHIP_PATH", nil
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
        if entity ~= nil then
            for _, ref in ipairs(column_refs_in_expression(dimension.expression)) do
                if ref.alias == owning_alias and not source_column_exists(entity.source_schema, entity.source_object, ref.column_name) then
                    add_issue(ctx, "ERROR", "DIMENSION", dimension.name, "SEMANTIC_MODEL_017",
                        "Dimension expression references unknown source column: " .. ref.alias .. "." .. ref.column_name .. ".")
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
        if entity ~= nil then
            for _, ref in ipairs(column_refs_in_expression(fact.expression)) do
                if ref.alias == owning_alias and not source_column_exists(entity.source_schema, entity.source_object, ref.column_name) then
                    add_issue(ctx, "ERROR", "FACT", fact.name, "SEMANTIC_MODEL_017",
                        "Fact expression references unknown source column: " .. ref.alias .. "." .. ref.column_name .. ".")
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
                if source_entity ~= nil and not source_column_exists(source_entity.source_schema, source_entity.source_object, ref.column_name) then
                    add_issue(ctx, "ERROR", "METRIC", metric.name, "SEMANTIC_MODEL_017",
                        "Metric filter references unknown source column: " .. ref.alias .. "." .. ref.column_name .. ".")
                end
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
            if ctx.metric_by_name[upper(metric_name)] == nil then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references unknown metric: " .. metric_name .. ".")
            end
        end
        for _, dimension_name in ipairs(extract_json_array_values(request_json, "dimensions")) do
            if ctx.dimension_by_name[upper(dimension_name)] == nil then
                add_issue(ctx, "ERROR", "VERIFIED_QUERY", query_name, "SEMANTIC_MODEL_023",
                    "Verified query references unknown dimension: " .. dimension_name .. ".")
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

-- Returns true if metric.base_entity_id is reachable via safe_edges from at least one
-- semantic object root entity. Mirrors the compiler join-resolution starting point.
local function metric_reachable_from_any_root(ctx, metric, safe_edges)
    if #ctx.semantic_objects == 0 then
        return true  -- no objects loaded, skip the check
    end
    for _, obj in ipairs(ctx.semantic_objects) do
        local ok, _, _ = find_path(safe_edges, obj.root_entity_id, metric.base_entity_id, true)
        if ok then
            return true
        end
    end
    return false
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
        local root_can_reach_metric = metric_reachable_from_any_root(ctx, metric, safe_edges)
        for _, dimension in ipairs(ctx.dimensions) do
            local is_valid = false
            local reason_code = "OK"
            local path = nil
            if not root_can_reach_metric then
                reason_code = "NO_SAFE_JOIN_PATH"
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
                    local connected = find_path(all_edges, metric.base_entity_id, dimension.entity_id, false)
                    reason_code = connected and "FANOUT_REQUIRES_POLICY" or reason
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
            add_issue(ctx, "ERROR", "SEMANTIC_OBJECT", row_value(row, "OBJECT_NAME", 1), "SEMANTIC_MODEL_030",
                "Visible metric " .. tostring(row_value(row, "METRIC_NAME", 3))
                .. " cannot be grouped or filtered by dimension " .. tostring(row_value(row, "DIMENSION_NAME", 5))
                .. ": " .. tostring(matrix_row.reason_code) .. ".")
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
        validate_unique_keys(ctx)
        local safe_edges, all_edges = relationship_edges(ctx)
        validate_expressions(ctx, safe_edges)
        extract_metric_dependencies(ctx)
        detect_metric_cycles(ctx)
        validate_agent_metadata(ctx)
        compute_metric_dimension_matrix(ctx, safe_edges, all_edges)
        validate_visible_metric_dimension_pairs(ctx)
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

select_materialization = M.select_materialization
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILER_RUNTIME AS
local M = {}

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
    if type(plan) ~= "table" or plan.selected_materialization == nil or plan.selected_materialization == JSON_NULL then
        return nil
    end
    if type(plan.selected_materialization) == "table" then
        return plan.selected_materialization.materialization_name
    end
    return tostring(plan.selected_materialization)
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

-- Compile-result cache (BUG-D-002). The compiler is deterministic per
-- (model_version_id, normalized request), so a successful compile is reused
-- until PUBLISH_MODEL drops cache entries for the model version. The parsed
-- request is canonicalized (strip logging-only fields, sort top-level keys)
-- and hashed with a 64-bit polynomial hash. Collisions in this space are
-- vanishingly improbable for any realistic dashboard workload.

local CACHE_IGNORED_REQUEST_KEYS = {client = true, purpose = true,
    natural_language_text = true, natural_language = true}

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
    return encoded
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
                local dep_metric = ctx.metric_by_id[key(dep_id)]
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
        entity_by_id = {},
        entity_by_alias = {},
        dimensions = {},
        dimension_by_id = {},
        metrics = {},
        metric_by_id = {},
        facts = {},
        fact_by_id = {},
        fact_by_name = {},
        relationships = {},
        canonical_fields = {},
        synonym_fields = {},
    }

    local entity_rows = query([[
        SELECT ENTITY_ID, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS
        FROM SYS_SEMANTIC.ENTITIES
        WHERE MODEL_ID = :model_id
          AND VERSION_ID = :version_id
          AND STATUS = 'ACTIVE'
        ORDER BY ENTITY_ID
    ]], {model_id = model.model_id, version_id = model.version_id})
    for _, row in ipairs(entity_rows or {}) do
        local entity = {
            id = row_value(row, "ENTITY_ID", 1),
            name = row_value(row, "ENTITY_NAME", 2),
            source_schema = row_value(row, "SOURCE_SCHEMA", 3),
            source_object = row_value(row, "SOURCE_OBJECT", 4),
            alias = row_value(row, "SOURCE_ALIAS", 5),
        }
        ctx.entities[#ctx.entities + 1] = entity
        ctx.entity_by_id[key(entity.id)] = entity
        ctx.entity_by_alias[upper(entity.alias)] = entity
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
               COALESCE(mt.METRIC_KIND, mt.METRIC_TYPE) AS METRIC_KIND
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
        }
        ctx.metrics[#ctx.metrics + 1] = metric
        ctx.metric_by_id[key(metric.id)] = metric
        ctx.canonical_fields[upper(metric.name)] = metric
    end

    local fact_rows = query([[
        SELECT FACT_ID, FACT_NAME, ENTITY_ID, EXPRESSION, DATA_TYPE
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
        }
        ctx.facts[#ctx.facts + 1] = fact
        ctx.fact_by_id[key(fact.id)] = fact
        ctx.fact_by_name[upper(fact.name)] = fact
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
        ctx.relationships[#ctx.relationships + 1] = {
            id = row_value(row, "RELATIONSHIP_ID", 1),
            name = row_value(row, "RELATIONSHIP_NAME", 2),
            from_entity_id = row_value(row, "FROM_ENTITY_ID", 3),
            to_entity_id = row_value(row, "TO_ENTITY_ID", 4),
            join_condition = row_value(row, "JOIN_CONDITION", 5),
            cardinality = row_value(row, "RELATIONSHIP_CARDINALITY", 6),
            join_type = row_value(row, "JOIN_TYPE", 7),
            fanout_policy = row_value(row, "FANOUT_POLICY", 8),
            path_priority = row_value(row, "PATH_PRIORITY", 9),
        }
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
    local edges = {}
    local function add_edge(from_id, to_id, relationship)
        local from_key = key(from_id)
        edges[from_key] = edges[from_key] or {}
        edges[from_key][#edges[from_key] + 1] = {
            to_id = to_id,
            relationship = relationship,
        }
    end
    for _, relationship in ipairs(ctx.relationships) do
        local cardinality = upper(relationship.cardinality)
        if cardinality == "ONE_TO_ONE" then
            add_edge(relationship.from_entity_id, relationship.to_entity_id, relationship)
            add_edge(relationship.to_entity_id, relationship.from_entity_id, relationship)
        elseif cardinality == "MANY_TO_ONE" then
            add_edge(relationship.from_entity_id, relationship.to_entity_id, relationship)
        elseif cardinality == "ONE_TO_MANY" then
            add_edge(relationship.to_entity_id, relationship.from_entity_id, relationship)
        elseif cardinality == "MANY_TO_MANY" and not missing(relationship.fanout_policy) then
            add_edge(relationship.from_entity_id, relationship.to_entity_id, relationship)
            add_edge(relationship.to_entity_id, relationship.from_entity_id, relationship)
        end
    end
    return edges
end

local function find_path(ctx, from_id, to_id)
    if key(from_id) == key(to_id) then
        return {}
    end
    local edges = ctx._edges
    if edges == nil then
        edges = relationship_edges(ctx)
        ctx._edges = edges
    end
    local queue = {{id = from_id, path = {}}}
    local seen = {[key(from_id)] = true}
    local index = 1
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        for _, edge in ipairs(edges[key(current.id)] or {}) do
            local next_key = key(edge.to_id)
            if not seen[next_key] then
                local next_path = {}
                for _, path_edge in ipairs(current.path) do
                    next_path[#next_path + 1] = path_edge
                end
                next_path[#next_path + 1] = {
                    from_entity_id = current.id,
                    to_entity_id = edge.to_id,
                    relationship = edge.relationship,
                }
                if next_key == key(to_id) then
                    return next_path
                end
                seen[next_key] = true
                queue[#queue + 1] = {id = edge.to_id, path = next_path}
            end
        end
    end
    return nil
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
            local dep_metric = ctx.metric_by_id[key(dep_id)]
            if dep_metric ~= nil then
                collect_metric_entities(ctx, dep_metric, needed_entities, seen_metrics)
            end
        end
    end
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
        for _, candidate in ipairs(ctx.metrics) do
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
    return nil, error_result("SEMANTIC_REQUEST_033", "Unsupported filter operator: " .. tostring(op) .. ". Supported operators: =, !=, <>, >, >=, <, <=, LIKE, IN, BETWEEN.")
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
            return nil, nil, error_result("SEMANTIC_REQUEST_042", "No safe relationship path from semantic object root to entity " .. tostring(entity and entity.name or entity_id) .. ".")
        end
        local path_names = {}
        for _, edge in ipairs(path) do
            local relationship = edge.relationship
            path_names[#path_names + 1] = relationship.name
            local join_key = key(relationship.id)
            local to_entity_key = key(edge.to_entity_id)
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
    for _, dimension in ipairs(dimensions) do
        select_parts[#select_parts + 1] = tostring(dimension.expression) .. " AS " .. quote_alias(dimension.name)
        group_parts[#group_parts + 1] = tostring(dimension.expression)
    end
    for _, metric in ipairs(metrics) do
        select_parts[#select_parts + 1] = expand_metric(ctx, metric) .. " AS " .. quote_alias(metric.name)
    end

    local sql_parts = {}
    sql_parts[#sql_parts + 1] = "SELECT " .. table.concat(select_parts, ", ")
    sql_parts[#sql_parts + 1] = "FROM " .. quote_qualified(root.source_schema, root.source_object) .. " " .. tostring(root.alias)
    for _, join in ipairs(joins) do
        sql_parts[#sql_parts + 1] = tostring(join.relationship.join_type or "LEFT") .. " JOIN "
            .. quote_qualified(join.entity.source_schema, join.entity.source_object)
            .. " " .. tostring(join.entity.alias)
            .. " ON " .. tostring(join.relationship.join_condition)
    end
    if #filters > 0 then
        local predicates = {}
        for _, filter in ipairs(filters) do
            predicates[#predicates + 1] = filter.predicate
        end
        sql_parts[#sql_parts + 1] = "WHERE " .. table.concat(predicates, " AND ")
    end
    if #group_parts > 0 then
        sql_parts[#sql_parts + 1] = "GROUP BY " .. table.concat(group_parts, ", ")
    end
    if having_predicates ~= nil and #having_predicates > 0 then
        sql_parts[#sql_parts + 1] = "HAVING " .. table.concat(having_predicates, " AND ")
    end
    if #order_by > 0 then
        sql_parts[#sql_parts + 1] = "ORDER BY " .. table.concat(order_by, ", ")
    end
    if limit ~= nil then
        sql_parts[#sql_parts + 1] = "LIMIT " .. tostring(limit)
    end
    return table.concat(sql_parts, "\n")
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
          CACHE_HIT, FINISHED_AT
        ) VALUES (
          :model_id, :version_id, :client_name, :purpose, :request_json, :generated_sql,
          :plan_json, :requested_metrics, :requested_dimensions, :status, :error_code, :error_message,
          :cache_hit, CURRENT_TIMESTAMP
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
          ERROR_MESSAGE, FINISHED_AT
        ) VALUES (
          :model_id, :version_id, :client_name, :original_sql, :generated_sql,
          :plan_json, :requested_dimensions, :requested_metrics, :materialization_used,
          :status, :error_code,
          :error_message, CURRENT_TIMESTAMP
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
          AND STATUS = 'OK'
          AND ERROR_COUNT = 0
        ORDER BY VALIDATION_RUN_ID DESC
        LIMIT 1
    ]], {model_id = model.model_id, version_id = model.version_id})
    if rows == nil or #rows == 0 then
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

    local matrix_err = validate_metric_dimensions(ctx, selected_metrics, all_dimensions)
    if matrix_err ~= nil then
        return matrix_err
    end

    local joins, relationship_paths, join_err = plan_joins(ctx, needed_entities)
    if join_err ~= nil then
        return join_err
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
        local op = upper(having_filter.op or having_filter.operator or "=")
        local expr = expand_metric(ctx, metric_field)
        local predicate, predicate_err = build_dimension_predicate(expr, op, having_filter.value, metric_field.data_type, having_filter.value_sql)
        if predicate_err ~= nil then
            return predicate_err
        end
        having_predicates[#having_predicates + 1] = predicate
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
        and #selected_metrics > 0 then
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

    local plan = {
        model = model.model_name,
        version_id = model.version_id,
        version_number = model.version_number,
        object = ctx.object.name,
        metrics = {},
        metric_details = {},
        dimensions = {},
        filters = filters,
        relationship_paths = relationship_paths,
        selected_materialization = JSON_NULL,
        materialization_decision = materialization_decision,
        validation_run_id = validation_run_id,
        warnings = {},
    }
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
    local result = ok_result(sql_text, plan, validation_run_id)
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
            local u = token_upper(tokens[idx])
            if u == "IN" or u == "BETWEEN" or u == "LIKE" or u == "=" or u == "!=" or u == "<>" or u == ">" or u == ">=" or u == "<" or u == "<=" then
                op_index = idx
                op = u
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
        if op == "IN" then
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
            local u = token_upper(tokens[idx])
            if u == "IN" or u == "BETWEEN" or u == "LIKE" or u == "=" or u == "!=" or u == "<>" or u == ">" or u == ">=" or u == "<" or u == "<=" then
                op_index = idx
                op = u
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
        if op == "IN" then
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

compile_request_json = M.compile_request_json
compile_sql = M.compile_sql
compile_sql_debug = M.compile_sql_debug
compile_sql_for_preprocessor = M.compile_sql_for_preprocessor
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
    for i = start_index, #tokens do
        if tokens[i].depth == 0 then
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
        error("SEMANTIC_DDL_012: expected REPLACE FACTS, REPLACE METRICS, or ADD OR REPLACE METRIC")
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

local function validate_metric_shape(model, metric)
    if metric.metric_type == "RATIO" then
        local metric_input_count = 0
        for _, identifier in ipairs(identifiers_in_expression(metric.expression)) do
            if object_id_by_name(model, "METRIC", identifier) ~= nil then
                metric_input_count = metric_input_count + 1
            end
        end
        if metric_input_count < 2 then
            error("SEMANTIC_DDL_070: RATIO metric " .. metric.name .. " must reference at least two aggregate metrics")
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
    for _, identifier in ipairs(identifiers_in_expression(metric.expression)) do
        local object_type = nil
        local object_id_value = object_id_by_name(model, "FACT", identifier)
        local input_role = "MEASURE"
        if object_id_value ~= nil then
            object_type = "FACT"
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
            definition_source_id = definition_source_id,
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
            definition_source_id = definition_source_id,
        })
        existing_id = scalar([[
            SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND UPPER(METRIC_NAME) = UPPER(:metric_name)
        ]], {model_id = model.model_id, version_id = model.version_id, metric_name = metric.name})
    end
    add_object_column(object_id_value, "METRIC", existing_id, metric.name, true)
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

local function snapshot_model_state(model)
    return {
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
        if sql_bool(dry_run) then
            return {{"DRY_RUN", nil, "Parsed Semantic SQL definition.", normalized_json, #definition.facts + #definition.metrics, nil}}
        end
        local model = load_model(definition.model_name)
        restore_model = model
        local object_id_value = object_id(model, definition.object_name)
        snapshot = snapshot_model_state(model)
        source_id = insert_source(model, definition, definition_sql, normalized_json, "APPLYING")
        if definition.replace_facts then
            replace_object_columns(object_id_value, "FACT")
        end
        if definition.replace_metrics then
            replace_object_columns(object_id_value, "METRIC")
        end
        for _, fact in ipairs(definition.facts) do
            upsert_fact(model, object_id_value, fact)
        end
        for _, metric in ipairs(definition.metrics) do
            upsert_metric(model, object_id_value, metric, source_id)
        end
        local validation_rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = definition.model_name})
        local error_count = 0
        for _, row in ipairs(validation_rows or {}) do
            if row_value(row, "SEVERITY", 1) == "ERROR" then
                error_count = error_count + 1
            end
        end
        local validation_run_id = scalar([[
            SELECT MAX(VALIDATION_RUN_ID)
            FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id
              AND VERSION_ID = :version_id
        ]], {model_id = model.model_id, version_id = model.version_id})
        query([[
            UPDATE SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES
            SET APPLY_STATUS = :status,
                VALIDATION_RUN_ID = :validation_run_id
            WHERE DEFINITION_SOURCE_ID = :source_id
        ]], {status = error_count > 0 and "VALIDATION_FAILED" or "APPLIED", validation_run_id = validation_run_id, source_id = source_id})
        if error_count > 0 then
            restore_model_state(model, snapshot)
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = definition.model_name})
            return {{"ERROR", "SEMANTIC_DDL_090", "Definition rejected; validation failed and catalog state was restored.", normalized_json, #definition.facts + #definition.metrics, validation_run_id}}
        end
        return {{"OK", nil, "Semantic definition applied.", normalized_json, #definition.facts + #definition.metrics, validation_run_id}}
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

local function canonical_relationship_sql(model_name, row)
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP("
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
            SELECT e.ENTITY_NAME, e.SOURCE_SCHEMA, e.SOURCE_OBJECT, e.SOURCE_ALIAS,
                   e.PRIMARY_KEY_EXPR, e.GRAIN_DESCRIPTION, e.DESCRIPTION
            FROM SYS_SEMANTIC.ENTITIES e
            JOIN SYS_SEMANTIC.MODELS m
              ON m.MODEL_ID = e.MODEL_ID
             AND m.ACTIVE_VERSION_ID = e.VERSION_ID
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
                   r.RELATIONSHIP_CARDINALITY, r.JOIN_TYPE, r.FANOUT_POLICY
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
            add_export("RELATIONSHIP", model_name .. "." .. name, canonical_relationship_sql(model_name, row))
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
        return {status = "OK", generated_sql = "EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(" .. sql_string(text) .. ", FALSE)"}
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
        line = string.gsub(line, "\r$", "")
        lines[#lines + 1] = line
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
