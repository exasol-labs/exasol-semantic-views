--- Creates a DRAFT semantic model with its initial version 1 and sets it active; returns nothing.
-- @script SEMANTIC_ADMIN.CREATE_MODEL
-- @param MODEL_NAME
-- @param PUBLISHED_SCHEMA Schema that PUBLISH_MODEL will create views in; required identifier.
-- @param DESCRIPTION Optional model description; NULL leaves it unset.
-- @param OWNER_ROLE Optional owning role name; NULL leaves it unset.
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
