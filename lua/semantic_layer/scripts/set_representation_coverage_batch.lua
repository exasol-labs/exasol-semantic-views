--- Sets coverage predicates and bounds for every active representation of an entity at once; returns one row per representation.
-- @script SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity in the model's active version.
-- @param COVERAGE_JSON Array covering every active representation: {representation_name, coverage_predicate, valid_from, valid_to}.
-- @returns TABLE

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value) return tostring(value):match("^%s*(.-)%s*$") end
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
import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local json = script_support.ESV_JSON

local function json_field(item, name)
    local value = item[name]
    if value == json.NULL then return nil end
    return value
end
local function sql_value(value)
    if value == nil then return null end
    return value
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local ok, declarations = pcall(json.decode, COVERAGE_JSON)
if not ok or type(declarations) ~= "table" or #declarations == 0 then
    local detail = not ok and tostring(declarations)
        or (type(declarations) ~= "table" and "top-level value is not an array"
            or "array is empty")
    error("SEMANTIC_ADMIN_060: COVERAGE_JSON must be a non-empty JSON array: "
        .. detail)
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, m.STATUS, er.REPRESENTATION_ID,
           er.REPRESENTATION_NAME, er.COVERAGE_PREDICATE, TO_CHAR(er.VALID_FROM, 'YYYY-MM-DD HH24:MI:SS.FF6') AS VALID_FROM,
           TO_CHAR(er.VALID_TO, 'YYYY-MM-DD HH24:MI:SS.FF6') AS VALID_TO
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
    ORDER BY er.PRIORITY, er.REPRESENTATION_ID
]], {model_name = model_name, entity_name = entity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_014: entity or active representations not found: " .. entity_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local model_status = row_value(rows[1], "STATUS", 3)
local representations = {}
for _, row in ipairs(rows) do
    local name = tostring(row_value(row, "REPRESENTATION_NAME", 5))
    representations[string.upper(name)] = {
        id = row_value(row, "REPRESENTATION_ID", 4),
        name = name,
        previous_predicate = row_value(row, "COVERAGE_PREDICATE", 6) or null,
        previous_valid_from = row_value(row, "VALID_FROM", 7) or null,
        previous_valid_to = row_value(row, "VALID_TO", 8) or null,
    }
end
local seen = {}
local prepared = {}
for index, item in ipairs(declarations) do
    if type(item) ~= "table" then
        error("SEMANTIC_ADMIN_060: coverage declaration " .. tostring(index) .. " must be an object")
    end
    local representation_name = normalize_name(
        json_field(item, "representation_name"),
        "COVERAGE_JSON[" .. tostring(index) .. "].representation_name")
    local key = string.upper(representation_name)
    local representation = representations[key]
    if representation == nil then
        error("SEMANTIC_ADMIN_047: active representation not found: " .. representation_name)
    end
    if seen[key] then
        error("SEMANTIC_ADMIN_060: duplicate coverage declaration: " .. representation_name)
    end
    seen[key] = true
    local predicate = json_field(item, "coverage_predicate")
    local valid_from = json_field(item, "valid_from")
    local valid_to = json_field(item, "valid_to")
    if predicate ~= nil then predicate = trim(predicate) end
    if predicate == nil and (valid_from ~= nil or valid_to ~= nil) then
        error("SEMANTIC_ADMIN_003: coverage bounds require COVERAGE_PREDICATE for "
            .. representation_name)
    end
    if predicate ~= nil and valid_from == nil and valid_to == nil then
        error("SEMANTIC_ADMIN_003: UNION partition requires VALID_FROM or VALID_TO for "
            .. representation_name)
    end
    prepared[#prepared + 1] = {
        representation = representation,
        predicate = sql_value(predicate),
        valid_from = sql_value(valid_from),
        valid_to = sql_value(valid_to),
    }
end
for key, representation in pairs(representations) do
    if not seen[key] then
        error("SEMANTIC_ADMIN_060: coverage batch must declare every active representation; missing: "
            .. representation.name)
    end
end

for _, item in ipairs(prepared) do
    query([[
        UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        SET COVERAGE_PREDICATE = :coverage_predicate,
            VALID_FROM = TO_TIMESTAMP(REPLACE(:valid_from, 'T', ' '), 'YYYY-MM-DD HH24:MI:SS.FF6'), VALID_TO = TO_TIMESTAMP(REPLACE(:valid_to, 'T', ' '), 'YYYY-MM-DD HH24:MI:SS.FF6'),
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE REPRESENTATION_ID = :representation_id
    ]], {representation_id = item.representation.id,
          coverage_predicate = item.predicate,
          valid_from = item.valid_from, valid_to = item.valid_to})
end
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
            for _, representation in pairs(representations) do
                query([[
                    UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
                    SET COVERAGE_PREDICATE = :coverage_predicate,
                        VALID_FROM = TO_TIMESTAMP(REPLACE(:valid_from, 'T', ' '), 'YYYY-MM-DD HH24:MI:SS.FF6'), VALID_TO = TO_TIMESTAMP(REPLACE(:valid_to, 'T', ' '), 'YYYY-MM-DD HH24:MI:SS.FF6'),
                        UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
                    WHERE REPRESENTATION_ID = :representation_id
                ]], {representation_id = representation.id,
                      coverage_predicate = representation.previous_predicate,
                      valid_from = representation.previous_valid_from,
                      valid_to = representation.previous_valid_to})
            end
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_059: published coverage batch rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end

-- The bounds are reported as stored, not as given: a TIMESTAMP result column
-- casts its value with the session's NLS_TIMESTAMP_FORMAT, and only the stored
-- value read back unformatted arrives in that format whatever the session's is.
local result = {}
for _, item in ipairs(prepared) do
    local bounds = query([[
        SELECT VALID_FROM, VALID_TO FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        WHERE REPRESENTATION_ID = :representation_id
    ]], {representation_id = item.representation.id})[1]
    result[#result + 1] = {item.representation.id, model_name, entity_name,
        item.representation.name, item.predicate == null and "NONE" or "UNION",
        item.predicate, row_value(bounds, "VALID_FROM", 1), row_value(bounds, "VALID_TO", 2)}
end
exit(result, [[
  REPRESENTATION_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256),
  FUSION_STRATEGY VARCHAR(32), COVERAGE_PREDICATE VARCHAR(2000000),
  VALID_FROM TIMESTAMP, VALID_TO TIMESTAMP
]])
