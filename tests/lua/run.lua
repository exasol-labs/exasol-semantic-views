-- Minimal database-free test runner and coverage collector for the Exasol Lua
-- runtime. It intentionally has no LuaRocks dependencies.

local script_path = arg[0]:gsub("\\", "/")
local repo_root = script_path:gsub("/tests/lua/run%.lua$", "")
if repo_root == script_path then repo_root = "." end

ESV_TEST_MODE = true
null = setmetatable({}, {__tostring = function() return "null" end})

local tests = {}
local branch_outcomes = {}
local executed = {}
local possible = {}
local module_roots = {}

local function normalize_source(source)
    source = tostring(source or ""):gsub("^@", ""):gsub("\\", "/")
    local marker = "/lua/semantic_layer/"
    local at = source:find(marker, 1, true)
    if at then return source:sub(at + 1) end
    if source:sub(1, 19) == "lua/semantic_layer/" then return source end
    return nil
end

debug.sethook(function(_, line)
    local source = normalize_source(debug.getinfo(2, "S").source)
    if source then
        executed[source] = executed[source] or {}
        executed[source][line] = true
    end
end, "l")

local function load_runtime(relative_path, roots)
    local full_path = repo_root .. "/" .. relative_path
    local chunk, err = loadfile(full_path, "t", _G)
    if not chunk then error(err) end
    chunk()
    module_roots[relative_path] = roots()
end

load_runtime("lua/semantic_layer/compiler/request_json.lua", function()
    return {compile_request_json, compile_sql, compile_sql_debug,
        compile_sql_for_preprocessor, ESV_COMPILER_TEST_API}
end)
load_runtime("lua/semantic_layer/admin/validator.lua", function()
    return {validate_model, ESV_VALIDATOR_TEST_API}
end)
load_runtime("lua/semantic_layer/compiler/materializations.lua", function()
    return {select_materialization, ESV_MATERIALIZATION_TEST_API}
end)
load_runtime("lua/semantic_layer/admin/semantic_definition.lua", function()
    return {apply_semantic_definition, apply_normalized_osi_import,
        import_databricks_metric_view, describe_semantic_metric,
        explain_semantic_metric, export_semantic_definition, preprocess_sql,
        ESV_SEMANTIC_DEFINITION_TEST_API}
end)
load_runtime("lua/semantic_layer/agent/runtime.lua", function()
    return {add_agent_instruction, add_verified_query, search_semantic_objects,
        describe_semantic_object, get_business_glossary, explain_compiled_sql,
        record_agent_feedback, ESV_AGENT_TEST_API}
end)

local seen_functions = {}
local function collect_function(fn)
    if type(fn) ~= "function" or seen_functions[fn] then return end
    seen_functions[fn] = true
    local info = debug.getinfo(fn, "SL")
    local source = info and normalize_source(info.source)
    if source and info.activelines then
        possible[source] = possible[source] or {}
        for line, _ in pairs(info.activelines) do possible[source][line] = true end
    end
    local index = 1
    while true do
        local _, value = debug.getupvalue(fn, index)
        if not _ then break end
        if type(value) == "function" then collect_function(value) end
        index = index + 1
    end
end

local function collect_roots(value, seen_tables)
    if type(value) == "function" then
        collect_function(value)
    elseif type(value) == "table" and not seen_tables[value] then
        seen_tables[value] = true
        for _, child in pairs(value) do collect_roots(child, seen_tables) end
    end
end
for _, roots in pairs(module_roots) do collect_roots(roots, {}) end

function test(name, fn)
    tests[#tests + 1] = {name = name, fn = fn}
end

local function render(value)
    if type(value) ~= "table" then return tostring(value) end
    local parts = {}
    for key, child in pairs(value) do parts[#parts + 1] = tostring(key) .. "=" .. render(child) end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

function assert_equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. render(expected)
            .. ", got " .. render(actual), 2)
    end
end

function assert_true(value, message)
    if not value then error(message or "expected truthy value", 2) end
end

function assert_contains(text, fragment, message)
    if not tostring(text):find(tostring(fragment), 1, true) then
        error((message or "text does not contain fragment") .. ": " .. tostring(fragment), 2)
    end
end

function assert_error(fn, fragment)
    local ok, err = pcall(fn)
    if ok then error("expected an error", 2) end
    if fragment then assert_contains(err, fragment) end
end

-- Decision coverage is explicit: every named decision is expected to be tested
-- with both true and false outcomes. assert_branch couples recording to the
-- assertion, so a passing test cannot record an outcome it did not observe.
function assert_branch(name, actual, expected)
    local normalized = not not actual
    branch_outcomes[name] = branch_outcomes[name] or {}
    branch_outcomes[name][normalized] = true
    assert_equal(normalized, not not expected, "branch " .. name)
end

local specs = {
    "tests/lua/compiler_unit_test.lua",
    "tests/lua/validator_unit_test.lua",
    "tests/lua/materialization_unit_test.lua",
    "tests/lua/semantic_definition_unit_test.lua",
    "tests/lua/agent_unit_test.lua",
}
for _, spec in ipairs(specs) do dofile(repo_root .. "/" .. spec) end

local failures = 0
for _, case in ipairs(tests) do
    local ok, err = xpcall(case.fn, debug.traceback)
    if ok then
        io.write("PASS ", case.name, "\n")
    else
        failures = failures + 1
        io.write("FAIL ", case.name, "\n", err, "\n")
    end
end
debug.sethook()

local thresholds = dofile(repo_root .. "/tests/lua/coverage_thresholds.lua")
local coverage_failures = 0
io.write("\nLua runtime line coverage\n")
for source, threshold in pairs(thresholds.lines) do
    local active, hit = 0, 0
    for line, _ in pairs(possible[source] or {}) do
        active = active + 1
        if executed[source] and executed[source][line] then hit = hit + 1 end
    end
    local percentage = active == 0 and 0 or (hit * 100 / active)
    io.write(string.format("  %-62s %4d/%-4d %6.2f%% (minimum %.2f%%)\n",
        source, hit, active, percentage, threshold))
    if percentage + 0.0001 < threshold then coverage_failures = coverage_failures + 1 end
end

local branch_total, branch_hit = 0, 0
for _, outcomes in pairs(branch_outcomes) do
    branch_total = branch_total + 2
    if outcomes[true] then branch_hit = branch_hit + 1 end
    if outcomes[false] then branch_hit = branch_hit + 1 end
end
local branch_percentage = branch_total == 0 and 0 or branch_hit * 100 / branch_total
io.write(string.format("\nDecision outcome coverage: %d/%d %.2f%% (minimum %.2f%%)\n",
    branch_hit, branch_total, branch_percentage, thresholds.branches))
if branch_percentage + 0.0001 < thresholds.branches then
    coverage_failures = coverage_failures + 1
end

io.write(string.format("\n%d tests, %d test failures, %d coverage failures\n",
    #tests, failures, coverage_failures))
if failures > 0 or coverage_failures > 0 then os.exit(1) end
