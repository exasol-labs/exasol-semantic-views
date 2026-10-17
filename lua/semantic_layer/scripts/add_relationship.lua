--- Adds a relationship between two entities, rolling back if it adds validation errors on a published model; returns nothing.
-- @script SEMANTIC_ADMIN.ADD_RELATIONSHIP
-- @param MODEL_NAME
-- @param RELATIONSHIP_NAME New relationship name, unique among active relationships.
-- @param FROM_ENTITY_NAME Entity on the from side of the join.
-- @param TO_ENTITY_NAME Entity on the to side of the join.
-- @param JOIN_CONDITION Required SQL join condition between the two entities' aliases.
-- @param CARDINALITY ONE_TO_ONE, ONE_TO_MANY, MANY_TO_ONE or MANY_TO_MANY.
-- @param JOIN_TYPE INNER or LEFT; NULL defaults to LEFT.
-- @param FANOUT_POLICY ALLOCATE, DEDUPLICATE or REFERENCE_ONLY; NULL stores no policy.
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

if missing(JOIN_CONDITION) then
    error("SEMANTIC_ADMIN_001: JOIN_CONDITION is required")
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local relationship_name = normalize_name(RELATIONSHIP_NAME, "RELATIONSHIP_NAME")
local from_entity_name = normalize_name(FROM_ENTITY_NAME, "FROM_ENTITY_NAME")
local to_entity_name = normalize_name(TO_ENTITY_NAME, "TO_ENTITY_NAME")
local cardinality = normalize_choice(CARDINALITY, "CARDINALITY", {"ONE_TO_ONE", "ONE_TO_MANY", "MANY_TO_ONE", "MANY_TO_MANY"})
local join_type = "LEFT"
if not missing(JOIN_TYPE) then
    join_type = normalize_choice(JOIN_TYPE, "JOIN_TYPE", {"INNER", "LEFT"})
end

-- FANOUT_POLICY is a closed set, not free text. No value authorizes traversal
-- of a fanning edge; the policy records what the modeler intends a planner to
-- do if the technique is ever proven. Unrecognized values used to be stored
-- verbatim, which read as a safety override that did not exist. See
-- docs/validation-rules.md#fanout-policy.
local fanout_policy = null
if not missing(FANOUT_POLICY) then
    fanout_policy = normalize_choice(FANOUT_POLICY, "FANOUT_POLICY",
        {"ALLOCATE", "DEDUPLICATE", "REFERENCE_ONLY"})
end

local model = model_row(model_name)
local from_entity_id = entity_id(model, from_entity_name)
local to_entity_id = entity_id(model, to_entity_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.RELATIONSHIPS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(RELATIONSHIP_NAME) = UPPER(:relationship_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model.model_id, version_id = model.version_id, relationship_name = relationship_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_016: duplicate relationship: " .. relationship_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.RELATIONSHIPS (
      MODEL_ID, VERSION_ID, RELATIONSHIP_NAME, FROM_ENTITY_ID, TO_ENTITY_ID,
      JOIN_CONDITION, RELATIONSHIP_CARDINALITY, JOIN_TYPE, IS_REQUIRED, FANOUT_POLICY,
      PATH_PRIORITY, STATUS
    ) VALUES (
      :model_id, :version_id, :relationship_name, :from_entity_id, :to_entity_id,
      :join_condition, :cardinality, :join_type, FALSE, :fanout_policy,
      100, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    relationship_name = relationship_name,
    from_entity_id = from_entity_id,
    to_entity_id = to_entity_id,
    join_condition = tostring(JOIN_CONDITION),
    cardinality = cardinality,
    join_type = join_type,
    fanout_policy = fanout_policy
})
local relationship_id = scalar([[
    SELECT RELATIONSHIP_ID FROM SYS_SEMANTIC.RELATIONSHIPS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND UPPER(RELATIONSHIP_NAME) = UPPER(:relationship_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model.model_id, version_id = model.version_id,
      relationship_name = relationship_name})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = model.version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model.model_id, version_id = model.version_id})
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
            query("DELETE FROM SYS_SEMANTIC.RELATIONSHIPS WHERE RELATIONSHIP_ID = :relationship_id",
                {relationship_id = relationship_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published relationship change rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
