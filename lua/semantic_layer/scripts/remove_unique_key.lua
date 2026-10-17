--- Removes an entity's unique key once it has no columns, restoring it on a published model if validation fails; one row.
-- @script SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity that owns the key. Required.
-- @param KEY_NAME Active unique key to remove; its columns must be removed first. Required.
-- @returns TABLE

-- NULL arrives as userdata, and userdata is truthy: `value or ""` would render
-- it as an address and defeat the required-parameter check below.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local model_name = trim(MODEL_NAME)
local entity_name = trim(ENTITY_NAME)
local key_name = trim(KEY_NAME)
if model_name == "" or entity_name == "" or key_name == "" then
    error("SEMANTIC_ADMIN_001: model, entity, and key names are required")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, m.STATUS, uk.UNIQUE_KEY_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
    JOIN SYS_SEMANTIC.UNIQUE_KEYS uk
      ON uk.ENTITY_ID = e.ENTITY_ID AND uk.VERSION_ID = e.VERSION_ID
     AND UPPER(uk.KEY_NAME) = UPPER(:key_name) AND uk.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name, key_name = key_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_096: active unique key not found: " .. key_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local model_status = row_value(rows[1], "STATUS", 3)
local unique_key_id = row_value(rows[1], "UNIQUE_KEY_ID", 4)
local column_rows = query([[
    SELECT ORDINAL_POSITION FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS
    WHERE UNIQUE_KEY_ID = :unique_key_id LIMIT 1
]], {unique_key_id = unique_key_id})
if column_rows ~= nil and #column_rows > 0 then
    error("SEMANTIC_ADMIN_097: cannot remove a unique key with columns; "
        .. "remove its unique-key columns first")
end
query([[
    UPDATE SYS_SEMANTIC.UNIQUE_KEYS SET STATUS = 'INACTIVE',
        UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
    WHERE UNIQUE_KEY_ID = :unique_key_id
]], {unique_key_id = unique_key_id})
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
            query([[
                UPDATE SYS_SEMANTIC.UNIQUE_KEYS SET STATUS = 'ACTIVE',
                    UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
                WHERE UNIQUE_KEY_ID = :unique_key_id
            ]], {unique_key_id = unique_key_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published unique-key removal rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
query("DELETE FROM SYS_SEMANTIC.UNIQUE_KEYS WHERE UNIQUE_KEY_ID = :unique_key_id",
    {unique_key_id = unique_key_id})
exit({{unique_key_id, model_name, entity_name, key_name, "REMOVED"}}, [[
  UNIQUE_KEY_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  KEY_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
