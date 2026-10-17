--- Translates a Databricks metric view YAML into Semantic DDL and optionally applies it; returns one status row.
-- @script SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW
-- @param YAML_TEXT Databricks Unity Catalog metric view definition as YAML text.
-- @param MODEL_NAME
-- @param PUBLISHED_SCHEMA Schema for the published views; NULL defaults to SEMANTIC_<MODEL_NAME>.
-- @param APPLY_IMPORT TRUE, 'true', 'TRUE' or '1' applies the translation; anything else only translates.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.import_databricks_metric_view(
    YAML_TEXT,
    MODEL_NAME,
    PUBLISHED_SCHEMA,
    APPLY_IMPORT
)

exit(rows or {}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  MODEL_NAME VARCHAR(256),
  GENERATED_DDL VARCHAR(2000000),
  DIAGNOSTICS_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0)
]])
