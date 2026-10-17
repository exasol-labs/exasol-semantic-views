--- Suggests unique keys and relationship key mappings derivable from legacy model metadata; one row per suggestion.
-- @script SEMANTIC_ADMIN.SUGGEST_GRAIN_METADATA
-- @param MODEL_NAME
-- @returns TABLE

import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local rows = compiler.suggest_grain_metadata(MODEL_NAME)

exit(rows or {}, [[
  SUGGESTION_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(512),
  REASON_CODE VARCHAR(128),
  PROPOSED_METADATA_JSON VARCHAR(2000000)
]])
