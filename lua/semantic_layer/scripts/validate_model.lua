--- Validates a model and records the run; returns one row per issue with severity, rule code and message.
-- @script SEMANTIC_ADMIN.VALIDATE_MODEL
-- @param MODEL_NAME
-- @returns TABLE

import("SEMANTIC_ADMIN.VALIDATOR_RUNTIME", "validator")
-- The compiler decides what type each metric returns, so validation asks it
-- (SEMANTIC_MODEL_076). Imported only when the check runs: it is skipped for a
-- draft model, which should not pay for loading the compiler.
local function metric_result_types(model_name, previous)
    import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")
    return compiler.metric_result_types(model_name, previous)
end

local issues = validator.validate_model(MODEL_NAME, metric_result_types)
local output_rows = {}
local clean = true
for _, issue in ipairs(issues or {}) do
    table.insert(output_rows, {
        issue.severity,
        issue.object_type,
        issue.object_name or null,
        issue.rule_code,
        issue.message,
    })
    if issue.severity == "ERROR" or issue.severity == "PRECONDITION" then
        clean = false
    end
end

-- A frozen view that no longer matches the model is retired here, after the
-- run is recorded, because the check compiles and a compile reads the latest
-- run. Only after a clean one: a run with errors is one a caller is about to
-- roll back, and such a model compiles nothing to compare with. The rows are
-- this call's report, not the run's -- the run judged the catalog, and
-- CHECK_FROZEN_VIEWS reports the views' state for as long as it lasts.
local synced_ok, synced = false, nil
if clean then
    synced_ok, synced = pcall(query,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.SYNC_FROZEN_VIEWS(:model_name)",
        {model_name = MODEL_NAME})
end
for _, row in ipairs(synced_ok and synced or {}) do
    local action = row.OUTCOME or row[3]
    if action == "RETIRED" or action == "FAILED" then
        table.insert(output_rows, {
            "WARNING",
            "FROZEN_VIEW",
            tostring(row.VIEW_SCHEMA or row[1]) .. "." .. tostring(row.VIEW_NAME or row[2]),
            action == "RETIRED" and "SEMANTIC_MODEL_078" or "SEMANTIC_MODEL_079",
            row.DETAIL or row[4],
        })
    end
end

exit(output_rows, [[
  SEVERITY VARCHAR(32),
  OBJECT_TYPE VARCHAR(64),
  OBJECT_NAME VARCHAR(512),
  RULE_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000)
]])
