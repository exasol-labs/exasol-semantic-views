--- Lists vendor extension payloads stored on a model, optionally filtered; returns one row per extension.
-- @script SEMANTIC_ADMIN.GET_CUSTOM_EXTENSIONS
-- @param MODEL_NAME
-- @param SCOPE_TYPE Optional filter: MODEL, SEMANTIC_OBJECT, ENTITY, RELATIONSHIP, DIMENSION, FACT or METRIC. NULL lists all scopes.
-- @param SCOPE_NAME Element name for the SCOPE_TYPE filter; required when SCOPE_TYPE is set and not MODEL.
-- @param VENDOR_NAME Optional vendor filter (case-insensitive); NULL lists all vendors.
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
