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
local model_name = trim(MODEL_NAME)
local identity_name = trim(IDENTITY_NAME)
local representation_name = trim(REPRESENTATION_NAME)
local source_expression = trim(SOURCE_EXPRESSION)
local binding_kind = upper(BINDING_KIND)
if source_expression == "" then error("SEMANTIC_ADMIN_001: SOURCE_EXPRESSION is required") end
if binding_kind ~= "DIRECT" and binding_kind ~= "MAPPED" then
    error("SEMANTIC_ADMIN_003: BINDING_KIND must be DIRECT or MAPPED")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, si.ENTITY_ID, si.IDENTITY_ID,
           er.REPRESENTATION_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.MODEL_ID = m.MODEL_ID AND si.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name) AND si.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = si.ENTITY_ID AND er.VERSION_ID = si.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, identity_name = identity_name,
      representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_049: identity or representation not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local identity_id = row_value(rows[1], "IDENTITY_ID", 4)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 5)
local existing = query([[
    SELECT IDENTITY_BINDING_ID FROM SYS_SEMANTIC.IDENTITY_BINDINGS
    WHERE IDENTITY_ID = :identity_id AND REPRESENTATION_ID = :representation_id
      AND STATUS = 'ACTIVE'
]], {identity_id = identity_id, representation_id = representation_id})
local binding_id
if existing ~= nil and #existing > 0 then
    binding_id = row_value(existing[1], "IDENTITY_BINDING_ID", 1)
    query([[
        UPDATE SYS_SEMANTIC.IDENTITY_BINDINGS
        SET SOURCE_EXPRESSION = :source_expression, BINDING_KIND = :binding_kind,
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE IDENTITY_BINDING_ID = :binding_id
    ]], {binding_id = binding_id, source_expression = source_expression,
          binding_kind = binding_kind})
else
    query([[
        INSERT INTO SYS_SEMANTIC.IDENTITY_BINDINGS (
          MODEL_ID, VERSION_ID, ENTITY_ID, IDENTITY_ID, REPRESENTATION_ID,
          SOURCE_EXPRESSION, BINDING_KIND, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :identity_id, :representation_id,
          :source_expression, :binding_kind, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          identity_id = identity_id, representation_id = representation_id,
          source_expression = source_expression, binding_kind = binding_kind})
    local ids = query("SELECT MAX(IDENTITY_BINDING_ID) FROM SYS_SEMANTIC.IDENTITY_BINDINGS WHERE IDENTITY_ID = :identity_id",
        {identity_id = identity_id})
    binding_id = ids[1][1]
end
if binding_kind == "DIRECT" then
    query("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_BINDING_ID = :binding_id",
        {binding_id = binding_id})
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
query("EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)",
    {model_name = model_name})
exit({{binding_id, model_name, identity_name, representation_name,
    source_expression, binding_kind}}, [[
  IDENTITY_BINDING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256),
  SOURCE_EXPRESSION VARCHAR(2000000), BINDING_KIND VARCHAR(32)
]])
