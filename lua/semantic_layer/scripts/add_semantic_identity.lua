--- Creates or updates an entity's semantic identity, restoring it if a published model fails validation; returns one row.
-- @script SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY
-- @param MODEL_NAME
-- @param ENTITY_NAME Active entity that owns the identity; required. An entity can hold only one active identity.
-- @param IDENTITY_NAME Identity name; required, unique across entities. An existing one on this entity is updated.
-- @param IDENTITY_KIND BUSINESS or GLOBAL (case-insensitive); required.
-- @param DATA_TYPE SQL data type of the identity key; required.
-- @param DESCRIPTION Optional description, stored as given.
-- @returns TABLE

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
local entity_name = trim(ENTITY_NAME)
local identity_name = trim(IDENTITY_NAME)
local identity_kind = upper(IDENTITY_KIND)
local data_type = trim(DATA_TYPE)
if model_name == "" or entity_name == "" or identity_name == "" or data_type == "" then
    error("SEMANTIC_ADMIN_001: model, entity, identity, and data type are required")
end
if identity_kind ~= "BUSINESS" and identity_kind ~= "GLOBAL" then
    error("SEMANTIC_ADMIN_003: IDENTITY_KIND must be BUSINESS or GLOBAL")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID, m.STATUS
    FROM SYS_SEMANTIC.MODELS m JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local model_status = row_value(rows[1], "STATUS", 4)
local existing = query([[
    SELECT IDENTITY_ID, IDENTITY_KIND, DATA_TYPE, DESCRIPTION
    FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND UPPER(IDENTITY_NAME) = UPPER(:identity_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      identity_name = identity_name})
local conflicting = query([[
    SELECT IDENTITY_ID FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND UPPER(IDENTITY_NAME) = UPPER(:identity_name)
      AND ENTITY_ID <> :entity_id AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      identity_name = identity_name})
if conflicting ~= nil and #conflicting > 0 then
    error("SEMANTIC_ADMIN_011: duplicate semantic identity name: " .. identity_name)
end
local entity_identity = query([[
    SELECT IDENTITY_NAME FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND UPPER(IDENTITY_NAME) <> UPPER(:identity_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      identity_name = identity_name})
if entity_identity ~= nil and #entity_identity > 0 then
    error("SEMANTIC_ADMIN_051: entity already has an active semantic identity: "
        .. tostring(row_value(entity_identity[1], "IDENTITY_NAME", 1)))
end
local identity_id
local was_update = existing ~= nil and #existing > 0
local previous_identity_kind = was_update
    and row_value(existing[1], "IDENTITY_KIND", 2) or nil
local previous_data_type = was_update
    and row_value(existing[1], "DATA_TYPE", 3) or nil
local previous_description = was_update
    and (row_value(existing[1], "DESCRIPTION", 4) or null) or null
if existing ~= nil and #existing > 0 then
    identity_id = row_value(existing[1], "IDENTITY_ID", 1)
    query([[
        UPDATE SYS_SEMANTIC.SEMANTIC_IDENTITIES
        SET IDENTITY_KIND = :identity_kind, DATA_TYPE = :data_type,
            DESCRIPTION = :description, UPDATED_AT = CURRENT_TIMESTAMP,
            UPDATED_BY = CURRENT_USER
        WHERE IDENTITY_ID = :identity_id
    ]], {identity_id = identity_id, identity_kind = identity_kind,
          data_type = data_type, description = DESCRIPTION})
else
    query([[
        INSERT INTO SYS_SEMANTIC.SEMANTIC_IDENTITIES (
          MODEL_ID, VERSION_ID, ENTITY_ID, IDENTITY_NAME, IDENTITY_KIND,
          DATA_TYPE, DESCRIPTION, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :identity_name, :identity_kind,
          :data_type, :description, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          identity_name = identity_name, identity_kind = identity_kind,
          data_type = data_type, description = DESCRIPTION})
    local ids = query("SELECT MAX(IDENTITY_ID) FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id",
        {model_id = model_id, version_id = version_id})
    identity_id = ids[1][1]
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
if tostring(model_status) == "PUBLISHED" then
    local validation_rows = query(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.NEW_VALIDATION_ERRORS(:model_name)",
        {model_name = model_name})
    for _, validation_row in ipairs(validation_rows or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
            local rule_code = row_value(validation_row, "RULE_CODE", 4)
                or "SEMANTIC_MODEL_ERROR"
            local message = row_value(validation_row, "MESSAGE", 5)
                or "model validation failed"
            if was_update then
                query([[
                    UPDATE SYS_SEMANTIC.SEMANTIC_IDENTITIES
                    SET IDENTITY_KIND = :identity_kind, DATA_TYPE = :data_type,
                        DESCRIPTION = :description, UPDATED_AT = CURRENT_TIMESTAMP,
                        UPDATED_BY = CURRENT_USER
                    WHERE IDENTITY_ID = :identity_id
                ]], {identity_id = identity_id,
                      identity_kind = previous_identity_kind,
                      data_type = previous_data_type,
                      description = previous_description})
            else
                query("DELETE FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES WHERE IDENTITY_ID = :identity_id",
                    {identity_id = identity_id})
            end
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published semantic-identity change rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
exit({{identity_id, model_name, entity_name, identity_name, identity_kind, data_type}}, [[
  IDENTITY_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), IDENTITY_KIND VARCHAR(32), DATA_TYPE VARCHAR(128)
]])
