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
local attribute_type = upper(ATTRIBUTE_TYPE)
local attribute_name = trim(ATTRIBUTE_NAME)
local fusion_strategy = upper(FUSION_STRATEGY)
if attribute_type ~= "DIMENSION" and attribute_type ~= "FACT" then
    error("SEMANTIC_ADMIN_003: ATTRIBUTE_TYPE must be DIMENSION or FACT")
end
if fusion_strategy ~= "PREFER" and fusion_strategy ~= "COALESCE"
    and fusion_strategy ~= "RECONCILE" then
    error("SEMANTIC_ADMIN_003: FUSION_STRATEGY must be PREFER, COALESCE, or RECONCILE")
end
local table_name = attribute_type == "DIMENSION" and "DIMENSIONS" or "FACTS"
local id_column = attribute_type == "DIMENSION" and "DIMENSION_ID" or "FACT_ID"
local name_column = attribute_type == "DIMENSION" and "DIMENSION_NAME" or "FACT_NAME"
local rows = query(
    "SELECT m.MODEL_ID, m.ACTIVE_VERSION_ID, a.ENTITY_ID, a." .. id_column
      .. " FROM SYS_SEMANTIC.MODELS m JOIN SYS_SEMANTIC." .. table_name .. " a"
      .. " ON a.MODEL_ID = m.MODEL_ID AND a.VERSION_ID = m.ACTIVE_VERSION_ID"
      .. " AND UPPER(a." .. name_column .. ") = UPPER(:attribute_name)"
      .. " AND a.STATUS = 'ACTIVE' WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name)",
    {model_name = model_name, attribute_name = attribute_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_021: " .. attribute_type .. " not found: " .. attribute_name)
end
local model_id = row_value(rows[1], "MODEL_ID", 1)
local version_id = row_value(rows[1], "ACTIVE_VERSION_ID", 2)
local entity_id = row_value(rows[1], "ENTITY_ID", 3)
local attribute_id = row_value(rows[1], id_column, 4)
local existing_rows = query([[
    SELECT FUSION_STRATEGY FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
    WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
      AND ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
]], {model_id = model_id, version_id = version_id,
      attribute_type = attribute_type, attribute_id = attribute_id})
local had_row = existing_rows ~= nil and #existing_rows > 0
local previous_strategy = had_row
    and row_value(existing_rows[1], "FUSION_STRATEGY", 1) or nil

-- Prospective on a published model. COALESCE and RECONCILE carry contracts the
-- validator checks -- bindings on at least two representations, exactly one
-- AUTHORITATIVE for RECONCILE -- and a policy that fails them leaves a live
-- published model failing validation, which takes every consumer offline until
-- someone works out which change to undo. Apply, revalidate, restore on error.
local function apply_policy(strategy)
    if strategy == nil then
        query([[
            DELETE FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
              AND ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
        ]], {model_id = model_id, version_id = version_id,
              attribute_type = attribute_type, attribute_id = attribute_id})
    elseif not had_row and strategy == fusion_strategy then
        query([[
            INSERT INTO SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES (
              MODEL_ID, VERSION_ID, ENTITY_ID, ATTRIBUTE_TYPE, ATTRIBUTE_ID,
              FUSION_STRATEGY, STATUS
            ) VALUES (
              :model_id, :version_id, :entity_id, :attribute_type, :attribute_id,
              :fusion_strategy, 'ACTIVE'
            )
        ]], {model_id = model_id, version_id = version_id, entity_id = entity_id,
              attribute_type = attribute_type, attribute_id = attribute_id,
              fusion_strategy = strategy})
    else
        query([[
            UPDATE SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES
            SET FUSION_STRATEGY = :fusion_strategy, STATUS = 'ACTIVE',
                UPDATED_AT = CURRENT_TIMESTAMP, UPDATED_BY = CURRENT_USER
            WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id
              AND ATTRIBUTE_TYPE = :attribute_type AND ATTRIBUTE_ID = :attribute_id
        ]], {model_id = model_id, version_id = version_id,
              attribute_type = attribute_type, attribute_id = attribute_id,
              fusion_strategy = strategy})
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

local recertified = apply_policy(fusion_strategy)
-- A draft is left STALE rather than reverted, for the same reason as every
-- other mutator: compilation is gated on validation status, and reverting would
-- block the repair sequence on a model that is already invalid.
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
    apply_policy(previous_strategy)
    error("SEMANTIC_ADMIN_094: published fusion-policy change rejected and restored; "
        .. "candidate introduced validation error: " .. detail)
end
exit({{model_name, attribute_type, attribute_name, fusion_strategy}}, [[
  MODEL_NAME VARCHAR(256), ATTRIBUTE_TYPE VARCHAR(32),
  ATTRIBUTE_NAME VARCHAR(256), FUSION_STRATEGY VARCHAR(32)
]])
