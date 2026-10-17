--- Removes the key mapping at one ordinal of a relationship, restoring it on a published model if validation fails; one row.
-- @script SEMANTIC_ADMIN.REMOVE_RELATIONSHIP_KEY_MAPPING
-- @param MODEL_NAME
-- @param RELATIONSHIP_NAME Active relationship whose mapping is removed. Required.
-- @param ORDINAL_POSITION Positive integer position of the key mapping to remove.
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
local relationship_name = trim(RELATIONSHIP_NAME)
local ordinal = tonumber(ORDINAL_POSITION)
if model_name == "" or relationship_name == "" then
    error("SEMANTIC_ADMIN_001: MODEL_NAME and RELATIONSHIP_NAME are required")
end
if ordinal == nil or ordinal < 1 or ordinal % 1 ~= 0 then
    error("SEMANTIC_ADMIN_003: ORDINAL_POSITION must be a positive integer")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, m.STATUS, r.RELATIONSHIP_ID,
           rkm.FROM_COLUMN_NAME, rkm.FROM_EXPRESSION,
           rkm.TO_COLUMN_NAME, rkm.TO_EXPRESSION
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.RELATIONSHIPS r
      ON r.MODEL_ID = m.MODEL_ID AND r.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(r.RELATIONSHIP_NAME) = UPPER(:relationship_name)
     AND r.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS rkm
      ON rkm.RELATIONSHIP_ID = r.RELATIONSHIP_ID
     AND rkm.ORDINAL_POSITION = :ordinal
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, relationship_name = relationship_name,
      ordinal = ordinal})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_065: active relationship key mapping not found: "
        .. relationship_name .. "[" .. tostring(ordinal) .. "]")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local model_status = row_value(rows[1], "STATUS", 3)
local relationship_id = row_value(rows[1], "RELATIONSHIP_ID", 4)
local from_column = row_value(rows[1], "FROM_COLUMN_NAME", 5) or null
local from_expression = row_value(rows[1], "FROM_EXPRESSION", 6) or null
local to_column = row_value(rows[1], "TO_COLUMN_NAME", 7) or null
local to_expression = row_value(rows[1], "TO_EXPRESSION", 8) or null
query([[
    DELETE FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
    WHERE RELATIONSHIP_ID = :relationship_id AND ORDINAL_POSITION = :ordinal
]], {relationship_id = relationship_id, ordinal = ordinal})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
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
                INSERT INTO SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS (
                  RELATIONSHIP_ID, ORDINAL_POSITION, FROM_COLUMN_NAME,
                  FROM_EXPRESSION, TO_COLUMN_NAME, TO_EXPRESSION
                ) VALUES (
                  :relationship_id, :ordinal, :from_column, :from_expression,
                  :to_column, :to_expression
                )
            ]], {relationship_id = relationship_id, ordinal = ordinal,
                  from_column = from_column, from_expression = from_expression,
                  to_column = to_column, to_expression = to_expression})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published relationship-mapping removal rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
exit({{model_name, relationship_name, ordinal, "REMOVED"}}, [[
  MODEL_NAME VARCHAR(256), RELATIONSHIP_NAME VARCHAR(256),
  ORDINAL_POSITION DECIMAL(18,0), STATUS VARCHAR(32)
]])
