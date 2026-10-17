--- Explains a past compilation by handle; returns one row with request, generated SQL, plan and governance narrative.
-- @script SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL
-- @param HANDLE_TYPE AGENT_REQUEST (or AGENT_REQUEST_ID, AGENT) or QUERY_LOG (or QUERY_LOG_ID, SQL).
-- @param HANDLE_ID Numeric id of the agent request or query log entry; another principal's handle reports as not found.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.explain_compiled_sql(HANDLE_TYPE, HANDLE_ID)

exit(rows or {}, [[
  HANDLE_TYPE VARCHAR(64),
  HANDLE_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  VERSION_ID DECIMAL(18,0),
  STATUS VARCHAR(64),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  REQUEST_TEXT VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  REQUESTED_DIMENSIONS VARCHAR(2000000),
  REQUESTED_METRICS VARCHAR(2000000),
  SELECTED_MATERIALIZATION VARCHAR(512),
  GOVERNANCE VARCHAR(2000000)
]])
