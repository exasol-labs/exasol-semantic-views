-- The record every compile entry point answers with, when it refuses.
--
-- Both the request compiler (request_json.lua) and the Semantic SQL syntax layer
-- (semantic_sql_syntax.lua) return it, so it is defined once, here, rather than
-- in either of them; a second copy would be a second idea of what a refusal
-- carries.

local M = {}

do
    local json = assert(ESV_JSON, "shared JSON runtime is required")

    function M.error(code, message, clarification)
        return {
            status = clarification and "NEEDS_CLARIFICATION" or "ERROR",
            error_code = code,
            error_message = message,
            generated_sql = nil,
            plan_json = nil,
            clarification_json = clarification and json.encode(clarification) or nil,
            validation_run_id = nil,
            agent_request_id = nil,
            query_log_id = nil,
        }
    end
end

ESV_COMPILE_RESULT = M
