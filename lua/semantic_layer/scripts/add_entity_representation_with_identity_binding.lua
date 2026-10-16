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
local function normalize_name(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    local name = trim(value)
    if not string.match(name, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. name)
    end
    return name
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function json_scalar(value)
    if type(value) == "table" then return nil end
    return value
end
local function required_mapping(mapping, field)
    local value = json_scalar(mapping[field])
    if missing(value) then
        error("SEMANTIC_ADMIN_064: mapping " .. field .. " is required")
    end
    return trim(value)
end
local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
end

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local source_schema = normalize_name(SOURCE_SCHEMA, "SOURCE_SCHEMA")
local source_object = normalize_name(SOURCE_OBJECT, "SOURCE_OBJECT")
local identity_name = normalize_name(IDENTITY_NAME, "IDENTITY_NAME")
local source_expression = trim(SOURCE_EXPRESSION)
if source_expression == "" then
    error("SEMANTIC_ADMIN_001: SOURCE_EXPRESSION is required")
end
local source_kind = missing(SOURCE_KIND) and "RELATION" or upper(SOURCE_KIND)
if source_kind ~= "RELATION" and source_kind ~= "VIRTUAL_SCHEMA" then
    error("SEMANTIC_ADMIN_003: invalid SOURCE_KIND: " .. tostring(SOURCE_KIND))
end
-- The catalog settles it, so a declared kind that disagrees is refused rather
-- than stored. SOURCE_KIND was free text: VIRTUAL_SCHEMA over an ordinary table
-- and RELATION over a virtual schema were both accepted, and the compiler treats
-- the distinction as a planning input.
do
    local declared_virtual = source_kind == "VIRTUAL_SCHEMA"
    local actually_virtual = tonumber(scalar([[
        SELECT COUNT(*) FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS
        WHERE UPPER(SCHEMA_NAME) = UPPER(:source_schema)
    ]], {source_schema = source_schema}) or 0) > 0
    if declared_virtual ~= actually_virtual then
        error("SEMANTIC_ADMIN_218: SOURCE_KIND " .. source_kind .. " disagrees with"
            .. " the catalog: " .. tostring(source_schema) .. " is "
            .. (actually_virtual and "a virtual schema" or "not a virtual schema")
            .. ". Declare " .. (actually_virtual and "VIRTUAL_SCHEMA" or "RELATION")
            .. ", or omit SOURCE_KIND and let it default.")
    end
end
local binding_kind = upper(BINDING_KIND)
if binding_kind ~= "DIRECT" and binding_kind ~= "MAPPED" then
    error("SEMANTIC_ADMIN_003: BINDING_KIND must be DIRECT or MAPPED")
end
local priority = missing(PRIORITY) and 100 or tonumber(PRIORITY)
if priority == nil or priority < 1 or priority % 1 ~= 0 then
    error("SEMANTIC_ADMIN_003: PRIORITY must be a positive integer")
end
local mapping = nil
if binding_kind == "DIRECT" then
    if not missing(MAPPING_JSON) then
        error("SEMANTIC_ADMIN_064: DIRECT binding must not include MAPPING_JSON")
    end
else
    if missing(MAPPING_JSON) then
        error("SEMANTIC_ADMIN_064: MAPPED binding requires MAPPING_JSON")
    end
    local decoded, value = pcall(
        semantic_definition.decode_json, tostring(MAPPING_JSON))
    if not decoded or type(value) ~= "table" then
        error("SEMANTIC_ADMIN_064: MAPPING_JSON must be a JSON object: "
            .. tostring(value))
    end
    local certification = upper(required_mapping(value, "certification_status"))
    if certification ~= "CERTIFIED" then
        error("SEMANTIC_ADMIN_003: runtime identity mappings must be CERTIFIED")
    end
    mapping = {
        source_schema = required_mapping(value, "source_schema"),
        source_object = required_mapping(value, "source_object"),
        source_local_column = required_mapping(value, "source_local_column"),
        semantic_key_column = required_mapping(value, "semantic_key_column"),
        certification_status = certification,
    }
end

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, m.STATUS, e.ENTITY_ID,
           p.SOURCE_ALIAS, si.IDENTITY_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS p
      ON p.MODEL_ID = e.MODEL_ID AND p.VERSION_ID = e.VERSION_ID
     AND p.ENTITY_ID = e.ENTITY_ID AND p.REPRESENTATION_ROLE = 'PRIMARY'
     AND p.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.SEMANTIC_IDENTITIES si
      ON si.MODEL_ID = e.MODEL_ID AND si.VERSION_ID = e.VERSION_ID
     AND si.ENTITY_ID = e.ENTITY_ID
     AND UPPER(si.IDENTITY_NAME) = UPPER(:identity_name)
     AND si.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
      identity_name = identity_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_064: entity, primary representation, or active identity not found")
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local model_status = row_value(rows[1], "STATUS", 3)
local entity_id = row_value(rows[1], "ENTITY_ID", 4)
local source_alias = row_value(rows[1], "SOURCE_ALIAS", 5)
local identity_id = row_value(rows[1], "IDENTITY_ID", 6)
local duplicate = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
]], {entity_id = entity_id, representation_name = representation_name})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_046: duplicate representation name: " .. representation_name)
end

