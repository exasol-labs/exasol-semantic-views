--- Builds a glossary of a visible semantic object's fields and agent instructions; returns one row with text and JSON.
-- @script SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic object to describe. Required; must be visible in OBJECTS_FOR_AGENT.
-- @param QUERY_MODE STRUCTURED_REQUEST or SEMANTIC_SQL (case-insensitive); NULL defaults to STRUCTURED_REQUEST.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.get_business_glossary(MODEL_NAME, OBJECT_NAME, QUERY_MODE)

exit(rows or {}, [[
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  QUERY_MODE VARCHAR(64),
  GLOSSARY_TEXT VARCHAR(2000000),
  GLOSSARY_JSON VARCHAR(2000000)
]])
