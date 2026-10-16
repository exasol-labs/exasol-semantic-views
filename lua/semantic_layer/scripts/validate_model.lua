import("SEMANTIC_ADMIN.VALIDATOR_RUNTIME", "validator")

local issues = validator.validate_model(MODEL_NAME)
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
