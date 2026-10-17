--- Exports the fusion declaration document for a model or one entity; returns one row with the scope and document JSON.
-- @script SEMANTIC_ADMIN.EXPORT_FUSION_DECLARATION
-- @param MODEL_NAME
-- @param ENTITY_NAME Optional entity to restrict the export to; NULL exports the whole model.
-- @returns TABLE

import("SEMANTIC_ADMIN.FUSION_RUNTIME", "fusion")

local rows = fusion.export_fusion_declaration(MODEL_NAME, ENTITY_NAME)

exit(rows or {}, [[
  SCOPE_KIND VARCHAR(32),
  SCOPE_NAME VARCHAR(256),
  REPRESENTATION_COUNT DECIMAL(18,0),
  DECLARATION_JSON VARCHAR(2000000)
]])
