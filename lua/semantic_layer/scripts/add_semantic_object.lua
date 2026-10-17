--- Adds a semantic object (semantic view) rooted at an entity to a model; returns nothing.
-- @script SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT
-- @param MODEL_NAME
-- @param OBJECT_NAME New semantic object name; must be unique in the model.
-- @param ROOT_ENTITY_NAME Existing entity the object is rooted at. Required.
-- @param DESCRIPTION Optional description; NULL stores NULL.
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
