--- Replaces an existing attribute binding's expression, role and priority, restoring on validation error; returns one row.
-- @script SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING
-- @param MODEL_NAME
-- @param ATTRIBUTE_TYPE DIMENSION or FACT (case-insensitive); required.
-- @param ATTRIBUTE_NAME Dimension or fact whose binding is replaced; required.
-- @param REPRESENTATION_NAME Representation the binding belongs to; required, binding must exist.
-- @param SOURCE_EXPRESSION New SQL expression over that representation; required.
-- @param BINDING_ROLE PREFER or FALLBACK (case-insensitive); required.
-- @param BINDING_PRIORITY Positive integer priority; required.
-- @returns TABLE

local function missing(value)
    return value == nil or value == null or string.match(tostring(value), "^%s*$") ~= nil
end
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
local attribute_type = choice(
    ATTRIBUTE_TYPE, "ATTRIBUTE_TYPE", {DIMENSION = true, FACT = true})
local attribute_name = normalized(ATTRIBUTE_NAME, "ATTRIBUTE_NAME")
local representation_name = normalized(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local source_expression = normalized(SOURCE_EXPRESSION, "SOURCE_EXPRESSION")
local binding_role = choice(
    BINDING_ROLE, "BINDING_ROLE", {PREFER = true, FALLBACK = true})
local priority = tonumber(BINDING_PRIORITY)
if priority == nil or priority < 1 or priority % 1 ~= 0 then
    error("SEMANTIC_ADMIN_001: BINDING_PRIORITY must be a positive integer")
end

local table_name = attribute_type == "DIMENSION" and "DIMENSIONS" or "FACTS"
local id_column = attribute_type == "DIMENSION" and "DIMENSION_ID" or "FACT_ID"
local name_column = attribute_type == "DIMENSION" and "DIMENSION_NAME" or "FACT_NAME"
local binding_rows = query(
    "SELECT ab.ATTRIBUTE_BINDING_ID, ab.MODEL_ID, ab.VERSION_ID, ab.ENTITY_ID,"
      .. " ab.SOURCE_EXPRESSION, ab.BINDING_ROLE, ab.BINDING_PRIORITY, m.STATUS"
      .. " FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS ab"
      .. " JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = ab.MODEL_ID"
      .. " JOIN SYS_SEMANTIC." .. table_name .. " a"
      .. " ON a." .. id_column .. " = ab.ATTRIBUTE_ID"
      .. " JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er"
      .. " ON er.REPRESENTATION_ID = ab.REPRESENTATION_ID"
      .. " WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)"
      .. " AND ab.VERSION_ID = m.ACTIVE_VERSION_ID"
      .. " AND ab.ATTRIBUTE_TYPE = :attribute_type"
      .. " AND UPPER(a." .. name_column .. ") = UPPER(:attribute_name)"
      .. " AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)"
      .. " AND ab.STATUS = 'ACTIVE' AND a.STATUS = 'ACTIVE' AND er.STATUS = 'ACTIVE'",
    {model_name = model_name, attribute_type = attribute_type,
     attribute_name = attribute_name, representation_name = representation_name})
if binding_rows == nil or #binding_rows == 0 then
    error("SEMANTIC_ADMIN_025: attribute binding not found: " .. attribute_name
        .. " -> " .. representation_name .. "; use ADD_ATTRIBUTE_BINDING to create it")
end
local binding_id = row_value(binding_rows[1], "ATTRIBUTE_BINDING_ID", 1)
local model_id = row_value(binding_rows[1], "MODEL_ID", 2)
local version_id = row_value(binding_rows[1], "VERSION_ID", 3)
local previous_expression = row_value(binding_rows[1], "SOURCE_EXPRESSION", 5)
local previous_role = row_value(binding_rows[1], "BINDING_ROLE", 6)
local previous_priority = row_value(binding_rows[1], "BINDING_PRIORITY", 7)

-- A replacement may repair an already-invalid draft. Reject only errors that
-- the candidate introduces, and restore the exact previous binding on failure.
local baseline_validation_rows = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
    {model_name = model_name})
local baseline_errors = validation_error_signatures(baseline_validation_rows)
query([[
    UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
    SET SOURCE_EXPRESSION = :source_expression,
        BINDING_ROLE = :binding_role,
        BINDING_PRIORITY = :priority,
        UPDATED_AT = CURRENT_TIMESTAMP,
        UPDATED_BY = CURRENT_USER
    WHERE ATTRIBUTE_BINDING_ID = :binding_id
]], {source_expression = source_expression, binding_role = binding_role,
      priority = priority, binding_id = binding_id})
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})
local validation_rows = query(
    "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
    {model_name = model_name})
for _, validation_row in ipairs(validation_rows or {}) do
        if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR"
            or tostring(row_value(validation_row, "SEVERITY", 1)) == "PRECONDITION" then
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
            query([[
                UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS
                SET SOURCE_EXPRESSION = :source_expression,
                    BINDING_ROLE = :binding_role,
                    BINDING_PRIORITY = :priority,
                    UPDATED_AT = CURRENT_TIMESTAMP,
                    UPDATED_BY = CURRENT_USER
                WHERE ATTRIBUTE_BINDING_ID = :binding_id
            ]], {source_expression = previous_expression, binding_role = previous_role,
                  priority = previous_priority, binding_id = binding_id})
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_093: attribute binding replacement rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
exit({{binding_id, model_name, attribute_type, attribute_name, representation_name,
    source_expression, binding_role, priority}}, [[
  ATTRIBUTE_BINDING_ID DECIMAL(18,0), MODEL_NAME VARCHAR(256),
  ATTRIBUTE_TYPE VARCHAR(32), ATTRIBUTE_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256), SOURCE_EXPRESSION VARCHAR(2000000),
  BINDING_ROLE VARCHAR(32), BINDING_PRIORITY DECIMAL(18,0)
]])
