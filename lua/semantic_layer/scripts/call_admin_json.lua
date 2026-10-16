-- Call any SEMANTIC_ADMIN script with a JSON object instead of positional
-- arguments.
--
-- Exasol checks parameter arity in the SQL layer, before a script body runs, so
-- a positional mistake can only ever surface as `expected N script parameters
-- but got M` -- no script name, no parameter name, and no way for the script to
-- improve it. Named arguments remove the failure mode instead of describing it:
-- an unknown or missing parameter is reported here, by name, against the
-- signature published in SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS.
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

-- NULL arrives as userdata, and userdata is truthy: `value or ""` would render
-- it as an address and defeat the required-parameter check below.
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
local function upper(value) return string.upper(trim(value)) end
local function row_value(row, name, position)
    if row == nil then return nil end
    return row[name] or row[string.lower(name)] or row[position]
end
local function sql_string(value)
    if value == nil or value == null then return "NULL" end
    return "'" .. string.gsub(tostring(value), "'", "''") .. "'"
end

local script_name = upper(SCRIPT_NAME)
if script_name == "" then
    error("SEMANTIC_ADMIN_001: SCRIPT_NAME is required")
end
if script_name == "CALL_ADMIN_JSON" then
    error("SEMANTIC_ADMIN_100: CALL_ADMIN_JSON cannot call itself")
end

local signature_rows = query([[
    SELECT ORDINAL_POSITION, PARAMETER_NAME, PARAMETER_COUNT, CALL_TEMPLATE
    FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS
    WHERE SCRIPT_NAME = :script_name
    ORDER BY ORDINAL_POSITION
]], {script_name = script_name})
if signature_rows == nil or #signature_rows == 0 then
    error("SEMANTIC_ADMIN_100: unknown admin script: " .. script_name
        .. ". Query SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS for the scripts and "
        .. "their parameters.")
end

local parameters = {}
local known = {}
local call_template = nil
for _, signature_row in ipairs(signature_rows) do
    local parameter_name = row_value(signature_row, "PARAMETER_NAME", 2)
    call_template = call_template or row_value(signature_row, "CALL_TEMPLATE", 4)
    if parameter_name ~= nil and parameter_name ~= null then
        parameters[#parameters + 1] = tostring(parameter_name)
        known[upper(parameter_name)] = true
    end
end

local args = {}
local args_text = trim(ARGS_JSON)
if args_text ~= "" and upper(args_text) ~= "NULL" then
    local ok, decoded = pcall(semantic_definition.decode_json, args_text)
    if not ok or type(decoded) ~= "table" then
        error("SEMANTIC_ADMIN_101: ARGS_JSON must be a JSON object of parameter "
            .. "names for " .. script_name .. ". Expected: " .. tostring(call_template))
    end
    for key, value in pairs(decoded) do
        args[upper(key)] = value
    end
end

local unknown = {}
for key, _ in pairs(args) do
    if not known[key] then unknown[#unknown + 1] = key end
end
if #unknown > 0 then
    table.sort(unknown)
    error("SEMANTIC_ADMIN_101: unknown parameter(s) for " .. script_name .. ": "
        .. table.concat(unknown, ", ") .. ". Expected: " .. tostring(call_template))
end

local call_args = {}
for _, parameter_name in ipairs(parameters) do
    local value = args[upper(parameter_name)]
    if value == nil or value == null then
        call_args[#call_args + 1] = "NULL"
    elseif type(value) == "boolean" then
        call_args[#call_args + 1] = value and "TRUE" or "FALSE"
    elseif type(value) == "number" then
        call_args[#call_args + 1] = tostring(value)
    elseif type(value) == "table" then
        call_args[#call_args + 1] = sql_string(semantic_definition.encode_json(value))
    else
        call_args[#call_args + 1] = sql_string(value)
    end
end

local statement = "EXECUTE SCRIPT SEMANTIC_ADMIN." .. script_name
    .. "(" .. table.concat(call_args, ", ") .. ")"
local rows = query(statement)

local result = {}
for _, result_row in ipairs(rows or {}) do
    local values = {}
    local index = 1
    while result_row[index] ~= nil do
        local value = result_row[index]
        values[index] = (value == null) and null or value
        index = index + 1
    end
    result[#result + 1] = values
end

exit({{"OK", script_name, #result, semantic_definition.encode_json(result), statement}}, [[
  STATUS VARCHAR(32),
  SCRIPT_NAME VARCHAR(128),
  ROW_COUNT DECIMAL(18,0),
  RESULT_JSON VARCHAR(2000000),
  EXECUTED_STATEMENT VARCHAR(2000000)
]])
