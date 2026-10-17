--- Adds a semantic identity to an entity with a binding for every active representation; returns one row per binding.
-- @script SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY_WITH_BINDINGS
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity that receives the identity; it must not already have an active one.
-- @param IDENTITY_NAME New identity name, unique among the model's active identities.
-- @param IDENTITY_KIND BUSINESS or GLOBAL.
-- @param DATA_TYPE Required SQL data type of the identity value.
-- @param DESCRIPTION Optional description, stored as given.
-- @param BINDINGS_JSON Array, one per active representation: {representation_name, source_expression, binding_kind: DIRECT|MAPPED, mapping}.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")
local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
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
local function json_scalar(value)
    if type(value) == "table" then return nil end
    return value
end
local function required_json(item, field, label)
    local value = json_scalar(item[field])
    if missing(value) then
        error("SEMANTIC_ADMIN_063: " .. label .. " is required")
    end
    return trim(value)
end
local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
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
local decoded, bindings = pcall(semantic_definition.decode_json,
    missing(BINDINGS_JSON) and "" or tostring(BINDINGS_JSON))
if not decoded or type(bindings) ~= "table" or #bindings == 0 then
    error("SEMANTIC_ADMIN_063: BINDINGS_JSON must be a non-empty JSON array: "
        .. tostring(bindings))
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
local existing = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND (ENTITY_ID = :entity_id OR UPPER(IDENTITY_NAME) = UPPER(:identity_name))
      AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      identity_name = identity_name})
if tonumber(existing or 0) > 0 then
    error("SEMANTIC_ADMIN_051: entity or identity name already has an active semantic identity")
end
local representation_rows = query([[
    SELECT REPRESENTATION_ID, REPRESENTATION_NAME
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id})
local representations = {}
for _, representation_row in ipairs(representation_rows or {}) do
    local name = row_value(representation_row, "REPRESENTATION_NAME", 2)
    representations[upper(name)] = {
        id = row_value(representation_row, "REPRESENTATION_ID", 1),
        name = name,
    }
end

local prepared = {}
local seen = {}
for index, item in ipairs(bindings) do
    if type(item) ~= "table" then
        error("SEMANTIC_ADMIN_063: binding " .. tostring(index) .. " must be an object")
    end
    local representation_name = required_json(
        item, "representation_name", "binding representation_name")
    local representation = representations[upper(representation_name)]
    if representation == nil then
        error("SEMANTIC_ADMIN_063: binding references an inactive or unknown representation: "
            .. representation_name)
    end
    if seen[upper(representation_name)] then
        error("SEMANTIC_ADMIN_063: duplicate binding for representation: "
            .. representation_name)
    end
    seen[upper(representation_name)] = true
    local binding_kind = upper(required_json(item, "binding_kind", "binding_kind"))
    if binding_kind ~= "DIRECT" and binding_kind ~= "MAPPED" then
        error("SEMANTIC_ADMIN_003: BINDING_KIND must be DIRECT or MAPPED")
    end
    local mapping = item.mapping
    if binding_kind == "DIRECT" and mapping ~= nil and mapping ~= null then
        error("SEMANTIC_ADMIN_063: DIRECT binding must not include mapping metadata: "
            .. representation_name)
    end
    if binding_kind == "MAPPED" and type(mapping) ~= "table" then
        error("SEMANTIC_ADMIN_063: MAPPED binding requires a mapping object: "
            .. representation_name)
    end
    local prepared_mapping = nil
    if binding_kind == "MAPPED" then
        local certification = upper(required_json(
            mapping, "certification_status", "mapping certification_status"))
        if certification ~= "CERTIFIED" then
            error("SEMANTIC_ADMIN_003: runtime identity mappings must be CERTIFIED")
        end
        prepared_mapping = {
            source_schema = required_json(mapping, "source_schema", "mapping source_schema"),
            source_object = required_json(mapping, "source_object", "mapping source_object"),
            source_local_column = required_json(
                mapping, "source_local_column", "mapping source_local_column"),
            semantic_key_column = required_json(
                mapping, "semantic_key_column", "mapping semantic_key_column"),
            certification_status = certification,
        }
    end
    prepared[#prepared + 1] = {
        representation = representation,
        source_expression = required_json(
            item, "source_expression", "binding source_expression"),
        binding_kind = binding_kind,
        mapping = prepared_mapping,
    }
end
for representation_key, representation in pairs(representations) do
    if not seen[representation_key] then
        error("SEMANTIC_ADMIN_063: no binding supplied for active representation: "
            .. tostring(representation.name))
    end
end

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
local identity_id = scalar([[
    SELECT IDENTITY_ID FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND UPPER(IDENTITY_NAME) = UPPER(:identity_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      identity_name = identity_name})
local result = {}
for _, item in ipairs(prepared) do
    query([[
        INSERT INTO SYS_SEMANTIC.IDENTITY_BINDINGS (
          MODEL_ID, VERSION_ID, ENTITY_ID, IDENTITY_ID, REPRESENTATION_ID,
          SOURCE_EXPRESSION, BINDING_KIND, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :identity_id, :representation_id,
          :source_expression, :binding_kind, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          identity_id = identity_id, representation_id = item.representation.id,
          source_expression = item.source_expression, binding_kind = item.binding_kind})
    local binding_id = scalar([[
        SELECT IDENTITY_BINDING_ID FROM SYS_SEMANTIC.IDENTITY_BINDINGS
        WHERE IDENTITY_ID = :identity_id AND REPRESENTATION_ID = :representation_id
          AND STATUS = 'ACTIVE'
    ]], {identity_id = identity_id,
          representation_id = item.representation.id})
    if item.mapping ~= nil then
        query([[
            INSERT INTO SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS (
              MODEL_ID, VERSION_ID, IDENTITY_BINDING_ID, SOURCE_SCHEMA,
              SOURCE_OBJECT, SOURCE_LOCAL_COLUMN, SEMANTIC_KEY_COLUMN,
              CERTIFICATION_STATUS, STATUS
            ) VALUES (
              :model_id, :version_id, :binding_id, :source_schema,
              :source_object, :source_local_column, :semantic_key_column,
              :certification_status, 'ACTIVE'
            )
        ]], {model_id = model_id, version_id = version_id, binding_id = binding_id,
              source_schema = item.mapping.source_schema,
              source_object = item.mapping.source_object,
              source_local_column = item.mapping.source_local_column,
              semantic_key_column = item.mapping.semantic_key_column,
              certification_status = item.mapping.certification_status})
    end
    result[#result + 1] = {identity_id, binding_id, model_name, entity_name,
        identity_name, item.representation.name, item.binding_kind}
end
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
                DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS
                WHERE IDENTITY_BINDING_ID IN (
                  SELECT IDENTITY_BINDING_ID FROM SYS_SEMANTIC.IDENTITY_BINDINGS
                  WHERE IDENTITY_ID = :identity_id
                )
            ]], {identity_id = identity_id})
            query("DELETE FROM SYS_SEMANTIC.IDENTITY_BINDINGS WHERE IDENTITY_ID = :identity_id",
                {identity_id = identity_id})
            query("DELETE FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES WHERE IDENTITY_ID = :identity_id",
                {identity_id = identity_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published identity-with-bindings candidate rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
exit(result, [[
  IDENTITY_ID DECIMAL(18,0), IDENTITY_BINDING_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256), IDENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256), BINDING_KIND VARCHAR(32)
]])
