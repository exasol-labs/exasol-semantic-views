--- Applies a fusion declaration document like APPLY_FUSION_DECLARATION but raises on refusal; returns one status row.
-- @script SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION_OR_FAIL
-- @param MODEL_NAME
-- @param DECLARATION_JSON JSON {model?, entities: {<entity>: {identity, representations, attribute_bindings, attribute_policies}}}.
-- @param DRY_RUN TRUE or 'TRUE' applies, validates and then restores the catalog; anything else commits.
-- @returns TABLE

-- APPLY_FUSION_DECLARATION reports a refusal in STATUS, and an orchestrator
-- such as dbt counts a statement that returned rows as one that succeeded: a
-- refused document left the run green over a model that was never fused. This
-- raises instead, after the catalog has been restored, so the statement fails.
import("SEMANTIC_ADMIN.FUSION_RUNTIME", "fusion")

local rows = fusion.apply_fusion_declaration(MODEL_NAME, DECLARATION_JSON, DRY_RUN)
local first = rows ~= nil and rows[1] or nil
if first ~= nil and first[1] == "ERROR" then
    local code = first[2] or "SEMANTIC_FUSION_090"
    local message = tostring(first[3] or "Fusion declaration apply failed.")
    if string.find(message, code, 1, true) == nil then
        message = code .. ": " .. message
    end
    error(message, 0)
end

exit(rows or {}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000),
  OPERATION_COUNT DECIMAL(18,0),
  APPLIED_COUNT DECIMAL(18,0)
]])
