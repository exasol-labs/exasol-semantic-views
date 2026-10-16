-- The one declared input to the trust boundary. Everything else about it --
-- which relations are governed, which materializations carry their policy -- is
-- derived by VALIDATE_MODEL from what the database says, never declared twice.
--
-- OPEN reports; GOVERNED refuses. A model is not moved to GOVERNED silently: the
-- caller sets it, then validates, and the validation tells them what it costs.
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

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local mode = normalize_choice(GOVERNANCE_MODE, "GOVERNANCE_MODE", {"OPEN", "GOVERNED"})

local rows = query([[
    SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end

query([[
    UPDATE SYS_SEMANTIC.MODELS
    SET GOVERNANCE_MODE = :mode, UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {mode = mode, model_name = model_name})

-- The stored trust classes were derived under the previous mode's rules, so they
-- no longer describe this model. Clearing them keeps a stale answer from being
-- read as a current one; the next VALIDATE_MODEL rebuilds them.
query([[
    DELETE FROM SYS_SEMANTIC.SOURCE_TRUST
    WHERE MODEL_ID IN (
      SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
    )
]], {model_name = model_name})

-- And the compile cache with them. Moving to GOVERNED can make the model fail
-- validation, and the compiler binds to the latest run that *succeeded* -- so a
-- cached statement would go on being served by a model that no longer validates.
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID IN (
      SELECT ACTIVE_VERSION_ID FROM SYS_SEMANTIC.MODELS
      WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
    )
]], {model_name = model_name})
