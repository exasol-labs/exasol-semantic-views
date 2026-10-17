--- Describes a semantic object visible to the caller; returns one row for the object and one per field.
-- @script SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic object to describe; required. A metric or dimension name is refused with a hint.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.describe_semantic_object(MODEL_NAME, OBJECT_NAME)

exit(rows or {}, [[
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  ROW_KIND VARCHAR(64),
  FIELD_KIND VARCHAR(64),
  FIELD_NAME VARCHAR(256),
  SQL_COLUMN_NAME VARCHAR(256),
  DATA_TYPE VARCHAR(128),
  DESCRIPTION VARCHAR(2000000),
  DETAILS_JSON VARCHAR(2000000)
]])
