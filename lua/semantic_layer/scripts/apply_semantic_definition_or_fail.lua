--- Applies a Semantic DDL statement like APPLY_SEMANTIC_DEFINITION but raises on refusal; returns one status row.
-- @script SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION_OR_FAIL
-- @param DEFINITION_SQL One ALTER SEMANTIC VIEW statement in an accepted form (REPLACE/ADD OR REPLACE/DROP/RENAME ...).
-- @param DRY_RUN TRUE, 'true', 'TRUE' or '1' validates and then restores the catalog; anything else commits.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_semantic_definition(DEFINITION_SQL, DRY_RUN)
local first = rows ~= nil and rows[1] or nil
if first ~= nil and first[1] == "ERROR" then
    local code = first[2] or "SEMANTIC_DDL_999"
    local message = tostring(first[3] or "Semantic definition apply failed.")
    if string.find(message, code, 1, true) == nil then
        message = code .. ": " .. message
    end
    error(message, 0)
end

exit(rows or {}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000),
  NORMALIZED_JSON VARCHAR(2000000),
  OPERATION_COUNT DECIMAL(18,0),
  VALIDATION_RUN_ID DECIMAL(18,0)
]])
