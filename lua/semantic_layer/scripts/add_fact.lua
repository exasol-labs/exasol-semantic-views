--- Adds a fact to an entity, binds it to the entity's representations and validates the model; returns one row with the fact id.
-- @script SEMANTIC_ADMIN.ADD_FACT
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity the fact is declared on; required, must exist.
-- @param FACT_NAME New fact name; required identifier, unique in the model.
-- @param EXPRESSION SQL expression over the entity alias; required.
-- @param DATA_TYPE SQL data type of the fact; required.
-- @param ADDITIVE_POLICY Required: ADDITIVE, SEMI_ADDITIVE or NON_ADDITIVE (case-insensitive).
-- @param DISPLAY_NAME Optional display label; NULL leaves it unset.
-- @param DESCRIPTION Optional description; NULL leaves it unset.
-- @param IS_PRIVATE
-- @param IS_CERTIFIED
-- @returns TABLE

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

local function bool_value(value, default_value)
    if missing(value) then
        return default_value
    end
    local text = string.lower(tostring(value))
    return value == true or text == "true" or text == "1"
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

local function validation_error_summary(validation_rows)
    for _, row in ipairs(validation_rows or {}) do
        local severity = row_value(row, "SEVERITY", 1)
        if severity == "ERROR" or severity == "PRECONDITION" then
            local object_type = row_value(row, "OBJECT_TYPE", 2) or "OBJECT"
            local object_name = row_value(row, "OBJECT_NAME", 3) or "unknown"
            local rule_code = row_value(row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR"
            local message = row_value(row, "MESSAGE", 5) or "model validation failed"
            return tostring(object_type) .. " " .. tostring(object_name) .. " " .. tostring(rule_code) .. ": " .. tostring(message)
        end
    end
    return nil
end

local function rollback_fact(model_name, fact_id_value)
    query([[
        DELETE FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
        WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID = :fact_id
    ]], {fact_id = fact_id_value})
    query([[
        DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID = :fact_id
    ]], {fact_id = fact_id_value})
    query([[
        DELETE FROM SYS_SEMANTIC.FACTS
        WHERE FACT_ID = :fact_id
    ]], {fact_id = fact_id_value})
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
end

if missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_001: EXPRESSION is required")
end
if missing(DATA_TYPE) then
    error("SEMANTIC_ADMIN_001: DATA_TYPE is required")
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local fact_name = normalize_name(FACT_NAME, "FACT_NAME")
local additive_policy = normalize_choice(ADDITIVE_POLICY, "ADDITIVE_POLICY", {"ADDITIVE", "SEMI_ADDITIVE", "NON_ADDITIVE"})
local model = model_row(model_name)
local entity_id_value = entity_id(model, entity_name)

local duplicate = scalar([[
    SELECT COUNT(*)
    FROM SYS_SEMANTIC.FACTS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(FACT_NAME) = UPPER(:fact_name)
]], {model_id = model.model_id, version_id = model.version_id, fact_name = fact_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_020: duplicate fact: " .. fact_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.FACTS (
      MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
      ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, IS_PRIVATE, IS_CERTIFIED, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :fact_name, :expression, :data_type,
      :additive_policy, :display_name, :description, :is_private, :is_certified, 'ACTIVE'
    )
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id_value,
    fact_name = fact_name,
    expression = tostring(EXPRESSION),
    data_type = tostring(DATA_TYPE),
    additive_policy = additive_policy,
    display_name = optional_text(DISPLAY_NAME),
    description = optional_text(DESCRIPTION),
    is_private = bool_value(IS_PRIVATE, false),
    is_certified = bool_value(IS_CERTIFIED, false)
})
local fact_id = scalar([[
    SELECT FACT_ID
    FROM SYS_SEMANTIC.FACTS
    WHERE MODEL_ID = :model_id
      AND VERSION_ID = :version_id
      AND UPPER(FACT_NAME) = UPPER(:fact_name)
]], {model_id = model.model_id, version_id = model.version_id, fact_name = fact_name})
query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY, IS_DEFAULT, STATUS
    )
    SELECT :model_id, :version_id, :entity_id, 'FACT', :attribute_id,
           er.REPRESENTATION_ID, :expression, 'PREFER', 1,
           CASE WHEN er.REPRESENTATION_ROLE = 'PRIMARY' THEN TRUE ELSE FALSE END,
           'ACTIVE'
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
    WHERE er.ENTITY_ID = :entity_id AND er.STATUS = 'ACTIVE'
      AND (er.REPRESENTATION_ROLE = 'PRIMARY' OR (
        (SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS active_er
         WHERE active_er.ENTITY_ID = :entity_id AND active_er.STATUS = 'ACTIVE') > 1
        AND NOT EXISTS (
          SELECT 1 FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS uncovered_er
          WHERE uncovered_er.ENTITY_ID = :entity_id
            AND uncovered_er.STATUS = 'ACTIVE'
            AND uncovered_er.COVERAGE_PREDICATE IS NULL
        )
      ))
]], {
    model_id = model.model_id,
    version_id = model.version_id,
    entity_id = entity_id_value,
    attribute_id = fact_id,
    expression = tostring(EXPRESSION),
})
local validation_rows = query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)", {model_name = model_name})
local validation_error = validation_error_summary(validation_rows)
if validation_error ~= nil then
    rollback_fact(model_name, fact_id)
    error("SEMANTIC_ADMIN_092: fact rejected; validation failed: " .. validation_error)
end
exit({{fact_id, model_name, entity_name, fact_name, false, bool_value(IS_PRIVATE, false), bool_value(IS_CERTIFIED, false)}}, [[
  FACT_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  FACT_NAME VARCHAR(256),
  WAS_UPDATE BOOLEAN,
  IS_PRIVATE BOOLEAN,
  IS_CERTIFIED BOOLEAN
]])
