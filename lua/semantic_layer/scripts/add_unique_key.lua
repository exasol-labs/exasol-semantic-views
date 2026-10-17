--- Adds a unique key to an entity, or updates the existing key of that name; returns one row with the key and WAS_UPDATE.
-- @script SEMANTIC_ADMIN.ADD_UNIQUE_KEY
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity in the model's active version.
-- @param KEY_NAME Key name (identifier); an existing key of this name on the entity is updated.
-- @param KEY_KIND PRIMARY, UNIQUE or ALTERNATE; NULL defaults to UNIQUE.
-- @param DESCRIPTION Optional description; NULL stores none.
-- @param SOURCE_FORMAT Free-text source format, upper-cased; NULL defaults to OSI.
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

import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local scalar = script_support.ESV_ROWS.scalar

local function model_row(model_name)
    local rows = query([[
        SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID AS VERSION_ID, m.STATUS
        FROM SYS_SEMANTIC.MODELS m
        WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ]], {model_name = model_name})
    if rows == nil or #rows == 0 then
        error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
    end
    return {
        model_id = row_value(rows[1], "MODEL_ID", 1),
        version_id = row_value(rows[1], "VERSION_ID", 2),
        status = row_value(rows[1], "STATUS", 3)
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

local existing_key_rows = query([[
    SELECT UNIQUE_KEY_ID, KEY_KIND, DESCRIPTION, SOURCE_FORMAT
    FROM SYS_SEMANTIC.UNIQUE_KEYS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id
      AND UPPER(KEY_NAME) = UPPER(:key_name)
]], {model_id = model.model_id, version_id = model.version_id, entity_id = entity_id, key_name = key_name})
local unique_key_id = nil
local previous_key_kind = nil
local previous_description = nil
local previous_source_format = nil
if existing_key_rows ~= nil and #existing_key_rows > 0 then
    unique_key_id = row_value(existing_key_rows[1], "UNIQUE_KEY_ID", 1)
    previous_key_kind = row_value(existing_key_rows[1], "KEY_KIND", 2)
    previous_description = row_value(existing_key_rows[1], "DESCRIPTION", 3) or null
    previous_source_format = row_value(existing_key_rows[1], "SOURCE_FORMAT", 4)
end
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

query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS
    SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model.model_id, version_id = model.version_id})

if tostring(model.status) == "PUBLISHED" then
    local candidate_validation = query(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.NEW_VALIDATION_ERRORS(:model_name)",
        {model_name = model_name})
    for _, validation_row in ipairs(candidate_validation or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
            local rule_code = row_value(validation_row, "RULE_CODE", 4)
                or "SEMANTIC_MODEL_ERROR"
            local message = row_value(validation_row, "MESSAGE", 5)
                or "model validation failed"
            if was_update then
                query([[
                    UPDATE SYS_SEMANTIC.UNIQUE_KEYS
                    SET KEY_KIND = :key_kind, DESCRIPTION = :description,
                        SOURCE_FORMAT = :source_format,
                        UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
                    WHERE UNIQUE_KEY_ID = :unique_key_id
                ]], {unique_key_id = unique_key_id, key_kind = previous_key_kind,
                      description = previous_description,
                      source_format = previous_source_format})
            else
                query("DELETE FROM SYS_SEMANTIC.UNIQUE_KEYS WHERE UNIQUE_KEY_ID = :unique_key_id",
                    {unique_key_id = unique_key_id})
            end
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published unique-key change rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
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
