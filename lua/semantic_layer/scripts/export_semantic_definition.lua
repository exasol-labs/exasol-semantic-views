--- Exports a model, a semantic view or one metric as canonical Semantic DDL; returns one row per exported definition.
-- @script SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic view to export; NULL exports the whole model (entities, relationships, facts, all views).
-- @param METRIC_NAME A metric name exports that metric alone; ENTITY, RELATIONSHIP, FACT, DIMENSION or METRIC filters by kind.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.export_semantic_definition(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {}, [[
  DEFINITION_KIND VARCHAR(64),
  DEFINITION_REF VARCHAR(1024),
  DEFINITION_SQL VARCHAR(2000000)
]])
