--- Registers an existing table or view as an aggregate materialization for a model; returns nothing.
-- @script SEMANTIC_ADMIN.REGISTER_MATERIALIZATION
-- @param MODEL_NAME
-- @param MATERIALIZATION_NAME New materialization name, unique in the model's active version.
-- @param PHYSICAL_SCHEMA Schema of the physical table or view, which must exist.
-- @param PHYSICAL_OBJECT Table or view name in PHYSICAL_SCHEMA.
-- @param MATERIALIZATION_TYPE Must be AGGREGATE.
-- @param FRESHNESS_POLICY ALWAYS, MANUAL, SNAPSHOT or MAX_AGE <n> MINUTES|HOURS|DAYS; NULL leaves it undeclared.
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

local function source_object_exists(schema_name, object_name)
    local count = scalar([[
        SELECT COUNT(*)
        FROM (
          SELECT TABLE_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_TABLES
          WHERE TABLE_SCHEMA = UPPER(:schema_name)
            AND TABLE_NAME = UPPER(:object_name)
          UNION ALL
          SELECT VIEW_NAME AS OBJECT_NAME
          FROM SYS.EXA_ALL_VIEWS
          WHERE VIEW_SCHEMA = UPPER(:schema_name)
            AND VIEW_NAME = UPPER(:object_name)
        ) visible_objects
    ]], {schema_name = schema_name, object_name = object_name})
    return tonumber(count or 0) > 0
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local materialization_name = normalize_name(MATERIALIZATION_NAME, "MATERIALIZATION_NAME")
local physical_schema = normalize_name(PHYSICAL_SCHEMA, "PHYSICAL_SCHEMA")
local physical_object = normalize_name(PHYSICAL_OBJECT, "PHYSICAL_OBJECT")
local materialization_type = normalize_choice(MATERIALIZATION_TYPE, "MATERIALIZATION_TYPE", {"AGGREGATE"})
local model = model_row(model_name)

-- The vocabulary is the selector's, read from the runtime that applies it. Free
-- text used to be stored verbatim and then rejected on every compile, so a
-- materialization registered with `'dbt run --select gold (hourly)'` could never
-- be chosen and nothing said so (BUG-27).
if type(import) == "function" then
    import("SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME", "materializations")
end
local freshness, freshness_error = materializations.freshness_policy(
    missing(FRESHNESS_POLICY) and nil or FRESHNESS_POLICY)
if freshness == nil then
    error("SEMANTIC_ADMIN_003: invalid FRESHNESS_POLICY: " .. freshness_error)
end

if not source_object_exists(physical_schema, physical_object) then
    error("SEMANTIC_ADMIN_030: materialization physical object not found: " .. physical_schema .. "." .. physical_object)
end

local duplicate = scalar([[
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
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_031: duplicate materialization: " .. materialization_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.MATERIALIZATIONS (
      MODEL_ID, VERSION_ID, MATERIALIZATION_NAME, PHYSICAL_SCHEMA,
      PHYSICAL_OBJECT, MATERIALIZATION_TYPE, FRESHNESS_POLICY, STATUS,
      FRESHNESS_MAX_AGE_SECONDS
    ) VALUES (
      :model_id, :version_id, :materialization_name, :physical_schema,
      :physical_object, :materialization_type, :freshness_policy, 'ACTIVE',
      :max_age_seconds
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    materialization_name = materialization_name,
    physical_schema = physical_schema,
    physical_object = physical_object,
    materialization_type = materialization_type,
    freshness_policy = freshness.text or optional_text(FRESHNESS_POLICY),
    max_age_seconds = freshness.seconds or null
})
-- A new materialization expands the set of candidate plans, so drop cached
-- compile results for this model version (BUG-D-002 cache coherence).
query([[
    DELETE FROM SYS_SEMANTIC.COMPILE_CACHE
    WHERE MODEL_VERSION_ID = :version_id
]], {version_id = model.version_id})
-- SOURCE_TRUST classifies the relations this model reads, and this call changed
-- that set, so the stored classes no longer describe it. They are derived by
-- VALIDATE_MODEL and cannot be recomputed here; clearing them makes the gap
-- visible as an empty SOURCE_TRUST_FOR_MODEL rather than as a picture that
-- quietly omits the relation just registered. The next VALIDATE_MODEL rebuilds
-- them, which is the next step in the authoring order anyway.
query([[
    DELETE FROM SYS_SEMANTIC.SOURCE_TRUST
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
]], {model_id = model.model_id, version_id = model.version_id})
