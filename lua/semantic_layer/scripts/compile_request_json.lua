--- Compiles a structured JSON semantic request into SQL; returns one 9-column row with status, generated SQL and plan.
-- @script SEMANTIC_ADMIN.COMPILE_REQUEST_JSON
-- @param REQUEST_JSON JSON request object: model, object, and arrays metrics, dimensions, filters, having, order_by, plus options.
-- @returns TABLE

import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_request_json(REQUEST_JSON)

exit({
    {
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.agent_request_id or null,
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
  AGENT_REQUEST_ID DECIMAL(18,0)
]])
