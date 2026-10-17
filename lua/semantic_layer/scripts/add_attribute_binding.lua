--- Binds a dimension or fact to an entity representation, refusing bindings that add validation errors; returns one row for the binding.
-- @script SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING
-- @param MODEL_NAME
-- @param ATTRIBUTE_TYPE Kind of attribute to bind: DIMENSION or FACT (case-insensitive). Required.
-- @param ATTRIBUTE_NAME Name of the active dimension or fact to bind. Required.
-- @param REPRESENTATION_NAME Active representation of the attribute's entity to bind to. Required.
-- @param SOURCE_EXPRESSION SQL expression that yields the attribute from this representation. Required.
-- @param BINDING_ROLE Binding role: PREFER or FALLBACK (case-insensitive). Required.
-- @param BINDING_PRIORITY Binding priority; must be a positive integer.
-- @returns TABLE

local function missing(value)
    return value == nil or value == null or string.match(tostring(value), "^%s*$") ~= nil
end
import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local scalar = script_support.ESV_ROWS.scalar
local function normalized(value, label)
    if missing(value) then error("SEMANTIC_ADMIN_001: " .. label .. " is required") end
    return string.match(tostring(value), "^%s*(.-)%s*$")
end
local function choice(value, label, allowed)
    local result = string.upper(normalized(value, label))
    if not allowed[result] then
        error("SEMANTIC_ADMIN_001: unsupported " .. label .. ": " .. tostring(value))
    end
    return result
end
local function row_value(row, name, position)
    return row[name] or row[string.lower(name)] or row[position]
end
local function validation_error_signatures(rows)
    local signatures = {}
    for _, validation_row in ipairs(rows or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
            local signature = table.concat({
                tostring(row_value(validation_row, "OBJECT_TYPE", 2) or ""),
                tostring(row_value(validation_row, "OBJECT_NAME", 3) or ""),
                tostring(row_value(validation_row, "RULE_CODE", 4) or ""),
                tostring(row_value(validation_row, "MESSAGE", 5) or ""),
            }, "\31")
            signatures[signature] = true
        end
    end
    return signatures
end

local model_name = normalized(MODEL_NAME, "MODEL_NAME")
local attribute_type = choice(ATTRIBUTE_TYPE, "ATTRIBUTE_TYPE", {DIMENSION = true, FACT = true})
local attribute_name = normalized(ATTRIBUTE_NAME, "ATTRIBUTE_NAME")
local representation_name = normalized(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local source_expression = normalized(SOURCE_EXPRESSION, "SOURCE_EXPRESSION")
local binding_role = choice(BINDING_ROLE, "BINDING_ROLE", {PREFER = true, FALLBACK = true})
local priority = tonumber(BINDING_PRIORITY)
if priority == nil or priority < 1 or priority % 1 ~= 0 then
    error("SEMANTIC_ADMIN_001: BINDING_PRIORITY must be a positive integer")
end

local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID
    FROM SYS_SEMANTIC.MODELS m
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if rows == nil or #rows == 0 then error("SEMANTIC_ADMIN_011: model not found: " .. model_name) end
local model_id = rows[1][1]
local version_id = rows[1][2]
local table_name = attribute_type == "DIMENSION" and "DIMENSIONS" or "FACTS"
local id_column = attribute_type == "DIMENSION" and "DIMENSION_ID" or "FACT_ID"
local name_column = attribute_type == "DIMENSION" and "DIMENSION_NAME" or "FACT_NAME"
local attribute_rows = query(
    "SELECT " .. id_column .. ", ENTITY_ID FROM SYS_SEMANTIC." .. table_name
      .. " WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id"
      .. " AND UPPER(" .. name_column .. ") = UPPER(:attribute_name) AND STATUS = 'ACTIVE'",
    {model_id = model_id, version_id = version_id, attribute_name = attribute_name})
if attribute_rows == nil or #attribute_rows == 0 then
    error("SEMANTIC_ADMIN_021: " .. attribute_type .. " not found: " .. attribute_name)
end
local attribute_id = attribute_rows[1][1]
local entity_id = attribute_rows[1][2]
local representation_id = scalar([[
    SELECT REPRESENTATION_ID
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ENTITY_ID = :entity_id
      AND UPPER(REPRESENTATION_NAME) = UPPER(:representation_name)
      AND STATUS = 'ACTIVE'
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      representation_name = representation_name})
if representation_id == nil then
    error("SEMANTIC_ADMIN_015: representation not found for attribute entity: " .. representation_name)
end
local duplicate = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
    WHERE ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
      AND REPRESENTATION_ID = :representation_id AND STATUS = 'ACTIVE'
]], {attribute_type = attribute_type, attribute_id = attribute_id,
      representation_id = representation_id})
if tonumber(duplicate or 0) > 0 then
    error("SEMANTIC_ADMIN_024: duplicate attribute binding: " .. attribute_name
        .. " -> " .. representation_name
        .. "; use REPLACE_ATTRIBUTE_BINDING to update it, or remove the existing binding first")
end

-- Binding authoring is a repair operation: an alternate with renamed columns
-- can be invalid until all of its bindings exist. Preserve the pre-application
-- errors and reject only errors introduced by this candidate binding.
local baseline_validation_rows = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
    {model_name = model_name})
local baseline_errors = validation_error_signatures(baseline_validation_rows)

query([[
    INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS (
      MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
      REPRESENTATION_ID, SOURCE_EXPRESSION, BINDING_ROLE, BINDING_PRIORITY, STATUS
    ) VALUES (
      :model_id, :version_id, :entity_id, :attribute_type, :attribute_id,
      :representation_id, :source_expression, :binding_role, :priority, 'ACTIVE'
    )
]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
      attribute_type = attribute_type, attribute_id = attribute_id,
      representation_id = representation_id, source_expression = source_expression,
      binding_role = binding_role, priority = priority})
local binding_id = scalar([[
    SELECT ATTRIBUTE_BINDING_ID FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
    WHERE ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
      AND REPRESENTATION_ID = :representation_id AND STATUS = 'ACTIVE'
]], {attribute_type = attribute_type, attribute_id = attribute_id,
      representation_id = representation_id})
local validation_rows = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
    {model_name = model_name})
for _, validation_row in ipairs(validation_rows or {}) do
    local severity = row_value(validation_row, "SEVERITY", 1)
    if tostring(severity) == "ERROR" or tostring(severity) == "PRECONDITION" then
        local signature = table.concat({
            tostring(row_value(validation_row, "OBJECT_TYPE", 2) or ""),
            tostring(row_value(validation_row, "OBJECT_NAME", 3) or ""),
            tostring(row_value(validation_row, "RULE_CODE", 4) or ""),
            tostring(row_value(validation_row, "MESSAGE", 5) or ""),
        }, "\31")
        if not baseline_errors[signature] then
            local rule_code = row_value(validation_row, "RULE_CODE", 4)
                or "SEMANTIC_MODEL_ERROR"
            local message = row_value(validation_row, "MESSAGE", 5)
                or "model validation failed"
            query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE ATTRIBUTE_BINDING_ID = :binding_id",
                {binding_id = binding_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_093: attribute binding rejected; candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
exit({{binding_id, model_name, attribute_type, attribute_name, representation_name,
    binding_role, priority}}, [[
  ATTRIBUTE_BINDING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32), ATTRIBUTE_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256), BINDING_ROLE VARCHAR(32),
  BINDING_PRIORITY DECIMAL(18,0)
]])
