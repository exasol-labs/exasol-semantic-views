local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end

local function trim(value)
    return tostring(value):match("^%s*(.-)%s*$")
end

local function normalize_name(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. name)
    end
    return name
end

local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local predicate = missing(COVERAGE_PREDICATE) and null or trim(COVERAGE_PREDICATE)
local valid_from = missing(VALID_FROM) and null or VALID_FROM
local valid_to = missing(VALID_TO) and null or VALID_TO
if predicate == null and (valid_from ~= null or valid_to ~= null) then
    error("SEMANTIC_ADMIN_003: coverage bounds require COVERAGE_PREDICATE")
end
if predicate ~= null and valid_from == null and valid_to == null then
    error("SEMANTIC_ADMIN_003: UNION partition requires VALID_FROM or VALID_TO")
end

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, er.REPRESENTATION_ID,
           m.STATUS, er.COVERAGE_PREDICATE, er.VALID_FROM, er.VALID_TO
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
     AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID
     AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {
    model_name = model_name,
    entity_name = entity_name,
    representation_name = representation_name,
})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_047: active representation not found: " .. representation_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 3)
local model_status = row_value(rows[1], "STATUS", 4)
local previous_predicate = row_value(rows[1], "COVERAGE_PREDICATE", 5) or null
local previous_valid_from = row_value(rows[1], "VALID_FROM", 6) or null
local previous_valid_to = row_value(rows[1], "VALID_TO", 7) or null

query([[
    UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    SET COVERAGE_PREDICATE = :coverage_predicate,
        VALID_FROM = :valid_from,
        VALID_TO = :valid_to,
        UPDATED_AT = CURRENT_TIMESTAMP,
        UPDATED_BY = CURRENT_USER
    WHERE REPRESENTATION_ID = :representation_id
]], {
    representation_id = representation_id,
    coverage_predicate = predicate,
    valid_from = valid_from,
    valid_to = valid_to,
})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})

if tostring(model_status) == "PUBLISHED" then
    local candidate_validation = query(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
        {model_name = model_name})
    for _, validation_row in ipairs(candidate_validation or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
            local rule_code = row_value(validation_row, "RULE_CODE", 4)
                or "SEMANTIC_MODEL_ERROR"
            local message = row_value(validation_row, "MESSAGE", 5)
                or "model validation failed"
            query([[
                UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
                SET COVERAGE_PREDICATE = :coverage_predicate,
                    VALID_FROM = :valid_from,
                    VALID_TO = :valid_to,
                    UPDATED_AT = CURRENT_TIMESTAMP,
                    UPDATED_BY = CURRENT_USER
                WHERE REPRESENTATION_ID = :representation_id
            ]], {representation_id = representation_id,
                coverage_predicate = previous_predicate,
                valid_from = previous_valid_from,
                valid_to = previous_valid_to})
            -- Re-certify the restored published catalog. The failed candidate
            -- run remains as audit history but never gates the live surface.
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_059: published coverage change rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end

exit({{representation_id, model_name, entity_name, representation_name,
    predicate == null and "NONE" or "UNION", predicate, valid_from, valid_to}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  FUSION_STRATEGY VARCHAR(32),
  COVERAGE_PREDICATE VARCHAR(2000000),
  VALID_FROM TIMESTAMP,
  VALID_TO TIMESTAMP
]])
