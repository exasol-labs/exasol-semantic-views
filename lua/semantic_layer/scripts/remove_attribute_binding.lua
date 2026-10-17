--- Removes a dimension or fact binding from a representation, restoring it on a published model if validation fails; one row.
-- @script SEMANTIC_ADMIN.REMOVE_ATTRIBUTE_BINDING
-- @param MODEL_NAME
-- @param ATTRIBUTE_TYPE DIMENSION or FACT (case-insensitive).
-- @param ATTRIBUTE_NAME Dimension or fact whose binding is removed.
-- @param REPRESENTATION_NAME Representation the active binding points to.
-- @returns TABLE

-- NULL arrives as userdata, and userdata is truthy: `value or ""` would
-- render an address and report it back in the "not found" errors below.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
local model_name = trim(MODEL_NAME)
local attribute_type = string.upper(trim(ATTRIBUTE_TYPE))
local attribute_name = trim(ATTRIBUTE_NAME)
local representation_name = trim(REPRESENTATION_NAME)
if attribute_type ~= "DIMENSION" and attribute_type ~= "FACT" then
    error("SEMANTIC_ADMIN_001: ATTRIBUTE_TYPE must be DIMENSION or FACT")
end
local table_name = attribute_type == "DIMENSION" and "DIMENSIONS" or "FACTS"
local id_column = attribute_type == "DIMENSION" and "DIMENSION_ID" or "FACT_ID"
local name_column = attribute_type == "DIMENSION" and "DIMENSION_NAME" or "FACT_NAME"
local binding_rows = query(
    "SELECT ab.ATTRIBUTE_BINDING_ID, ab.MODEL_ID, ab.VERSION_ID, m.STATUS FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS ab"
      .. " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = ab.MODEL_ID"
      .. " JOIN SYS_SEMANTIC." .. table_name .. " a ON a." .. id_column .. " = ab.ATTRIBUTE_ID"
      .. " JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er ON er.REPRESENTATION_ID = ab.REPRESENTATION_ID"
      .. " WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)"
      .. " AND ab.ATTRIBUTE_TYPE = :attribute_type"
      .. " AND UPPER(a." .. name_column .. ") = UPPER(:attribute_name)"
      .. " AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)"
      .. " AND ab.STATUS = 'ACTIVE'",
    {model_name = model_name, attribute_type = attribute_type,
     attribute_name = attribute_name, representation_name = representation_name})
if binding_rows == nil or #binding_rows == 0 then
    error("SEMANTIC_ADMIN_025: attribute binding not found")
end
local binding_id = binding_rows[1][1]
local model_id = binding_rows[1][2]
local version_id = binding_rows[1][3]
local model_status = binding_rows[1][4]
query("UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS SET STATUS = 'INACTIVE' WHERE ATTRIBUTE_BINDING_ID = :binding_id",
    {binding_id = binding_id})
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
        local severity = validation_row.SEVERITY or validation_row.severity or validation_row[1]
        if tostring(severity) == "ERROR" or tostring(severity) == "PRECONDITION" then
            local rule_code = validation_row.RULE_CODE or validation_row.rule_code
                or validation_row[4] or "SEMANTIC_MODEL_ERROR"
            local message = validation_row.MESSAGE or validation_row.message
                or validation_row[5] or "model validation failed"
            query("UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS SET STATUS = 'ACTIVE' WHERE ATTRIBUTE_BINDING_ID = :binding_id",
                {binding_id = binding_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published attribute-binding removal rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE ATTRIBUTE_BINDING_ID = :binding_id",
    {binding_id = binding_id})
exit({{binding_id, model_name, attribute_type, attribute_name, representation_name, "REMOVED"}}, [[
  ATTRIBUTE_BINDING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32), ATTRIBUTE_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
