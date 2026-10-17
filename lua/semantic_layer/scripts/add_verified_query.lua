--- Compiles a request and stores it as a verified query on a semantic view; returns one row with its id and generated SQL.
-- @script SEMANTIC_ADMIN.ADD_VERIFIED_QUERY
-- @param MODEL_NAME
-- @param OBJECT_NAME Semantic view the query belongs to.
-- @param QUERY_NAME Required name of the verified query.
-- @param NATURAL_LANGUAGE_TEXT Required natural-language question the query answers.
-- @param REQUEST_JSON Required compile request object; model/object are added if absent and must match parameters 1 and 2.
-- @param EXPECTED_RESULT_SHAPE Optional free-text description of the expected result; NULL stores none.
-- @param IS_ONBOARDING_EXAMPLE Boolean ('true', '1' or 'yes' mean true); NULL means FALSE.
-- @returns TABLE

import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.add_verified_query(
    MODEL_NAME,
    OBJECT_NAME,
    QUERY_NAME,
    NATURAL_LANGUAGE_TEXT,
    REQUEST_JSON,
    EXPECTED_RESULT_SHAPE,
    IS_ONBOARDING_EXAMPLE
)

exit(rows or {}, [[
  VERIFIED_QUERY_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  QUERY_NAME VARCHAR(512),
  STATUS VARCHAR(32),
  GENERATED_SQL VARCHAR(2000000)
]])
