--- Compiles a Semantic SQL statement and logs it to the query log; returns one row ending in QUERY_LOG_ID.
-- @script SEMANTIC_ADMIN.COMPILE_SQL_DEBUG
-- @param ORIGINAL_SQL Semantic SQL statement to compile.
-- @param CLIENT_NAME Client label stored as CLIENT_NAME in SYS_SEMANTIC.QUERY_LOG.
-- @returns TABLE

import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_sql_debug(ORIGINAL_SQL, CLIENT_NAME)

exit({
    {
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        ORIGINAL_SQL or null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.query_log_id or null,
    }
}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  ORIGINAL_SQL VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  CLARIFICATION_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  QUERY_LOG_ID DECIMAL(18,0)
]])
