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
local identity_name = trim(IDENTITY_NAME)
local representation_name = trim(REPRESENTATION_NAME)
if model_name == "" or identity_name == "" or representation_name == "" then
    error("SEMANTIC_ADMIN_001: model, identity, and representation are required")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, im.IDENTITY_MAPPING_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.MODEL_ID = m.MODEL_ID AND si.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name) AND si.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = si.ENTITY_ID AND er.VERSION_ID = si.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.IDENTITY_BINDINGS ib
      ON ib.IDENTITY_ID = si.IDENTITY_ID AND ib.REPRESENTATION_ID = er.REPRESENTATION_ID
     AND ib.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS im
      ON im.IDENTITY_BINDING_ID = ib.IDENTITY_BINDING_ID AND im.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, identity_name = identity_name,
      representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_052: active identity mapping relation not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local mapping_id = row_value(rows[1], "IDENTITY_MAPPING_ID", 3)
query("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_MAPPING_ID = :mapping_id",
    {mapping_id = mapping_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
query("EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)",
    {model_name = model_name})
exit({{mapping_id, model_name, identity_name, representation_name, "REMOVED"}}, [[
  IDENTITY_MAPPING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256), STATUS VARCHAR(32)
]])
