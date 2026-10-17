--- Updates an active relationship's join condition, cardinality, join type or fan-out policy; returns one row with the new values.
-- @script SEMANTIC_ADMIN.SET_RELATIONSHIP
-- @param MODEL_NAME
-- @param RELATIONSHIP_NAME Active relationship to update.
-- @param JOIN_CONDITION New SQL join condition; NULL keeps the current one.
-- @param CARDINALITY ONE_TO_ONE, ONE_TO_MANY, MANY_TO_ONE or MANY_TO_MANY; NULL keeps the current one.
-- @param JOIN_TYPE INNER or LEFT; NULL keeps the current one.
-- @param FANOUT_POLICY ALLOCATE, DEDUPLICATE, REFERENCE_ONLY, or NONE to clear; NULL keeps the current one.
-- @returns TABLE

-- Update one relationship in place. Without this, correcting a cardinality or
-- a fanout policy took four steps -- remove the key mappings in descending
-- ordinal order, remove the relationship, add it back, re-add the mappings --
-- which is exactly the operation the fan-out reason codes push modelers
-- toward.
--
-- Any argument left NULL keeps its stored value; FANOUT_POLICY = 'NONE' clears
-- it. Endpoints are deliberately not editable: changing them makes it a
-- different relationship whose key mappings no longer describe it. Remove and
-- re-add for that.
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
-- NULL arrives as userdata, and userdata is truthy: `value or ""` would render
-- it as an address and defeat the required-parameter check below.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function normalize_choice(value, label, allowed)
    local choice = string.upper(trim(value))
    for _, allowed_value in ipairs(allowed) do
        if choice == allowed_value then
            return choice
        end
    end
    error("SEMANTIC_ADMIN_003: invalid " .. label .. ": " .. tostring(value))
end

local model_name = trim(MODEL_NAME)
local relationship_name = trim(RELATIONSHIP_NAME)
if model_name == "" or relationship_name == "" then
    error("SEMANTIC_ADMIN_001: MODEL_NAME and RELATIONSHIP_NAME are required")
end
if missing(JOIN_CONDITION) and missing(CARDINALITY) and missing(JOIN_TYPE)
    and missing(FANOUT_POLICY) then
    error("SEMANTIC_ADMIN_001: at least one of JOIN_CONDITION, CARDINALITY, "
        .. "JOIN_TYPE, or FANOUT_POLICY is required")
end

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, r.RELATIONSHIP_ID, r.JOIN_CONDITION,
           r.RELATIONSHIP_CARDINALITY, r.JOIN_TYPE, r.FANOUT_POLICY
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.RELATIONSHIPS r
      ON r.MODEL_ID = m.MODEL_ID AND r.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(r.RELATIONSHIP_NAME) = UPPER(:relationship_name)
     AND r.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, relationship_name = relationship_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_016: active relationship not found: " .. relationship_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local relationship_id = row_value(rows[1], "RELATIONSHIP_ID", 3)
local previous_join_condition = row_value(rows[1], "JOIN_CONDITION", 4)
local previous_cardinality = row_value(rows[1], "RELATIONSHIP_CARDINALITY", 5)
local previous_join_type = row_value(rows[1], "JOIN_TYPE", 6)
local previous_fanout_policy = row_value(rows[1], "FANOUT_POLICY", 7)
if previous_fanout_policy == null then
    previous_fanout_policy = nil
end

local next_join_condition = previous_join_condition
if not missing(JOIN_CONDITION) then
    next_join_condition = tostring(JOIN_CONDITION)
end
local next_cardinality = previous_cardinality
if not missing(CARDINALITY) then
    next_cardinality = normalize_choice(CARDINALITY, "CARDINALITY",
        {"ONE_TO_ONE", "ONE_TO_MANY", "MANY_TO_ONE", "MANY_TO_MANY"})
end
local next_join_type = previous_join_type
if not missing(JOIN_TYPE) then
    next_join_type = normalize_choice(JOIN_TYPE, "JOIN_TYPE", {"INNER", "LEFT"})
end
-- Same closed set as ADD_RELATIONSHIP, plus NONE to clear. No value authorizes
-- traversal; see docs/validation-rules.md#fanout-policy.
local next_fanout_policy = previous_fanout_policy
if not missing(FANOUT_POLICY) then
    local choice = normalize_choice(FANOUT_POLICY, "FANOUT_POLICY",
        {"ALLOCATE", "DEDUPLICATE", "REFERENCE_ONLY", "NONE"})
    next_fanout_policy = choice ~= "NONE" and choice or nil
end

local function apply_values(join_condition, cardinality, join_type, fanout_policy)
    query([[
        UPDATE SYS_SEMANTIC.RELATIONSHIPS
        SET JOIN_CONDITION = :join_condition,
            RELATIONSHIP_CARDINALITY = :cardinality,
            JOIN_TYPE = :join_type,
            FANOUT_POLICY = :fanout_policy
        WHERE RELATIONSHIP_ID = :relationship_id
    ]], {
        relationship_id = relationship_id,
        join_condition = join_condition,
        cardinality = cardinality,
        join_type = join_type,
        fanout_policy = fanout_policy == nil and null or fanout_policy,
    })
    query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
        {version_id = version_id})
    query([[
        UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS IN ('OK', 'WARNING')
    ]], {model_id = model_id, version_id = version_id})
    return query("EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)",
        {model_name = model_name})
end

local recertified = apply_values(next_join_condition, next_cardinality,
    next_join_type, next_fanout_policy)
-- RECERTIFY_MODEL_IF_PUBLISHED validates published models only, and reports
-- NOT_REQUIRED for a draft. A draft is left STALE on purpose: compilation is
-- gated on validation status, so nothing can query the model until the author
-- revalidates it, and reverting would block the repair this script exists for.
local validation_status = "NOT_REQUIRED"
if recertified ~= nil and #recertified > 0 then
    validation_status = tostring(row_value(recertified[1], "VALIDATION_STATUS", 3))
end
if validation_status == "ERROR" or validation_status == "PRECONDITION" then
    local detail_rows = query([[
        SELECT RULE_CODE, MESSAGE
        FROM SYS_SEMANTIC.VALIDATION_RESULTS
        WHERE VALIDATION_RUN_ID = (
            SELECT MAX(VALIDATION_RUN_ID) FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id)
          AND SEVERITY IN ('ERROR', 'PRECONDITION')
        ORDER BY VALIDATION_RESULT_ID
        LIMIT 1
    ]], {model_id = model_id, version_id = version_id})
    local detail = "model validation failed"
    if detail_rows ~= nil and #detail_rows > 0 then
        detail = tostring(row_value(detail_rows[1], "RULE_CODE", 1)) .. " "
            .. tostring(row_value(detail_rows[1], "MESSAGE", 2))
    end
    apply_values(previous_join_condition, previous_cardinality,
        previous_join_type, previous_fanout_policy)
    error("SEMANTIC_ADMIN_098: published relationship update rejected and restored; "
        .. "candidate introduced validation error: " .. detail)
end

exit({{relationship_id, model_name, relationship_name, next_join_condition,
       next_cardinality, next_join_type,
       next_fanout_policy == nil and null or next_fanout_policy,
       validation_status}}, [[
  RELATIONSHIP_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  RELATIONSHIP_NAME VARCHAR(256), JOIN_CONDITION VARCHAR(2000000),
  RELATIONSHIP_CARDINALITY VARCHAR(64), JOIN_TYPE VARCHAR(32),
  FANOUT_POLICY VARCHAR(64), VALIDATION_STATUS VARCHAR(32)
]])
