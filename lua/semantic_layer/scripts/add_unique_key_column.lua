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
if missing(COLUMN_NAME) and missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_001: COLUMN_NAME or EXPRESSION is required")
end
if not missing(COLUMN_NAME) and not missing(EXPRESSION) then
    error("SEMANTIC_ADMIN_041: specify either COLUMN_NAME or EXPRESSION, not both")
end
local column_name = missing(COLUMN_NAME) and null or trim(COLUMN_NAME)
if column_name ~= null and not string.match(column_name, "^[A-Za-z_][A-Za-z0-9_]*$") then
    error("SEMANTIC_ADMIN_002: invalid COLUMN_NAME: " .. column_name)
end
local expression = optional_text(EXPRESSION)
local model = model_row(model_name)
local unique_key_id = scalar([[
    SELECT uk.UNIQUE_KEY_ID
    FROM SYS_SEMANTIC.UNIQUE_KEYS uk
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.ENTITY_ID = uk.ENTITY_ID
    WHERE uk.MODEL_ID = :model_id
      AND uk.VERSION_ID = :version_id
      AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
      AND UPPER(uk.KEY_NAME) = UPPER(:key_name)
]], {model_id = model.model_id, version_id = model.version_id, entity_name = entity_name, key_name = key_name})
if unique_key_id == nil then
    error("SEMANTIC_ADMIN_042: unique key not found: " .. key_name)
end
local ordinal = ORDINAL_POSITION
if missing(ordinal) then
    ordinal = scalar([[
        SELECT COALESCE(MAX(ORDINAL_POSITION), 0) + 1
        FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
        WHERE UNIQUE_KEY_ID = :unique_key_id
    ]], {unique_key_id = unique_key_id})
end

local existing_rows = query([[
    SELECT COLUMN_NAME, EXPRESSION
    FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
    WHERE UNIQUE_KEY_ID = :unique_key_id
      AND ORDINAL_POSITION = :ordinal
]], {unique_key_id = unique_key_id, ordinal = ordinal})
local was_update = existing_rows ~= nil and #existing_rows > 0
local previous_column_name = was_update
    and (row_value(existing_rows[1], "COLUMN_NAME", 1) or null) or null
local previous_expression = was_update
    and (row_value(existing_rows[1], "EXPRESSION", 2) or null) or null
if was_update then
    query([[
        UPDATE SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
        SET COLUMN_NAME = :column_name,
            EXPRESSION = :expression
        WHERE UNIQUE_KEY_ID = :unique_key_id
          AND ORDINAL_POSITION = :ordinal
    ]], {unique_key_id = unique_key_id, ordinal = ordinal, column_name = column_name, expression = expression})
else
    query([[
        INSERT INTO SYS_SEMANTIC.UNIQUE_KEY_COLUMNS (
          UNIQUE_KEY_ID, ORDINAL_POSITION, COLUMN_NAME, EXPRESSION
        ) VALUES (
          :unique_key_id, :ordinal, :column_name, :expression
        )
    ]], {unique_key_id = unique_key_id, ordinal = ordinal, column_name = column_name, expression = expression})
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
                    UPDATE SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
                    SET COLUMN_NAME = :column_name, EXPRESSION = :expression
                    WHERE UNIQUE_KEY_ID = :unique_key_id
                      AND ORDINAL_POSITION = :ordinal
                ]], {unique_key_id = unique_key_id, ordinal = ordinal,
                      column_name = previous_column_name,
                      expression = previous_expression})
            else
                query([[
                    DELETE FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
                    WHERE UNIQUE_KEY_ID = :unique_key_id
                      AND ORDINAL_POSITION = :ordinal
                ]], {unique_key_id = unique_key_id, ordinal = ordinal})
            end
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published unique-key column change rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end

exit({{unique_key_id, model_name, entity_name, key_name, ordinal, column_name, expression, was_update}}, [[
  UNIQUE_KEY_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  KEY_NAME VARCHAR(256),
  ORDINAL_POSITION DECIMAL(18,0),
  COLUMN_NAME VARCHAR(256),
  EXPRESSION VARCHAR(2000000),
  WAS_UPDATE BOOLEAN
]])
