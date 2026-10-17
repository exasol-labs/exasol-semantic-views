--- Re-validates a model and returns one row per ERROR or PRECONDITION finding absent from the previous validation run.
-- @script SEMANTIC_ADMIN.NEW_VALIDATION_ERRORS
-- @param MODEL_NAME
-- @returns TABLE

-- Revalidate a candidate and report only the errors it *introduced*.
--
-- Every published mutator reverts itself when the candidate model fails
-- validation (SEMANTIC_ADMIN_094). Compared against zero errors, that is a trap
-- rather than a guard: a model carrying two independent errors cannot be
-- repaired, because each single step removes one and leaves the other, so every
-- step is refused and reverted. The model can then be neither published nor
-- fixed, and only DROP_MODEL escapes -- which takes the entities, relationships,
-- published views and grants with it.
--
-- Errors arrive without any admin call at all: drop a column a binding reads and
-- the published model is invalid the next time anyone validates it. So the
-- unrepairable state is reachable by ordinary means, not only by a sequence of
-- rolled-back documents.
--
-- The guard's purpose is to stop a change *introducing* a fault. That is what is
-- measured here: the candidate's errors are compared against the ones the model
-- already had, and only the difference is reported. A change that leaves the
-- model exactly as broken as it was is allowed through, which is what makes a
-- repair sequence possible; a change that breaks something new is still refused.
--
-- The baseline is the most recent validation run recorded for this model
-- version, which for a published model always exists: the active version is set
-- once at CREATE_MODEL and never advances, and publishing requires a successful
-- run. What that run does not promise is being *current*. A steward who has not
-- validated since the model broke has a baseline that predates the fault, so
-- every error reads as new and the change is refused exactly as before. The
-- remedy is VALIDATE_MODEL, and it is only ever one call: the refused mutator
-- revalidates on its way out, so the next attempt has a current baseline.
local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end
-- NULL arrives as userdata, and userdata is truthy.
local model_name = (MODEL_NAME == nil or MODEL_NAME == null) and ""
    or tostring(MODEL_NAME):match("^%s*(.-)%s*$")
if model_name == "" then
    error("SEMANTIC_ADMIN_001: MODEL_NAME is required")
end
local models = query([[
    SELECT MODEL_ID, ACTIVE_VERSION_ID FROM SYS_SEMANTIC.MODELS
    WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if models == nil or #models == 0 then
    error("SEMANTIC_ADMIN_011: model not found: " .. model_name)
end
local model_id = models[1][1]
local version_id = models[1][2]

-- Captured before revalidating, or the new run would be its own baseline.
local baseline = {}
for _, row in ipairs(query([[
    SELECT r.SEVERITY, r.OBJECT_TYPE, r.OBJECT_NAME, r.RULE_CODE
    FROM SYS_SEMANTIC.VALIDATION_RESULTS r
    WHERE r.VALIDATION_RUN_ID = (
        SELECT MAX(VALIDATION_RUN_ID) FROM SYS_SEMANTIC.VALIDATION_RUNS
        WHERE MODEL_ID = :model_id AND VERSION_ID = :version_id)
      AND r.SEVERITY IN ('ERROR', 'PRECONDITION')
]], {model_id = model_id, version_id = version_id}) or {}) do
    -- Keyed on what the finding is *about*, not on its message: several rules
    -- print counts that move while the fault stays the same.
    baseline[table.concat({
        tostring(row_value(row, "SEVERITY", 1)),
        tostring(row_value(row, "OBJECT_TYPE", 2)),
        tostring(row_value(row, "OBJECT_NAME", 3)),
        tostring(row_value(row, "RULE_CODE", 4)),
    }, "\30")] = true
end

local introduced = {}
for _, row in ipairs(query("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL(:model_name)",
        {model_name = model_name}) or {}) do
    local severity = tostring(row_value(row, "SEVERITY", 1))
    if severity == "ERROR" or severity == "PRECONDITION" then
        local key = table.concat({
            severity,
            tostring(row_value(row, "OBJECT_TYPE", 2)),
            tostring(row_value(row, "OBJECT_NAME", 3)),
            tostring(row_value(row, "RULE_CODE", 4)),
        }, "\30")
        if not baseline[key] then
            introduced[#introduced + 1] = {
                severity,
                tostring(row_value(row, "OBJECT_TYPE", 2)),
                tostring(row_value(row, "OBJECT_NAME", 3)),
                tostring(row_value(row, "RULE_CODE", 4)),
                tostring(row_value(row, "MESSAGE", 5)),
            }
        end
    end
end

exit(introduced, [[
  SEVERITY VARCHAR(32), OBJECT_TYPE VARCHAR(64), OBJECT_NAME VARCHAR(512),
  RULE_CODE VARCHAR(128), MESSAGE VARCHAR(2000000)
]])
