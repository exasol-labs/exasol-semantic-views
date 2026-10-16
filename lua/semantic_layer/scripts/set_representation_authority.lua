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
local representation_name = trim(REPRESENTATION_NAME)
local authority_role = upper(AUTHORITY_ROLE)
if model_name == "" or entity_name == "" or representation_name == "" then
    error("SEMANTIC_ADMIN_001: model, entity, and representation names are required")
end
if authority_role ~= "AUTHORITATIVE" and authority_role ~= "PREFER"
    and authority_role ~= "SUPPLEMENTAL" then
    error("SEMANTIC_ADMIN_003: AUTHORITY_ROLE must be AUTHORITATIVE, PREFER, or SUPPLEMENTAL")
end
local rows = query([[
    SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, e.ENTITY_ID, er.REPRESENTATION_ID
    FROM SYS_SEMANTIC.MODELS m
    JOIN SYS_SEMANTIC.ENTITIES e
      ON e.MODEL_ID = m.MODEL_ID AND e.VERSION_ID = m.ACTIVE_VERSION_ID
     AND UPPER(e.ENTITY_NAME) = UPPER(:entity_name) AND e.STATUS = 'ACTIVE'
    JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS er
      ON er.ENTITY_ID = e.ENTITY_ID AND er.MODEL_ID = e.MODEL_ID
     AND er.VERSION_ID = e.VERSION_ID
     AND UPPER(er.REPRESENTATION_NAME) = UPPER(:representation_name)
     AND er.STATUS = 'ACTIVE'
    WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name, entity_name = entity_name,
      representation_name = representation_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_047: active representation not found: " .. representation_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local representation_id = row_value(rows[1], "REPRESENTATION_ID", 4)
local existing_rows = query([[
    SELECT AUTHORITY_ROLE FROM SYS_SEMANTIC.REPRESENTATION_AUTHORITIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND REPRESENTATION_ID = :representation_id
]], {model_id = model_id, version_id = version_id,
      representation_id = representation_id})
local had_row = existing_rows ~= nil and #existing_rows > 0
local previous_role = had_row and row_value(existing_rows[1], "AUTHORITY_ROLE", 1) or nil

-- Prospective on a published model: authority decides which representation wins
-- a reconciliation, so one call can leave a live model failing validation and
-- dark for every consumer. Apply, revalidate, and restore the prior state if
-- the candidate does not hold -- the contract ADD_ENTITY_REPRESENTATION already
-- honours (SEMANTIC_ADMIN_094).
local function apply_authority(role)
    if role == nil then
        query([[
            DELETE FROM SYS_SEMANTIC.REPRESENTATION_AUTHORITIES
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
              AND REPRESENTATION_ID = :representation_id
        ]], {model_id = model_id, version_id = version_id,
              representation_id = representation_id})
    elseif not had_row and role == authority_role then
        query([[
            INSERT INTO SYS_SEMANTIC.REPRESENTATION_AUTHORITIES (
              MODEL_ID, VERSION_ID, ENTITY_ID, REPRESENTATION_ID, AUTHORITY_ROLE, STATUS
            ) VALUES (
              :model_id, :version_id, :entity_id, :representation_id, :authority_role, 'ACTIVE'
            )
        ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
              representation_id = representation_id, authority_role = role})
    else
        query([[
            UPDATE SYS_SEMANTIC.REPRESENTATION_AUTHORITIES
            SET AUTHORITY_ROLE = :authority_role, STATUS = 'ACTIVE',
                UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
              AND REPRESENTATION_ID = :representation_id
        ]], {model_id = model_id, version_id = version_id,
              representation_id = representation_id, authority_role = role})
    end
    query("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE WHERE MODEL_VERSION_ID = :version_id",
        {version_id = version_id})
    query([[
        UPDATE SYS_SEMANTIC.VALIDATION_RUNS SET STATUS = 'STALE'
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
          AND STATUS IN ('OK', 'WARNING')
    ]], {model_id = model_id, version_id = version_id})
    return query("EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)",
        {model_name = model_name})
end

local recertified = apply_authority(authority_role)
-- A draft is left STALE rather than reverted: compilation is gated on
-- validation status, so a stale draft serves nothing, and reverting would block
-- the repair sequence a modeller needs on a model that is already invalid.
local validation_status = "NOT_REQUIRED"
if recertified ~= nil and #recertified > 0 then
    validation_status = tostring(row_value(recertified[1], "VALIDATION_STATUS", 3))
end
if validation_status == "ERROR" or validation_status == "PRECONDITION" then
    local detail_rows = query([[
        SELECT RULE_CODE, MESSAGE
        FROM SYS_SEMANTIC.VALIDATION_RESULTS
        WHERE VALIDATION_RUN_ID = (
            SELECT MAX(VALIDATION_RUN_ID) FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id)
          AND SEVERITY IN ('ERROR', 'PRECONDITION')
        ORDER BY VALIDATION_RESULT_ID
        LIMIT 1
    ]], {model_id = model_id, version_id = version_id})
    local detail = "model validation failed"
    if detail_rows ~= nil and #detail_rows > 0 then
        detail = tostring(row_value(detail_rows[1], "RULE_CODE", 1)) .. " "
            .. tostring(row_value(detail_rows[1], "MESSAGE", 2))
    end
    apply_authority(previous_role)
    error("SEMANTIC_ADMIN_094: published authority change rejected and restored; "
        .. "candidate introduced validation error: " .. detail)
end
exit({{model_name, entity_name, representation_name, authority_role}}, [[
  MODEL_NAME VARCHAR(256), ENTITY_NAME VARCHAR(256),
  REPRESENTATION_NAME VARCHAR(256), AUTHORITY_ROLE VARCHAR(32)
]])
