--- Searches fields and objects visible to the caller by name and description; returns one scored row per match.
-- @script SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS
-- @param QUERY_TEXT Search text; its longest non-stop-word token is matched. Empty matches everything.
-- @param MODEL_NAME Optional model filter; NULL searches all visible models.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.search_semantic_objects(QUERY_TEXT, MODEL_NAME)

exit(rows or {}, [[
  RESULT_TYPE VARCHAR(64),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  FIELD_KIND VARCHAR(64),
  FIELD_NAME VARCHAR(256),
  DISPLAY_NAME VARCHAR(512),
  DESCRIPTION VARCHAR(2000000),
  MATCH_TEXT VARCHAR(2000000),
  SCORE DECIMAL(18,0),
  IS_CERTIFIED BOOLEAN
]])
