--- Declares a unique key and its columns on an entity, restoring on a published-model validation error; returns one row per column.
-- @script SEMANTIC_ADMIN.ADD_UNIQUE_KEY_WITH_COLUMNS
-- @param MODEL_NAME
-- @param ENTITY_NAME Active entity that owns the key; required.
-- @param KEY_NAME Key name; required identifier, unique within the entity.
-- @param KEY_KIND PRIMARY, UNIQUE or ALTERNATE; NULL defaults to UNIQUE.
-- @param DESCRIPTION Optional description; NULL leaves it unset.
-- @param SOURCE_FORMAT Format label, upper-cased; NULL defaults to OSI.
-- @param COLUMNS_JSON Non-empty JSON array of {column_name or expression, ordinal_position?}; ordinals contiguous from 1, default list order.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value) return tostring(value):match("^%s*(.-)%s*$") end
local function upper(value) return string.upper(trim(value)) end
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
local function json_scalar(value)
    if type(value) == "table" then return nil end
    return value
end
local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local key_name = normalize_name(KEY_NAME, "KEY_NAME")
local key_kind = missing(KEY_KIND) and "UNIQUE" or upper(KEY_KIND)
if key_kind ~= "PRIMARY" and key_kind ~= "UNIQUE" and key_kind ~= "ALTERNATE" then
    error("SEMANTIC_ADMIN_003: invalid KEY_KIND: " .. tostring(KEY_KIND))
end
local source_format = missing(SOURCE_FORMAT) and "OSI" or upper(SOURCE_FORMAT)
local decoded, columns = pcall(semantic_definition.decode_json,
    missing(COLUMNS_JSON) and "" or tostring(COLUMNS_JSON))
if not decoded or type(columns) ~= "table" or #columns == 0 then
    error("SEMANTIC_ADMIN_062: COLUMNS_JSON must be a non-empty JSON array: "
        .. tostring(columns))
end
local prepared = {}
local ordinals = {}
for index, item in ipairs(columns) do
    if type(item) ~= "table" then
        error("SEMANTIC_ADMIN_062: key column " .. tostring(index) .. " must be an object")
    end
    local ordinal = tonumber(json_scalar(item.ordinal_position) or index)
    if ordinal == nil or ordinal < 1 or ordinal % 1 ~= 0 then
        error("SEMANTIC_ADMIN_062: key-column ordinals must be positive integers")
    end
    if ordinals[ordinal] then
        error("SEMANTIC_ADMIN_062: duplicate key-column ordinal: " .. tostring(ordinal))
    end
    ordinals[ordinal] = true
    local column_name = json_scalar(item.column_name)
    local expression = json_scalar(item.expression)
    if not missing(column_name) then column_name = trim(column_name) else column_name = nil end
    if not missing(expression) then expression = trim(expression) else expression = nil end
    if (column_name == nil) == (expression == nil) then
        error("SEMANTIC_ADMIN_041: key column " .. tostring(ordinal)
            .. " must specify either column_name or expression, not both")
    end
    if column_name ~= nil
        and not string.match(column_name, "^[A-Za-z_][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid column_name: " .. column_name)
    end
    prepared[#prepared + 1] = {
        ordinal = ordinal,
        column_name = column_name == nil and null or column_name,
        expression = expression == nil and null or expression,
    }
end
table.sort(prepared, function(left, right) return left.ordinal < right.ordinal end)
for index, item in ipairs(prepared) do
    if item.ordinal ~= index then
        error("SEMANTIC_ADMIN_062: key-column ordinals must be contiguous from 1")
    end
end

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, m.STATUS, e.ENTITY_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local model_status = row_value(rows[1], "STATUS", 3)
local entity_id = row_value(rows[1], "ENTITY_ID", 4)
local duplicate = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.UNIQUE_KEYS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND UPPER(KEY_NAME) = UPPER(:key_name)
]], {model_id = model_id, version_id = version_id,
      entity_id = entity_id, key_name = key_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_011: duplicate unique key name: " .. key_name)
end
query([[
    INSERT INTO SYS_SEMANTIC.UNIQUE_KEYS (
      MODEL_ID, VERSION_ID, ENTITY_ID, KEY_NAME, KEY_KIND,
      DESCRIPTION, SOURCE_FORMAT, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :key_name, :key_kind,
      :description, :source_format, 'ACTIVE'
    )
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      key_name = key_name, key_kind = key_kind,
      description = missing(DESCRIPTION) and null or tostring(DESCRIPTION),
      source_format = source_format})
local unique_key_id = scalar([[
    SELECT UNIQUE_KEY_ID FROM SYS_SEMANTIC.UNIQUE_KEYS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND UPPER(KEY_NAME) = UPPER(:key_name)
]], {model_id = model_id, version_id = version_id,
      entity_id = entity_id, key_name = key_name})
for _, item in ipairs(prepared) do
    query([[
        INSERT INTO SYS_SEMANTIC.UNIQUE_KEY_COLUMNS (
          UNIQUE_KEY_ID, ORDINAL_POSITION, COLUMN_NAME, EXPRESSION
        ) VALUES (:unique_key_id, :ordinal, :column_name, :expression)
    ]], {unique_key_id = unique_key_id, ordinal = item.ordinal,
          column_name = item.column_name, expression = item.expression})
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
        "EXECUTE SCRIPT SEMANTIC_ADMIN.NEW_VALIDATION_ERRORS(:model_name)",
        {model_name = model_name})
    for _, validation_row in ipairs(candidate_validation or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
            local rule_code = row_value(validation_row, "RULE_CODE", 4)
                or "SEMANTIC_MODEL_ERROR"
            local message = row_value(validation_row, "MESSAGE", 5)
                or "model validation failed"
            query("DELETE FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS WHERE UNIQUE_KEY_ID = :unique_key_id",
                {unique_key_id = unique_key_id})
            query("DELETE FROM SYS_SEMANTIC.UNIQUE_KEYS WHERE UNIQUE_KEY_ID = :unique_key_id",
                {unique_key_id = unique_key_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published unique-key candidate rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
local result = {}
for _, item in ipairs(prepared) do
    result[#result + 1] = {unique_key_id, model_name, entity_name, key_name,
        key_kind, item.ordinal, item.column_name, item.expression}
end
exit(result, [[
  UNIQUE_KEY_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  KEY_NAME VARCHAR(256), KEY_KIND VARCHAR(64), ORDINAL_POSITION DECIMAL(18,0),
  COLUMN_NAME VARCHAR(256), EXPRESSION VARCHAR(2000000)
]])
