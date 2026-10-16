import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")
local function missing(value)
    return value == nil or value == null or string.match(tostring(value), "^%s*$") ~= nil
end
-- NULL arrives as userdata, and userdata is truthy: `value or ""` would render
-- it as an address and defeat the required-parameter check below.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
local function upper(value) return string.upper(trim(value)) end
local function normalized(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    local result = trim(value)
    if not string.match(result, "^[A-Za-z][A-Za-z0-9_]*$") then
        error("SEMANTIC_ADMIN_002: invalid " .. label .. ": " .. result)
    end
    return result
end
local function optional_text(value)
    if missing(value) then return null end
    return tostring(value)
end
local function bool_value(value, default_value)
    if missing(value) then return default_value end
    local text = string.lower(tostring(value))
    return value == true or text == "true" or text == "1"
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function scalar(sql_text, params)
    local rows = query(sql_text, params or {})
    if rows == nil or #rows == 0 then return nil end
    return rows[1][1]
end
local function validation_error_summary(rows)
    for _, row in ipairs(rows or {}) do
        if tostring(row_value(row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(row, "SEVERITY", 1)) == "PRECONDITION" then
            return tostring(row_value(row, "OBJECT_TYPE", 2) or "OBJECT") .. " "
                .. tostring(row_value(row, "OBJECT_NAME", 3) or "unknown") .. " "
                .. tostring(row_value(row, "RULE_CODE", 4) or "SEMANTIC_MODEL_ERROR")
                .. ": " .. tostring(row_value(row, "MESSAGE", 5) or "model validation failed")
        end
    end
    return nil
end

local attribute_type = upper(ATTRIBUTE_TYPE)
if attribute_type ~= "DIMENSION" and attribute_type ~= "FACT" then
    error("SEMANTIC_ADMIN_001: ATTRIBUTE_TYPE must be DIMENSION or FACT")
end
local model_name = normalized(MODEL_NAME, "MODEL_NAME")
local entity_name = normalized(ENTITY_NAME, "ENTITY_NAME")
local attribute_name = normalized(ATTRIBUTE_NAME, "ATTRIBUTE_NAME")
if missing(EXPRESSION) or missing(DATA_TYPE) then
    error("SEMANTIC_ADMIN_001: EXPRESSION and DATA_TYPE are required")
end
local expression = trim(EXPRESSION)
local data_type = trim(DATA_TYPE)
local object_name = nil
if attribute_type == "DIMENSION" then
    object_name = normalized(OBJECT_NAME, "OBJECT_NAME")
end
local additive_policy = nil
if attribute_type == "FACT" then
    additive_policy = upper(ADDITIVE_POLICY)
    if additive_policy ~= "ADDITIVE" and additive_policy ~= "SEMI_ADDITIVE"
            and additive_policy ~= "NON_ADDITIVE" then
        error("SEMANTIC_ADMIN_003: invalid ADDITIVE_POLICY: " .. tostring(ADDITIVE_POLICY))
    end
end
if missing(BINDINGS_JSON) or string.sub(trim(BINDINGS_JSON), 1, 1) ~= "[" then
    error("SEMANTIC_ADMIN_213: BINDINGS_JSON must be a JSON array")
end
local decoded, binding_specs = pcall(
    semantic_definition.decode_json, trim(BINDINGS_JSON))
if not decoded or type(binding_specs) ~= "table" then
    error("SEMANTIC_ADMIN_213: BINDINGS_JSON must be a JSON array: "
        .. tostring(binding_specs))
end

local model_rows = query([[
    SELECT MODEL_ID, ACTIVE_VERSION_ID
    FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if model_rows == nil or #model_rows == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end
local model_id = row_value(model_rows[1], "MODEL_ID", 1)
local version_id = row_value(model_rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = scalar([[
    SELECT ENTITY_ID FROM SYS_SEMANTIC.ENTITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND UPPER(ENTITY_NAME) = UPPER(:entity_name) AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_name = entity_name})
if entity_id == nil then
    error("SEMANTIC_ADMIN_014: entity not found: " .. entity_name)
end
local object_id = nil
if attribute_type == "DIMENSION" then
    object_id = scalar([[
        SELECT OBJECT_ID FROM SYS_SEMANTIC.SEMANTIC_OBJECTS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND UPPER(OBJECT_NAME) = UPPER(:object_name) AND STATUS = 'ACTIVE'
    ]], {model_id = model_id, version_id = version_id, object_name = object_name})
    if object_id == nil then
        error("SEMANTIC_ADMIN_017: semantic object not found: " .. object_name)
    end
end

local table_name = attribute_type == "DIMENSION" and "DIMENSIONS" or "FACTS"
local id_column = attribute_type == "DIMENSION" and "DIMENSION_ID" or "FACT_ID"
local name_column = attribute_type == "DIMENSION" and "DIMENSION_NAME" or "FACT_NAME"
local duplicate = scalar(
    "SELECT COUNT(*) FROM SYS_SEMANTIC." .. table_name
      .. " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id"
      .. " AND UPPER(" .. name_column .. ") = UPPER(:attribute_name)",
    {model_id = model_id, version_id = version_id, attribute_name = attribute_name})
if tonumber(duplicate or 0) > 0 then
    local code = attribute_type == "DIMENSION" and "SEMANTIC_ADMIN_019" or "SEMANTIC_ADMIN_020"
    error(code .. ": duplicate " .. string.lower(attribute_type) .. ": " .. attribute_name)
end
if attribute_type == "DIMENSION" then
    local duplicate_column = scalar([[
        SELECT COUNT(*) FROM SYS_SEMANTIC.OBJECT_COLUMNS
        WHERE OBJECT_ID = :object_id AND UPPER(COLUMN_NAME) = UPPER(:attribute_name)
    ]], {object_id = object_id, attribute_name = attribute_name})
    if tonumber(duplicate_column or 0) > 0 then
        error("SEMANTIC_ADMIN_018: duplicate object column: " .. attribute_name)
    end
end

local representation_rows = query([[
    SELECT REPRESENTATION_ID, REPRESENTATION_NAME, REPRESENTATION_ROLE,
           COVERAGE_PREDICATE
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id})
local primary = nil
local alternates = {}
local partitions = {}
local partitions_by_name = {}
for _, representation_row in ipairs(representation_rows or {}) do
    local representation = {
        id = row_value(representation_row, "REPRESENTATION_ID", 1),
        name = row_value(representation_row, "REPRESENTATION_NAME", 2),
        role = row_value(representation_row, "REPRESENTATION_ROLE", 3),
        coverage_predicate = row_value(representation_row, "COVERAGE_PREDICATE", 4),
    }
    if tostring(representation.role) == "PRIMARY" then
        if primary ~= nil then
            error("SEMANTIC_ADMIN_213: entity has more than one active primary representation")
        end
        primary = representation
    elseif representation.coverage_predicate ~= nil
            and representation.coverage_predicate ~= null
            and trim(representation.coverage_predicate) ~= "" then
        partitions[#partitions + 1] = representation
        partitions_by_name[upper(representation.name)] = representation
    else
        alternates[upper(representation.name)] = representation
    end
end
if primary == nil then
    error("SEMANTIC_ADMIN_213: entity has no active primary representation")
end

-- What a binding object may say, and what to do about a near miss.
--
-- Every refusal below used to be precise about the fault and silent about the
-- vocabulary, and they arrive one per round trip: "representation_name is
-- required" (because `representation` was silently ignored), then "binding_role
-- is required", then the primary rule, then "binding_role must be PREFER or
-- FALLBACK". Five attempts to write one dimension, each one buying a single
-- fact. So the contract is closed like DECLARATIONS_JSON's -- a misspelled key
-- is a refusal, not a silent drop -- every fault in an object is reported
-- together, and the refusal carries the shape and this entity's actual
-- alternate names, so one attempt is enough.
local BINDING_KEYS = {representation_name = true, source_expression = true,
    binding_role = true, binding_priority = true}
local BINDING_KEY_HINTS = {
    representation = "representation_name", name = "representation_name",
    rep = "representation_name", representationname = "representation_name",
    expression = "source_expression", source = "source_expression",
    sourceexpression = "source_expression", expr = "source_expression",
    role = "binding_role", bindingrole = "binding_role",
    priority = "binding_priority", bindingpriority = "binding_priority",
}
local function binding_shape_help()
    local alternate_names = {}
    for _, alternate in pairs(alternates) do
        alternate_names[#alternate_names + 1] = tostring(alternate.name)
    end
    table.sort(alternate_names)
    local help = ' Each binding is {"representation_name": ..., "source_expression":'
        .. ' ..., "binding_role": "PREFER" or "FALLBACK", "binding_priority":'
        .. ' <positive integer>}.'
    if #alternate_names > 0 then
        help = help .. " Alternates to bind: " .. table.concat(alternate_names, ", ") .. "."
    else
        help = help .. " This entity has no active alternate to bind."
    end
    return help .. ' The primary "' .. tostring(primary.name) .. '" takes'
        .. " binding_role and binding_priority only, because EXPRESSION supplies"
        .. " its expression."
end
local function positive_integer_fault(value, label, required_here)
    if value == nil or value == null then
        if required_here then return label .. " is required" end
        return nil
    end
    if type(value) == "table" then return label .. " must be a positive integer" end
    local number = tonumber(value)
    if number == nil or number < 1 or number % 1 ~= 0 then
        return label .. " must be a positive integer"
    end
    return nil
end
-- Every fault in one object, in one refusal.
local function binding_faults(item)
    local faults = {}
    local unknown = {}
    for supplied_key, _ in pairs(item) do
        local key_text = tostring(supplied_key)
        if not BINDING_KEYS[key_text] then unknown[#unknown + 1] = key_text end
    end
    table.sort(unknown)
    for _, key_text in ipairs(unknown) do
        local hint = BINDING_KEY_HINTS[string.lower(string.gsub(key_text, "[_%s]", ""))]
        faults[#faults + 1] = 'unknown key "' .. key_text .. '"'
            .. (hint ~= nil and (' (did you mean "' .. hint .. '"?)') or "")
    end
    local representation_name = item.representation_name
    local binds_primary = false
    if type(representation_name) == "table" or missing(representation_name) then
        faults[#faults + 1] = "representation_name is required"
    else
        binds_primary = upper(representation_name) == upper(primary.name)
    end
    if binds_primary then
        if item.source_expression ~= nil and item.source_expression ~= null then
            faults[#faults + 1] = "source_expression is not accepted for the"
                .. " primary; EXPRESSION supplies it"
        end
    elseif type(item.source_expression) == "table"
            or missing(item.source_expression) then
        faults[#faults + 1] = "source_expression is required"
    end
    if type(item.binding_role) == "table" or missing(item.binding_role) then
        faults[#faults + 1] = "binding_role is required"
    elseif upper(item.binding_role) ~= "PREFER" and upper(item.binding_role) ~= "FALLBACK" then
        faults[#faults + 1] = 'binding_role must be "PREFER" or "FALLBACK", not "'
            .. tostring(item.binding_role) .. '"'
    end
    local priority_fault = positive_integer_fault(
        item.binding_priority, "binding_priority", not binds_primary)
    if priority_fault ~= nil then faults[#faults + 1] = priority_fault end
    return faults
end

local prepared = {}
local primary_role = "PREFER"
local primary_priority = 1
for _, partition in ipairs(partitions) do
    prepared[#prepared + 1] = {
        representation = partition,
        source_expression = expression,
        binding_role = "PREFER",
        binding_priority = 1,
    }
end
local seen = {}
for index, item in ipairs(binding_specs) do
    if type(item) ~= "table" then
        error("SEMANTIC_ADMIN_213: binding " .. tostring(index) .. " must be an object")
    end
    local faults = binding_faults(item)
    if #faults > 0 then
        error("SEMANTIC_ADMIN_213: binding " .. tostring(index) .. " is not usable: "
            .. table.concat(faults, "; ") .. "." .. binding_shape_help())
    end
    local representation_name = trim(item.representation_name)
    if upper(representation_name) == upper(primary.name) then
        -- The primary's *expression* still comes from EXPRESSION -- two places
        -- to write it is two places to disagree. Its *role* is another matter,
        -- and refusing to take one is what made the canonical fusion case
        -- return NULL for every row: surfacing an attribute only a supplemental
        -- source carries forces EXPRESSION to be a CAST(NULL AS ...) placeholder,
        -- and this script pinned that placeholder at PREFER priority 1, which is
        -- what the compiler's candidate sort chooses first. The caller could
        -- describe the shape and not the resolution, so the only reachable
        -- outcome was the wrong one.
        primary_role = upper(item.binding_role)
        if item.binding_priority ~= nil and item.binding_priority ~= null then
            primary_priority = tonumber(item.binding_priority)
        end
        if seen[upper(representation_name)] then
            error("SEMANTIC_ADMIN_213: duplicate binding for representation: "
                .. representation_name)
        end
        seen[upper(representation_name)] = true
    else
        if partitions_by_name[upper(representation_name)] ~= nil then
            error("SEMANTIC_ADMIN_213: binding " .. tostring(index) .. " names the F3"
                .. " partition '" .. representation_name .. "'; EXPRESSION supplies"
                .. " every partition's binding." .. binding_shape_help())
        end
        local representation = alternates[upper(representation_name)]
        if representation == nil then
            error("SEMANTIC_ADMIN_213: binding " .. tostring(index) .. " names '"
                .. representation_name .. "', which is not an active alternate of"
                .. " entity '" .. entity_name .. "'." .. binding_shape_help())
        end
        if seen[upper(representation_name)] then
            error("SEMANTIC_ADMIN_213: duplicate binding for representation: "
                .. representation_name)
        end
        seen[upper(representation_name)] = true
        prepared[#prepared + 1] = {
            representation = representation,
            source_expression = trim(item.source_expression),
            binding_role = upper(item.binding_role),
            binding_priority = tonumber(item.binding_priority),
        }
    end
end
for representation_key, representation in pairs(alternates) do
    if not seen[representation_key] then
        error("SEMANTIC_ADMIN_213: no binding supplied for active alternate '"
            .. tostring(representation.name) .. "'; every active alternate needs"
            .. " one, so the attribute resolves whichever source a query picks."
            .. binding_shape_help())
    end
end

if attribute_type == "DIMENSION" then
    query([[
        INSERT INTO SYS_SEMANTIC.DIMENSIONS (
          MODEL_ID, VERSION_ID, ENTITY_ID, DIMENSION_NAME, EXPRESSION, DATA_TYPE,
          DISPLAY_NAME, DESCRIPTION, FORMAT_HINT, IS_HIDDEN, IS_CERTIFIED, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :attribute_name, :expression, :data_type,
          :display_name, :description, :format_hint, FALSE, :is_certified, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          attribute_name = attribute_name, expression = expression, data_type = data_type,
          display_name = optional_text(DISPLAY_NAME), description = optional_text(DESCRIPTION),
          format_hint = optional_text(FORMAT_HINT),
          is_certified = bool_value(IS_CERTIFIED, false)})
else
    query([[
        INSERT INTO SYS_SEMANTIC.FACTS (
          MODEL_ID, VERSION_ID, ENTITY_ID, FACT_NAME, EXPRESSION, DATA_TYPE,
          ADDITIVE_POLICY, DISPLAY_NAME, DESCRIPTION, IS_PRIVATE, IS_CERTIFIED, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :attribute_name, :expression, :data_type,
          :additive_policy, :display_name, :description, :is_private, :is_certified, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          attribute_name = attribute_name, expression = expression, data_type = data_type,
          additive_policy = additive_policy, display_name = optional_text(DISPLAY_NAME),
          description = optional_text(DESCRIPTION), is_private = bool_value(IS_PRIVATE, false),
          is_certified = bool_value(IS_CERTIFIED, false)})
end
local attribute_id = scalar(
    "SELECT " .. id_column .. " FROM SYS_SEMANTIC." .. table_name
      .. " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id"
      .. " AND UPPER(" .. name_column .. ") = UPPER(:attribute_name)",
    {model_id = model_id, version_id = version_id, attribute_name = attribute_name})
if attribute_type == "DIMENSION" then
    local ordinal = scalar([[
        SELECT COALESCE(MAX(ORDINAL_POSITION), 0) + 1
        FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE OBJECT_ID = :object_id
    ]], {object_id = object_id})
    query([[
        INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS (
          OBJECT_ID, COLUMN_KIND, OBJECT_REF_ID, COLUMN_NAME, ORDINAL_POSITION, IS_VISIBLE
        ) VALUES (
          :object_id, 'DIMENSION', :attribute_id, :attribute_name, :ordinal, TRUE
        )
    ]], {object_id = object_id, attribute_id = attribute_id,
          attribute_name = attribute_name, ordinal = ordinal})
end
query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY,
      IS_DEFAULT, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :attribute_type, :attribute_id,
      :representation_id, :source_expression, :binding_role, :binding_priority,
      TRUE, 'ACTIVE'
    )
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      attribute_type = attribute_type, attribute_id = attribute_id,
      representation_id = primary.id, source_expression = expression,
      binding_role = primary_role, binding_priority = primary_priority})
for _, item in ipairs(prepared) do
    query([[
        INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
          MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
          REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY,
          IS_DEFAULT, STATUS
        ) VALUES (
          :model_id, :version_id, :entity_id, :attribute_type, :attribute_id,
          :representation_id, :source_expression, :binding_role, :binding_priority,
          FALSE, 'ACTIVE'
        )
    ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
          attribute_type = attribute_type, attribute_id = attribute_id,
          representation_id = item.representation.id,
          source_expression = item.source_expression, binding_role = item.binding_role,
          binding_priority = item.binding_priority})
end

local validation_rows = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
    {model_name = model_name})
local validation_error = validation_error_summary(validation_rows)
if validation_error ~= nil then
    if attribute_type == "DIMENSION" then
        query([[
            DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS
            WHERE OBJECT_ID = :object_id AND COLUMN_KIND = 'DIMENSION'
              AND OBJECT_REF_ID = :attribute_id
        ]], {object_id = object_id, attribute_id = attribute_id})
    end
    query([[
        DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
        WHERE ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
    ]], {attribute_type = attribute_type, attribute_id = attribute_id})
    query(
        "DELETE FROM SYS_SEMANTIC." .. table_name .. " WHERE " .. id_column
          .. " = :attribute_id",
        {attribute_id = attribute_id})
    query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
        {model_name = model_name})
    local code = attribute_type == "DIMENSION" and "SEMANTIC_ADMIN_091" or "SEMANTIC_ADMIN_092"
    error(code .. ": " .. string.lower(attribute_type)
        .. " with bindings rejected; validation failed: " .. validation_error)
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
exit({{attribute_id, model_name, entity_name, attribute_type, attribute_name,
    #prepared + 1}}, [[
  ATTRIBUTE_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32), ATTRIBUTE_NAME VARCHAR(256),
  BINDING_COUNT DECIMAL(18,0)
]])
