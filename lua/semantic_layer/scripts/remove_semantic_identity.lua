--- Removes an entity's semantic identity that has no active bindings; returns one row with status REMOVED.
-- @script SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY
-- @param MODEL_NAME
-- @param ENTITY_NAME Active entity owning the identity; required.
-- @param IDENTITY_NAME Active identity to remove; required. Refused while active bindings exist.
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
import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local scalar = script_support.ESV_ROWS.scalar
local model_name = trim(MODEL_NAME)
local entity_name = trim(ENTITY_NAME)
local identity_name = trim(IDENTITY_NAME)
if model_name == "" or entity_name == "" or identity_name == "" then
    error("SEMANTIC_ADMIN_001: model, entity, and identity are required")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, si.IDENTITY_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.ENTITY_ID = e.ENTITY_ID AND si.VERSION_ID = e.VERSION_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name) AND si.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
      identity_name = identity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_055: active semantic identity not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local identity_id = row_value(rows[1], "IDENTITY_ID", 3)
local binding_count = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.IDENTITY_BINDINGS
    WHERE IDENTITY_ID = :identity_id AND STATUS = 'ACTIVE'
]], {identity_id = identity_id})
if tonumber(binding_count or 0) > 0 then
    error("SEMANTIC_ADMIN_056: cannot remove a semantic identity with active bindings; remove the bindings first")
end
query("DELETE FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES WHERE IDENTITY_ID = :identity_id",
    {identity_id = identity_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
query("EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)",
    {model_name = model_name})
exit({{identity_id, model_name, entity_name, identity_name, "REMOVED"}}, [[
  IDENTITY_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
