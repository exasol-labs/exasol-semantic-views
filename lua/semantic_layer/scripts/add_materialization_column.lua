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
