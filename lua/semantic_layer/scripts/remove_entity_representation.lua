--- Removes a non-primary representation and its bindings, restoring on new validation errors if published; returns one row.
-- @script SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION
-- @param MODEL_NAME
-- @param ENTITY_NAME Entity in the model's active version.
-- @param REPRESENTATION_NAME Active representation to remove; PRIMARY or one with active identity bindings is refused.
-- @returns TABLE

local function missing(value)
    return value == nil or value == null or tostring(value) == ""
end
local function trim(value) return tostring(value):match("^%s*(.-)%s*$") end
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
import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local scalar = script_support.ESV_ROWS.scalar

local model_name = normalize_name(MODEL_NAME, "MODEL_NAME")
local entity_name = normalize_name(ENTITY_NAME, "ENTITY_NAME")
local representation_name = normalize_name(REPRESENTATION_NAME, "REPRESENTATION_NAME")
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, er.REPRESENTATION_ID,
           er.REPRESENTATION_ROLE, m.STATUS
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID
     AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name)
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
    representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_045: active representation not found: " .. representation_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 3)
local model_status = row_value(rows[1], "STATUS", 5)
if tostring(row_value(rows[1], "REPRESENTATION_ROLE", 4)) == "PRIMARY" then
    error("SEMANTIC_ADMIN_047: cannot remove the PRIMARY representation; promote another representation first")
end
local binding_rows = query([[
    SELECT ATTRIBUTE_BINDING_ID FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS
    WHERE REPRESENTATION_ID = :representation_id AND STATUS = 'ACTIVE'
]], {representation_id = representation_id})
for _, binding_row in ipairs(binding_rows or {}) do
    query([[
        UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS SET STATUS = 'INACTIVE'
        WHERE ATTRIBUTE_BINDING_ID = :binding_id
    ]], {binding_id = row_value(binding_row, "ATTRIBUTE_BINDING_ID", 1)})
end
local identity_binding_count = scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.IDENTITY_BINDINGS
    WHERE REPRESENTATION_ID = :representation_id AND STATUS = 'ACTIVE'
]], {representation_id = representation_id})
if tonumber(identity_binding_count or 0) > 0 then
    error("SEMANTIC_ADMIN_057: cannot remove a representation with active identity bindings; remove mapping relations and identity bindings first")
end
local survivor_rows = query([[
    SELECT REPRESENTATION_ID, COVERAGE_PREDICATE, VALID_FROM, VALID_TO
    FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
    WHERE ENTITY_ID = (
      SELECT ENTITY_ID FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS
      WHERE REPRESENTATION_ID = :representation_id
    )
      AND REPRESENTATION_ID <> :representation_id
      AND STATUS = 'ACTIVE'
    ORDER BY REPRESENTATION_ID
]], {representation_id = representation_id})
local survivor = nil
if survivor_rows ~= nil and #survivor_rows == 1 then
    survivor = {
        id = row_value(survivor_rows[1], "REPRESENTATION_ID", 1),
        predicate = row_value(survivor_rows[1], "COVERAGE_PREDICATE", 2) or null,
        valid_from = row_value(survivor_rows[1], "VALID_FROM", 3) or null,
        valid_to = row_value(survivor_rows[1], "VALID_TO", 4) or null,
    }
end
query("UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS SET STATUS = 'INACTIVE' WHERE REPRESENTATION_ID = :representation_id",
    {representation_id = representation_id})
if survivor ~= nil then
    query([[
        UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
        SET COVERAGE_PREDICATE = NULL, VALID_FROM = NULL, VALID_TO = NULL,
            UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
        WHERE REPRESENTATION_ID = :representation_id
    ]], {representation_id = survivor.id})
end
query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
    {version_id = version_id})
query([[
    UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND STATUS IN ('OK', 'WARNING')
]], {model_id = model_id, version_id = version_id})

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
            query("UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS SET STATUS = 'ACTIVE' WHERE REPRESENTATION_ID = :representation_id",
                {representation_id = representation_id})
            for _, binding_row in ipairs(binding_rows or {}) do
                query([[
                    UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS SET STATUS = 'ACTIVE'
                    WHERE ATTRIBUTE_BINDING_ID = :binding_id
                ]], {binding_id = row_value(binding_row, "ATTRIBUTE_BINDING_ID", 1)})
            end
            if survivor ~= nil then
                query([[
                    UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS
                    SET COVERAGE_PREDICATE = :coverage_predicate,
                        VALID_FROM = :valid_from, VALID_TO = :valid_to,
                        UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
                    WHERE REPRESENTATION_ID = :representation_id
                ]], {representation_id = survivor.id,
                      coverage_predicate = survivor.predicate,
                      valid_from = survivor.valid_from,
                      valid_to = survivor.valid_to})
            end
            query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
                {model_name = model_name})
            error("SEMANTIC_ADMIN_094: published representation removal rejected and restored; "
                .. "candidate introduced validation error: "
                .. tostring(rule_code) .. " " .. tostring(message))
        end
    end
end
query("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE REPRESENTATION_ID = :representation_id",
    {representation_id = representation_id})
query("DELETE FROM SYS_SEMANTIC.REPRESENTATION_AUTHORITIES WHERE REPRESENTATION_ID = :representation_id",
    {representation_id = representation_id})
query("DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS WHERE REPRESENTATION_ID = :representation_id",
    {representation_id = representation_id})

exit({{representation_id, model_name, entity_name, representation_name, "REMOVED"}}, [[
  REPRESENTATION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256),
  STATUS VARCHAR(32)
]])
