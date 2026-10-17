--- Applies a normalized OSI import plan operation by operation; returns one status row per operation plus a validation row.
-- @script SEMANTIC_ADMIN.APPLY_NORMALIZED_OSI_IMPORT
-- @param PLAN_JSON JSON object with an operations array of {operation, target, arguments, source_path}; plus metadata patches.
-- @param VALIDATE_AFTER_APPLY Boolean; when true, validates the model after applying and reports the result in the last row.
-- @param WARNINGS_AS_ERRORS Boolean; passed to the post-apply validation summary to treat warnings as errors.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_normalized_osi_import(
    PLAN_JSON,
    VALIDATE_AFTER_APPLY,
    WARNINGS_AS_ERRORS
)

exit(rows or {}, [[
  STATUS VARCHAR(32),
  OPERATION_INDEX DECIMAL(18,0),
  OPERATION_NAME VARCHAR(128),
  TARGET VARCHAR(512),
  SOURCE_PATH VARCHAR(2000000),
  ROW_COUNT DECIMAL(18,0),
  WARNING_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  MESSAGE VARCHAR(2000000)
]])
