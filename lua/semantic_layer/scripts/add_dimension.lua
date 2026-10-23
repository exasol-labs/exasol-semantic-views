--- Adds a dimension on an entity, exposes it in a semantic view and validates; returns one row, rolling back on validation errors.
-- @script SEMANTIC_ADMIN.ADD_DIMENSION
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic view (object) that exposes the dimension as a column.
-- @param ENTITY_NAME Entity the dimension is defined on.
-- @param DIMENSION_NAME New dimension name; must be unique across the whole model, not only the view.
-- @param EXPRESSION Required SQL expression over the entity's source alias.
-- @param DATA_TYPE Required SQL data type of the dimension, stored as given.
-- @param DISPLAY_NAME Optional display name; NULL stores none.
-- @param DESCRIPTION Optional description; NULL stores none.
-- @param FORMAT_HINT Optional format hint; NULL stores none.
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
    -- Dimension names are unique per *model*, not per semantic object, while
    -- membership lives in OBJECT_COLUMNS. "duplicate dimension: ship_mode" gave
    -- no hint that the name was taken by a different object, nor that the
    -- existing dimension can simply be added to this one.
    local owner_rows = query([[
        SELECT so.OBJECT_NAME, e.ENTITY_NAME
        FROM SYS_SEMANTIC.DIMENSIONS d
        JOIN SYS_SEMANTIC.ENTITIES e ON e.ENTITY_ID = d.ENTITY_ID
        LEFT JOIN SYS_SEMANTIC.OBJECT_COLUMNS oc
          ON oc.COLUMN_KIND = 'DIMENSION' AND oc.OBJECT_REF_ID = d.DIMENSION_ID
        LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so ON so.OBJECT_ID = oc.OBJECT_ID
        WHERE d.MODEL_ID = :model_id
          AND d.VERSION_ID = :version_id
          AND UPPER(d.DIMENSION_NAME) = UPPER(:dimension_name)
        ORDER BY so.OBJECT_NAME
    ]], {model_id = model.model_id, version_id = model.version_id,
          dimension_name = dimension_name})
    local owners = {}
    local owning_entity = nil
    for _, owner_row in ipairs(owner_rows or {}) do
        local owner_object = row_value(owner_row, "OBJECT_NAME", 1)
        owning_entity = owning_entity or row_value(owner_row, "ENTITY_NAME", 2)
        if owner_object ~= nil and tostring(owner_object) ~= "" then
            owners[#owners + 1] = tostring(owner_object)
        end
    end
    local detail = " Dimension names are unique per model, not per semantic"
        .. " view, so this name is taken."
    if #owners > 0 then
        detail = detail .. " It is defined on entity '" .. tostring(owning_entity)
            .. "' and exposed by semantic view(s): " .. table.concat(owners, ", ")
            .. "."
    elseif owning_entity ~= nil then
        detail = detail .. " It is defined on entity '" .. tostring(owning_entity)
            .. "' and belongs to no semantic view yet."
    end
    detail = detail .. " Choose a distinct name for this view's column; there is"
        .. " no operation that shares one dimension between views. To change"
        .. " this dimension's own definition instead, call"
        .. " SEMANTIC_ADMIN.ADD_OR_REPLACE_DIMENSION, which updates it in place."
    error("SEMANTIC_ADMIN_019: duplicate dimension: " .. dimension_name .. "." .. detail)
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
query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY, IS_DEFAULT, STATUS
    )
    SELECT :model_id, :version_id, :entity_id, 'DIMENSION', :attribute_id,
           er.REPRESENTATION_ID, :expression, 'PREFER', 1,
           CASE WHEN er.REPRESENTATION_ROLE = 'PRIMARY' THEN TRUE ELSE FALSE END,
           'ACTIVE'
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
    WHERE er.ENTITY_ID = :entity_id AND er.STATUS = 'ACTIVE'
      AND (er.REPRESENTATION_ROLE = 'PRIMARY' OR (
        (SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS active_er
         WHERE active_er.ENTITY_ID = :entity_id AND active_er.STATUS = 'ACTIVE') > 1
        AND NOT EXISTS (
          SELECT 1 FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS uncovered_er
          WHERE uncovered_er.ENTITY_ID = :entity_id
            AND uncovered_er.STATUS = 'ACTIVE'
            AND uncovered_er.COVERAGE_PREDICATE IS NULL
        )
      ))
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id_value,
    attribute_id = dimension_id,
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
