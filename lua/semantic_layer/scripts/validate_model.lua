--- Validates a model and records the run; returns one row per issue with severity, rule code and message.
-- @script SEMANTIC_ADMIN.VALIDATE_MODEL
-- @param MODEL_NAME
-- @returns TABLE

import("SEMANTIC_ADMIN.VALIDATOR_RUNTIME", "validator")
-- The compiler decides what type each metric returns, so validation asks it
-- (SEMANTIC_MODEL_076). Imported only when the check runs: it is skipped for a
-- draft model, which should not pay for loading the compiler.
local function metric_result_types(model_name)
    import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")
    return compiler.metric_result_types(model_name)
end

local issues = validator.validate_model(MODEL_NAME, metric_result_types)
local output_rows = {}
for _, issue in ipairs(issues or {}) do
    table.insert(output_rows, {
        issue.severity,
        issue.object_type,
        issue.object_name or null,
        issue.rule_code,
        issue.message,
    })
end

exit(output_rows, [[
  SEVERITY VARCHAR(32),
  OBJECT_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(512),
  RULE_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000)
]])
