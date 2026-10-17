--- Sets a materialization's status and clears the compile cache and source trust for the model; returns nothing.
-- @script SEMANTIC_ADMIN.SET_MATERIALIZATION_STATUS
-- @param MODEL_NAME
-- @param MATERIALIZATION_NAME Existing materialization to update. Required.
-- @param STATUS New status: ACTIVE, INACTIVE or STALE (case-insensitive). Required.
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

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local materialization_name = normalize_name(MATERIALIZATION_NAME, "MATERIALIZATION_NAME")
local status = normalize_choice(STATUS, "STATUS", {"ACTIVE", "INACTIVE", "STALE"})
local model = model_row(model_name)
local affected = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.MATERIALIZATIONS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(MATERIALIZATION_NAME) = UPPER(:materialization_name)
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    materialization_name = materialization_name
})
if tonumber(affected or 0) == 0 then
    error("SEMANTIC_ADMIN_032: materialization not found: " .. materialization_name)
end

query([[
    UPDATE SYS_SEMANTIC.MATERIALIZATIONS
    SET STATUS = :status
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(MATERIALIZATION_NAME) = UPPER(:materialization_name)
]], {
    status = status,
    model_id = model.model_id,
    version_id = model.version_id,
    materialization_name = materialization_name
})
-- Materialization status changes affect materialization selection, so drop
-- cached compile results for this model version (BUG-D-002 cache coherence).
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})
-- SOURCE_TRUST classifies the relations this model reads, and activating or
-- retiring a materialization changes that set, so the stored classes no longer
-- describe it. They are derived by VALIDATE_MODEL and cannot be recomputed
-- here; clearing them makes the gap visible as an empty SOURCE_TRUST_FOR_MODEL
-- rather than as a picture that still classifies a relation the planner can no
-- longer choose. The next VALIDATE_MODEL rebuilds them.
query([[
    DELETE FROM SYS_SEMANTIC.SOURCE_TRUST
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
]], {model_id = model.model_id, version_id = model.version_id})