query([[
    INSERT INTO SYS_SEMANTIC.ENTITY_REPRESENTATIONS (
      MODEL_ID, VERSION_ID, ENTITY_ID, REPRESENTATION_NAME, SOURCE_KIND,
      SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS, REPRESENTATION_ROLE,
      PRIORITY, FRESHNESS_POLICY, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :representation_name, :source_kind,
      :source_schema, :source_object, :source_alias, 'ALTERNATE',
      :priority, :freshness_policy, 'ACTIVE'
    )
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      representation_name = representation_name, source_kind = source_kind,
      source_schema = source_schema, source_object = source_object,
      source_alias = source_alias, priority = priority,
      freshness_policy = missing(FRESHNESS_POLICY) and null
          or tostring(FRESHNESS_POLICY)})
local representation_id = scalar([[
    SELECT REPRESENTATION_ID FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
]], {entity_id = entity_id, representation_name = representation_name})
-- Keep the compound identity path symmetric with representation-plus-coverage.
-- Explicit bindings make the complete candidate visible to one validation run.
query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE,
      BINDING_PRIORITY, IS_DEFAULT, STATUS
    )
    SELECT d.MODEL_ID, d.VERSION_ID, d.ENTITY_ID, 'DIMENSION', d.DIMENSION_ID,
           :representation_id, d.EXPRESSION, 'PREFER', 1, FALSE, 'ACTIVE'
    FROM SYS_SEMANTIC.DIMENSIONS d
    WHERE d.MODEL_ID = :model_id AND d.VERSION_ID = :version_id
      AND d.ENTITY_ID = :entity_id AND d.STATUS = 'ACTIVE'
    UNION ALL
    SELECT f.MODEL_ID, f.VERSION_ID, f.ENTITY_ID, 'FACT', f.FACT_ID,
           :representation_id, f.EXPRESSION, 'PREFER', 1, FALSE, 'ACTIVE'
    FROM SYS_SEMANTIC.FACTS f
    WHERE f.MODEL_ID = :model_id AND f.VERSION_ID = :version_id
      AND f.ENTITY_ID = :entity_id AND f.STATUS = 'ACTIVE'
]], {representation_id = representation_id, model_id = model_id,
      version_id = version_id, entity_id = entity_id})
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
local binding_id = scalar([[
    SELECT IDENTITY_BINDING_ID FROM SYS_SEMANTIC.IDENTITY_BINDINGS
    WHERE IDENTITY_ID = :identity_id AND REPRESENTATION_ID = :representation_id
      AND STATUS = 'ACTIVE'
]], {identity_id = identity_id, representation_id = representation_id})
local mapping_id = null
if mapping ~= nil then
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
          source_schema = mapping.source_schema,
          source_object = mapping.source_object,
          source_local_column = mapping.source_local_column,
          semantic_key_column = mapping.semantic_key_column,
          certification_status = mapping.certification_status})
    mapping_id = scalar([[
        SELECT IDENTITY_MAPPING_ID
        FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS
        WHERE IDENTITY_BINDING_ID = :binding_id AND STATUS = 'ACTIVE'
    ]], {binding_id = binding_id})
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query("UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE' WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id AND STATUS IN ('OK', 'WARNING')",
    {model_id = model_id, version_id = version_id})
local candidate_validation = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.NEW_VALIDATION_ERRORS(:model_name)",
    {model_name = model_name})
local validation_errors = {}
local generated_binding_issues = {}
local binding_suffix = "@" .. upper(representation_name)
for _, validation_row in ipairs(candidate_validation or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
        local rule_code = row_value(validation_row, "RULE_CODE", 4)
            or "SEMANTIC_MODEL_ERROR"
        local message = row_value(validation_row, "MESSAGE", 5)
            or "model validation failed"
        local object_type = row_value(validation_row, "OBJECT_TYPE", 2)
            or "MODEL"
        local object_name = row_value(validation_row, "OBJECT_NAME", 3)
            or model_name
        local detail = tostring(rule_code)
            .. " [" .. tostring(object_type) .. " " .. tostring(object_name)
            .. "] " .. tostring(message)
        validation_errors[#validation_errors + 1] = detail
        local normalized_object_name = upper(object_name)
        if upper(object_type) == "ATTRIBUTE_BINDING"
                and string.sub(normalized_object_name, -#binding_suffix) == binding_suffix then
            generated_binding_issues[#generated_binding_issues + 1] = detail
        end
    end
end
if tostring(model_status) == "PUBLISHED" then
    if #validation_errors > 0 then
        query("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS WHERE IDENTITY_BINDING_ID = :binding_id",
            {binding_id = binding_id})
        query("DELETE FROM SYS_SEMANTIC.IDENTITY_BINDINGS WHERE IDENTITY_BINDING_ID = :binding_id",
            {binding_id = binding_id})
        query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE REPRESENTATION_ID = :representation_id",
            {representation_id = representation_id})
        query("DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS WHERE REPRESENTATION_ID = :representation_id",
            {representation_id = representation_id})
        query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
            {model_name = model_name})
        error("SEMANTIC_ADMIN_094: published representation-with-identity candidate rejected and restored; "
            .. "candidate introduced " .. tostring(#validation_errors)
            .. " validation error(s): " .. table.concat(validation_errors, "; "))
    end
end
exit({{representation_id, binding_id, mapping_id, model_name, entity_name,
    representation_name, identity_name, binding_kind, #generated_binding_issues,
    #generated_binding_issues == 0 and null
        or table.concat(generated_binding_issues, "; ")}}, [[
  REPRESENTATION_ID DECIMAL(18,0), IDENTITY_BINDING_ID DECIMAL(18,0),
  IDENTITY_MAPPING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256), REPRESENTATION_NAME VARCHAR(256),
  IDENTITY_NAME VARCHAR(256), BINDING_KIND VARCHAR(32),
  GENERATED_BINDING_ISSUE_COUNT DECIMAL(18,0),
  GENERATED_BINDING_ISSUES VARCHAR(2000000)
]])
