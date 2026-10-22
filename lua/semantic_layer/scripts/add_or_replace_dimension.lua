--- Creates or updates a dimension on a semantic object and validates the model, rolling back on error; returns one row with its id.
-- @script SEMANTIC_ADMIN.ADD_OR_REPLACE_DIMENSION
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic object that exposes the dimension; required, must exist.
-- @param ENTITY_NAME Entity the dimension expression reads from; required, must exist.
-- @param DIMENSION_NAME Dimension name; required identifier. An existing name is updated, a new one inserted.
-- @param EXPRESSION SQL expression over the entity alias; required. Also written to the default primary binding.
-- @param DATA_TYPE SQL data type of the dimension; required.
-- @param DISPLAY_NAME Optional display label; NULL clears it.
-- @param DESCRIPTION Optional description; NULL clears it.
-- @param FORMAT_HINT Optional format hint for clients; NULL clears it.
-- @param IS_CERTIFIED
-- @returns TABLE

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

import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local scalar = script_support.ESV_ROWS.scalar

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
        local severity = row_value(row, "SEVERITY", 1)
        if severity == "ERROR" or severity == "PRECONDITION" then
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

-- A partitioned entity requires every attribute on every partition. Preserve
-- source-specific bindings and seed only missing partitions from the governed
-- dimension expression.
query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
      BINDING_PRIORITY, IS_DEFAULT, STATUS
    )
    SELECT :model_id, :version_id, :entity_id, 'DIMENSION', :dimension_id,
           er.REPRESENTATION_ID, :expression, 'PREFER', 1, FALSE, 'ACTIVE'
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
    WHERE er.ENTITY_ID = :entity_id AND er.STATUS = 'ACTIVE'
      AND er.REPRESENTATION_ROLE <> 'PRIMARY'
      AND (SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS active_er
           WHERE active_er.ENTITY_ID = :entity_id AND active_er.STATUS = 'ACTIVE') > 1
      AND NOT EXISTS (
        SELECT 1 FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS uncovered_er
        WHERE uncovered_er.ENTITY_ID = :entity_id
          AND uncovered_er.STATUS = 'ACTIVE'
          AND uncovered_er.COVERAGE_PREDICATE IS NULL
      )
      AND NOT EXISTS (
        SELECT 1 FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS existing_binding
        WHERE existing_binding.ATTRIBUTE_TYPE = 'DIMENSION'
          AND existing_binding.ATTRIBUTE_ID = :dimension_id
          AND existing_binding.REPRESENTATION_ID = er.REPRESENTATION_ID
          AND existing_binding.STATUS = 'ACTIVE'
      )
]], {model_id = model.model_id, version_id = model.version_id,
    entity_id = entity_id_value, dimension_id = dimension_id,
    expression = tostring(EXPRESSION)})

-- Metric filters that name this dimension follow its new definition; see
-- reresolve_dimension_filters in the semantic definition runtime.
-- Imported only here: an insert has no filters to follow it.
if was_update then
    import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")
    semantic_definition.reresolve_dimension_filters_for(model_name, dimension_name)
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
