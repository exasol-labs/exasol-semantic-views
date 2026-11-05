-- Shared, strict Exasol stand-ins for the selected installed script bodies.
local M = {}
local root = (arg[0]:gsub("\\", "/")):gsub("/?tests/lua/run%.lua$", "")
if root == "" then root = "." end

local function same(actual, expected, path)
    if actual == null or expected == null then
        assert_equal(actual, expected, path)
        return
    end
    if type(actual) ~= type(expected) then
        error(path .. ": expected " .. type(expected) .. ", got " .. type(actual), 0)
    end
    if type(expected) ~= "table" then
        assert_equal(actual, expected, path)
        return
    end
    for key, value in pairs(expected) do same(actual[key], value, path .. "." .. tostring(key)) end
    for key in pairs(actual) do
        if expected[key] == nil then error(path .. ": unexpected key " .. tostring(key), 0) end
    end
end
M.same = same

local function parameters(path)
    local names = {}
    for line in io.lines(path) do
        local name = line:match("^%-%- @param ([A-Z][A-Z0-9_]*)")
        if name then names[name] = true end
    end
    return names
end

local function run(name, supplied, fixture)
    fixture = fixture or {}
    supplied = supplied or {}
    local path = root .. "/lua/semantic_layer/scripts/" .. name .. ".lua"
    local declared = parameters(path)
    for supplied_name in pairs(supplied) do
        assert_true(declared[supplied_name], "undeclared script parameter " .. supplied_name)
    end
    local env = setmetatable({null = null}, {__index = _G})
    env._G = env
    for param in pairs(declared) do env[param] = supplied[param] == nil and null or supplied[param] end

    local calls, step_index, imports = {}, 0, fixture.imports or {}
    local exit_marker = {}
    local result = {calls = calls, imports = {}, sql_text = nil}
    env.query = function(sql, bindings)
        step_index = step_index + 1
        local step = (fixture.sql or {})[step_index]
        assert_true(step ~= nil, "unexpected query #" .. step_index .. ": " .. tostring(sql))
        if step.sql then assert_equal(sql, step.sql, "SQL call #" .. step_index) end
        if step.contains then assert_contains(sql, step.contains, "SQL call #" .. step_index) end
        if step.bindings then same(bindings, step.bindings, "bindings #" .. step_index) end
        calls[#calls + 1] = {sql = sql, bindings = bindings}
        if step.error then error(step.error, 0) end
        return step.rows or {}
    end
    local function import_script(script, alias)
        local implementation = imports[script]
        assert_true(implementation ~= nil, "unexpected import " .. tostring(script))
        result.imports[#result.imports + 1] = {script, alias}
        if implementation == false then error("import denied: " .. script, 0) end
        if type(implementation) == "function" then implementation = implementation(env) end
        env[alias] = implementation
    end
    env.import = import_script
    env.exa = {import = import_script}
    env.exit = function(rows, columns)
        result.rows, result.columns = rows, columns
        error(exit_marker, 0)
    end
    if fixture.sql_text ~= nil then
        env.sqlparsing = {
            getsqltext = function() return fixture.sql_text end,
            setsqltext = function(value) result.sql_text = value end,
        }
    end
    local chunk, load_error = loadfile(path, "t", env)
    assert_true(chunk ~= nil, load_error)
    local ok, err = pcall(function()
        chunk()
        if name == "semantic_guard" or name == "frozen_view_guard" then env.run({}) end
    end)
    if not ok and err ~= exit_marker then result.error = tostring(err) end
    if fixture.error then
        assert_contains(result.error or "", fixture.error)
    else
        assert_true(result.error == nil, result.error)
    end
    assert_equal(step_index, #(fixture.sql or {}), "number of SQL calls")
    return result
end

function M.for_script(name)
    local function run_script(supplied, fixture)
        return run(name, supplied, fixture)
    end
    local function test_script(description, fn)
        test(string.upper(name) .. ": " .. description, fn)
    end
    local function delegate(runtime, method, supplied, rows)
        local expected = {}
        local path = root .. "/lua/semantic_layer/scripts/" .. name .. ".lua"
        for line in io.lines(path) do
            local param = line:match("^%-%- @param ([A-Z][A-Z0-9_]*)")
            if param then
                local value = supplied and supplied[param]
                expected[#expected + 1] = value == nil and null or value
            end
        end
        return {imports = {[runtime] = {[method] = function(...)
            assert_equal(select("#", ...), #expected, "delegated argument count")
            for index = 1, #expected do
                same(select(index, ...), expected[index], "delegated argument " .. index)
            end
            return rows or {{"DELEGATED"}}
        end}}}
    end
    return run_script, test_script, delegate
end

function M.support(env)
    return {
        ESV_ROWS = {scalar = function(sql, bindings)
            local rows = env.query(sql, bindings)
            if not rows or not rows[1] then return nil end
            local row = rows[1]
            return row.VALUE or row.COUNT or row.MAX or row[1]
        end, missing = ESV_ROWS.missing, row_value = ESV_ROWS.row_value},
        ESV_SOURCE_COLUMNS = {require_relation = function(_, schema, object)
            return schema, object
        end},
    }
end

function M.step(contains, rows, bindings)
    return {contains = contains, rows = rows, bindings = bindings}
end

function M.supported(sql)
    return {sql = sql or {}, imports = {
        ["SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"] = M.support,
    }}
end

function M.refusal(expected, imported)
    local fixture = {error = expected, imports = {}}
    for _, script in ipairs(imported or {}) do
        fixture.imports[script] = script == "SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"
            and M.support or {}
    end
    return fixture
end

return M
