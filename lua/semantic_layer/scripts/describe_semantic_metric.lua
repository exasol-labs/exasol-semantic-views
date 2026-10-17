--- Describes a metric's identity, meaning, computation, governance and presentation; one row per property.
-- @script SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_METRIC
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic object that exposes the metric. Required.
-- @param METRIC_NAME Metric to describe. Required.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.describe_semantic_metric(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {}, [[
  SECTION_NAME VARCHAR(128),
  PROPERTY_NAME VARCHAR(256),
  PROPERTY_VALUE VARCHAR(2000000)
]])
