--- Drops a model like DROP_MODEL, or reports NOT_FOUND when there is none; returns one row.
-- @script SEMANTIC_ADMIN.DROP_MODEL_IF_EXISTS
-- @param MODEL_NAME
-- @returns TABLE

-- A pipeline that rebuilds a model from source starts from a clean slate on
-- every run, the first one included, and DROP_MODEL refuses a model that is not
-- there (SEMANTIC_ADMIN_011). This is the form such a rebuild calls instead of
-- probing first. A separate script rather than a parameter on DROP_MODEL, whose
-- one-argument callers would otherwise all break. Only a missing model is
-- absorbed: every other refusal is DROP_MODEL's own, and raises.
import("SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME", "script_support")
local missing = script_support.ESV_ROWS.missing
local row_value = script_support.ESV_ROWS.row_value

local RESULT_COLUMNS = [[
  MODEL_NAME VARCHAR(256),
  PUBLISHED_SCHEMA VARCHAR(256),
  SCHEMA_DROPPED BOOLEAN,
  STATUS VARCHAR(32)
]]

if missing(MODEL_NAME) then
    error("SEMANTIC_ADMIN_001: MODEL_NAME is required")
end
local model_name = tostring(MODEL_NAME):match("^%s*(.-)%s*$")
local exists = script_support.ESV_ROWS.scalar([[
    SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS WHERE UPPER(MODEL_NAME) = UPPER(:model_name)
]], {model_name = model_name})
if tonumber(exists or 0) == 0 then
    exit({{model_name, null, false, "NOT_FOUND"}}, RESULT_COLUMNS)
end

local dropped = query("EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL(:model_name)",
    {model_name = model_name})[1]
exit({{row_value(dropped, "MODEL_NAME", 1), row_value(dropped, "PUBLISHED_SCHEMA", 2),
    row_value(dropped, "SCHEMA_DROPPED", 3), row_value(dropped, "STATUS", 4)}}, RESULT_COLUMNS)
