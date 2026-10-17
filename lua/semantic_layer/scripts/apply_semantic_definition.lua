--- Applies an ALTER SEMANTIC VIEW definition and validates, restoring on failure; returns one status row.
-- @script SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION
-- @param DEFINITION_SQL Semantic DDL text (ALTER SEMANTIC VIEW with REPLACE/ADD OR REPLACE/DROP/RENAME forms).
-- @param DRY_RUN TRUE, 'true' or '1' parses and validates, then restores the catalog; anything else, including NULL, applies.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_semantic_definition(DEFINITION_SQL, DRY_RUN)

exit(rows or {}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000),
  NORMALIZED_JSON VARCHAR(2000000),
  OPERATION_COUNT DECIMAL(18,0),
  VALIDATION_RUN_ID DECIMAL(18,0)
]])
