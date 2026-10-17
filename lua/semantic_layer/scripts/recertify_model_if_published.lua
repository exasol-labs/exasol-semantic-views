--- Re-validates a published model and reports the outcome; returns one row with model status and validation status.
-- @script SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED
-- @param MODEL_NAME
-- @returns TABLE

-- NULL arrives as userdata, and userdata is truthy: `MODEL_NAME or ""`
-- would render an address and sail past the check below.
local model_name = (MODEL_NAME == nil or MODEL_NAME == null) and ""
    or tostring(MODEL_NAME):match("^%s*(.-)%s*$")
if model_name == "" then
    error("SEMANTIC_ADMIN_001: MODEL_NAME is required")
end
local rows = query([[
    SELECT STATUS FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if rows == nil or #rows == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end
local model_status = rows[1].STATUS or rows[1].status or rows[1][1]
local validation_status = "NOT_REQUIRED"
if tostring(model_status) == "PUBLISHED" then
    -- NEW_VALIDATION_ERRORS runs the validation and reports only what this
    -- candidate introduced; the run it recorded carries the totals. Callers
    -- revert on ERROR and PRECONDITION, so an error the model already had must
    -- not be spelled either of those, or a repair sequence cannot start --
    -- see the header of NEW_VALIDATION_ERRORS.
    local introduced = query(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.NEW_VALIDATION_ERRORS(:model_name)",
        {model_name = model_name})
    validation_status = "OK"
    local first = (introduced or {})[1]
    if first ~= nil then
        local severity = first.SEVERITY or first.severity or first[1]
        validation_status = tostring(severity)
    end
    if validation_status == "OK" then
        local totals = query([[
            SELECT ERROR_COUNT, WARNING_COUNT FROM SYS_SEMANTIC.VALIDATION_RUNS
            WHERE VALIDATION_RUN_ID = (
                SELECT MAX(r.VALIDATION_RUN_ID) FROM SYS_SEMANTIC.VALIDATION_RUNS r
                JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = r.MODEL_ID
                WHERE UPPER(m.MODEL_NAME) = UPPER(:model_name))
        ]], {model_name = model_name})
        local totals_row = (totals or {})[1]
        if totals_row ~= nil then
            local errors = tonumber(totals_row.ERROR_COUNT or totals_row.error_count
                or totals_row[1]) or 0
            local warnings = tonumber(totals_row.WARNING_COUNT or totals_row.warning_count
                or totals_row[2]) or 0
            if errors > 0 then
                -- Distinct from ERROR on purpose: the model is invalid, and this
                -- change is not why. Reverting it would strand the steward.
                validation_status = "ERROR_PRE_EXISTING"
            elseif warnings > 0 then
                validation_status = "WARNING"
            end
        end
    end
end
exit({{model_name, model_status, validation_status}}, [[
  MODEL_NAME VARCHAR(256), MODEL_STATUS VARCHAR(32), VALIDATION_STATUS VARCHAR(32)
]])
