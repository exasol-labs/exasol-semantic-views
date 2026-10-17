--- Explains a metric's definition, lineage, compatible dimensions and validation status; one row per item.
-- @script SEMANTIC_ADMIN.EXPLAIN_SEMANTIC_METRIC
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic object that exposes the metric. Required.
-- @param METRIC_NAME Metric to explain. Required.
-- @returns TABLE

import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.explain_semantic_metric(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {}, [[
  SECTION_NAME VARCHAR(128),
  ITEM_NAME VARCHAR(256),
  DETAIL_TEXT VARCHAR(2000000)
]])
