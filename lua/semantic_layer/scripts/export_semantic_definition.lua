import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.export_semantic_definition(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {}, [[
  DEFINITION_KIND VARCHAR(64),
  DEFINITION_REF VARCHAR(1024),
  DEFINITION_SQL VARCHAR(2000000)
]])
