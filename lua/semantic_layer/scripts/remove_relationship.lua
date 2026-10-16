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
if model_name == "" or relationship_name == "" then
    error("SEMANTIC_ADMIN_001: MODEL_NAME and RELATIONSHIP_NAME are required")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, m.STATUS, r.RELATIONSHIP_ID
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
local model_status = row_value(rows[1], "STATUS", 3)
local relationship_id = row_value(rows[1], "RELATIONSHIP_ID", 4)
local mapping_rows = query([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS
    WHERE RELATIONSHIP_ID = :relationship_id
]], {relationship_id = relationship_id})
local mapping_count = mapping_rows ~= nil and #mapping_rows > 0
    and tonumber(mapping_rows[1][1]) or 0
if mapping_count > 0 then
    error("SEMANTIC_ADMIN_066: cannot remove a relationship with active key mappings; "
        .. "remove mappings in descending ordinal order first")
end
query([[
    UPDATE SYS_SEMANTIC.RELATIONSHIPS SET STATUS = 'REMOVED'
    WHERE RELATIONSHIP_ID = :relationship_id
]], {relationship_id = relationship_id})
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
            query("UPDATE SYS_SEMANTIC.RELATIONSHIPS SET STATUS = 'ACTIVE' WHERE RELATIONSHIP_ID = :relationship_id",
                {relationship_id = relationship_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published relationship removal rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
exit({{relationship_id, model_name, relationship_name, "REMOVED"}}, [[
  RELATIONSHIP_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  RELATIONSHIP_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
