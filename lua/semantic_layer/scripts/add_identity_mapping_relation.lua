-- NULL arrives as userdata, and userdata is truthy: `value or ""` would render
-- it as an address and defeat the required-parameter check below.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
local function upper(value) return string.upper(trim(value)) end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local certification = upper(CERTIFICATION_STATUS)
if trim(MODEL_NAME) == "" or trim(IDENTITY_NAME) == ""
    or trim(REPRESENTATION_NAME) == "" or trim(SOURCE_SCHEMA) == ""
    or trim(SOURCE_OBJECT) == "" or trim(SOURCE_LOCAL_COLUMN) == ""
    or trim(SEMANTIC_KEY_COLUMN) == "" then
    error("SEMANTIC_ADMIN_001: model, identity, representation, mapping source, and mapping columns are required")
end
if certification ~= "CERTIFIED" then
    error("SEMANTIC_ADMIN_003: runtime identity mappings must be CERTIFIED")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, ib.IDENTITY_BINDING_ID
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
     AND ib.BINDING_KIND = 'MAPPED' AND ib.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = trim(MODEL_NAME), identity_name = trim(IDENTITY_NAME),
      representation_name = trim(REPRESENTATION_NAME)})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_050: active MAPPED identity binding not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local binding_id = row_value(rows[1], "IDENTITY_BINDING_ID", 3)
query("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_BINDING_ID = :binding_id",
    {binding_id = binding_id})
query([[
    INSERT INTO SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS (
      MODEL_ID, VERSION_ID, IDENTITY_BINDING_ID, SOURCE_SCHEMA, SOURCE_OBJECT,
      SOURCE_LOCAL_COLUMN, SEMANTIC_KEY_COLUMN, CERTIFICATION_STATUS, STATUS
    ) VALUES (
      :model_id, :version_id, :binding_id, :source_schema, :source_object,
      :source_local_column, :semantic_key_column, :certification, 'ACTIVE'
    )
]], {model_id = model_id, version_id = version_id, binding_id = binding_id,
      source_schema = trim(SOURCE_SCHEMA), source_object = trim(SOURCE_OBJECT),
      source_local_column = trim(SOURCE_LOCAL_COLUMN),
      semantic_key_column = trim(SEMANTIC_KEY_COLUMN), certification = certification})
local ids = query("SELECT MAX(IDENTITY_MAPPING_ID) FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_BINDING_ID = :binding_id",
    {binding_id = binding_id})
local mapping_id = ids[1][1]
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
query("EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)",
    {model_name = trim(MODEL_NAME)})
exit({{mapping_id, trim(MODEL_NAME), trim(IDENTITY_NAME),
    trim(REPRESENTATION_NAME), trim(SOURCE_SCHEMA), trim(SOURCE_OBJECT), certification}}, [[
  IDENTITY_MAPPING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256),
  SOURCE_SCHEMA VARCHAR(256), SOURCE_OBJECT VARCHAR(256),
  CERTIFICATION_STATUS VARCHAR(32)
]])
