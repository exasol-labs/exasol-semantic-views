--- Stores or updates a vendor extension JSON payload on a model element; returns one row with its id and whether it was an update.
-- @script SEMANTIC_ADMIN.ADD_CUSTOM_EXTENSION
-- @param MODEL_NAME
-- @param SCOPE_TYPE Element kind: MODEL, SEMANTIC_OBJECT, ENTITY, RELATIONSHIP, DIMENSION, FACT or METRIC (case-insensitive); required.
-- @param SCOPE_NAME Name of the scoped element; ignored for MODEL, required for every other SCOPE_TYPE.
-- @param VENDOR_NAME Vendor that owns the payload; required. Part of the upsert key.
-- @param DATA_JSON Extension payload; required and must be valid JSON (any shape). Replaces the stored payload on update.
-- @param SOURCE_FORMAT Format label, upper-cased; NULL defaults to OSI. Part of the upsert key.
-- @param EXTENSION_NAME Extension name within the vendor; NULL defaults to 'default'. Part of the upsert key.
-- @returns TABLE

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
