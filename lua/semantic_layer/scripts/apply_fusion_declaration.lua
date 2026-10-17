--- Applies a fusion declaration document to a model, validating and restoring on failure; returns one status row.
-- @script SEMANTIC_ADMIN.APPLY_FUSION_DECLARATION
-- @param MODEL_NAME
-- @param DECLARATION_JSON JSON {model?, entities: {<entity>: {identity, representations, attribute_bindings, attribute_policies}}}.
-- @param DRY_RUN TRUE or 'TRUE' applies, validates and then restores the catalog; anything else commits.
-- @returns TABLE

import("SEMANTIC_ADMIN.FUSION_RUNTIME", "fusion")

local rows = fusion.apply_fusion_declaration(MODEL_NAME, DECLARATION_JSON, DRY_RUN)

exit(rows or {}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000),
  OPERATION_COUNT DECIMAL(18,0),
  APPLIED_COUNT DECIMAL(18,0)
]])
