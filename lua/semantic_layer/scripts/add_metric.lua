--- Adds a metric to a semantic object and rolls it back if model validation fails; returns one row for the new metric.
-- @script SEMANTIC_ADMIN.ADD_METRIC
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic object that exposes the metric. Required.
-- @param METRIC_NAME New metric name; must be unique in the model and in the object's columns.
-- @param EXPRESSION Metric SQL expression. Required.
-- @param FILTER_EXPR Optional SQL filter applied to the metric; NULL means no filter.
-- @param METRIC_TYPE One of ADDITIVE, RATIO, DISTINCT, SEMI_ADDITIVE, WINDOW, DERIVED (case-insensitive). Required.
-- @param BASE_ENTITY_NAME Entity the metric aggregates over. Required.
-- @param DATA_TYPE SQL data type of the metric result. Required.
-- @param DISPLAY_NAME Optional display name; NULL stores NULL.
-- @param DESCRIPTION Optional description; NULL stores NULL.
-- @param FORMAT_HINT Optional format hint; NULL stores NULL.
-- @param IS_PRIVATE
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
        local severity = row_value(row, "SEVERITY", 1)
        if severity == "ERROR" or severity == "PRECONDITION" then
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
