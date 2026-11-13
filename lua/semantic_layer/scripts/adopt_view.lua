--- Adopts an aggregate SQL view over one table as a semantic view: its plain columns become dimensions, its aggregates metrics, its table the entity; validates and publishes, and raises on any refusal.
-- @script SEMANTIC_ADMIN.ADOPT_VIEW
-- @param MODEL_NAME Model to adopt into; created, with published schema SEMANTIC_<MODEL_NAME>, when it does not exist.
-- @param VIEW_SCHEMA Schema of the view; matched as written, then in upper case.
-- @param VIEW_NAME The view, which also names the semantic view; matched as written, then in upper case.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.adopt_view(MODEL_NAME, VIEW_SCHEMA, VIEW_NAME)

exit(rows, [[
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  DIMENSIONS DECIMAL(9,0),
  METRICS DECIMAL(9,0),
  STATUS VARCHAR(32),
  DDL VARCHAR(2000000)
]])
