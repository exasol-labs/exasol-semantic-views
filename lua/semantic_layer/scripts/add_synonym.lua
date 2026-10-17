--- Adds a search synonym to a model element; returns one row echoing the synonym and its source.
-- @script SEMANTIC_ADMIN.ADD_SYNONYM
-- @param MODEL_NAME
-- @param OBJECT_TYPE Element kind: SEMANTIC_OBJECT, ENTITY, DIMENSION, FACT or METRIC; required.
-- @param OBJECT_NAME Name of the element; required identifier, must exist.
-- @param SYNONYM Synonym text; required, unique per element (case-insensitive).
-- @param SOURCE Origin label, upper-cased; NULL defaults to MANUAL.
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
