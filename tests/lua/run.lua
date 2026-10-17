-- Minimal database-free test runner and coverage collector for the Exasol Lua
-- runtime. It intentionally has no LuaRocks dependencies; see README.md for
-- what it provides and why it is not busted.
--
--   lua tests/lua/run.lua [name-substring]
--   ESV_TEST_SEED=<n>    reproduce a shuffled order; =none keeps file order

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

load_runtime("lua/semantic_layer/shared/json.lua", function()
    return {ESV_JSON}
end)
load_runtime("lua/semantic_layer/shared/rows.lua", function()
    return {ESV_ROWS}
end)
load_runtime("lua/semantic_layer/shared/sql_text.lua", function()
    return {ESV_SQL_TEXT}
end)
load_runtime("lua/semantic_layer/shared/catalog_rollback.lua", function()
    return {ESV_CATALOG_ROLLBACK}
end)
load_runtime("lua/semantic_layer/shared/grain_graph.lua", function()
    return {ESV_GRAIN_GRAPH}
end)
load_runtime("lua/semantic_layer/shared/source_columns.lua", function()
    return {ESV_SOURCE_COLUMNS}
end)
load_runtime("lua/semantic_layer/shared/identity_join.lua", function()
    return {ESV_IDENTITY_JOIN}
end)
load_runtime("lua/semantic_layer/compiler/query_spec.lua", function()
    return {ESV_QUERY_SPEC}
end)
load_runtime("lua/semantic_layer/compiler/catalog_snapshot.lua", function()
    return {ESV_CATALOG_SNAPSHOT}
end)
load_runtime("lua/semantic_layer/compiler/metric_plan.lua", function()
    return {ESV_METRIC_PLAN}
end)
load_runtime("lua/semantic_layer/compiler/physical_plan.lua", function()
    return {ESV_PHYSICAL_PLAN}
end)
load_runtime("lua/semantic_layer/compiler/grain_sql.lua", function()
    return {ESV_GRAIN_SQL}
end)
load_runtime("lua/semantic_layer/compiler/compile_result.lua", function()
    return {ESV_COMPILE_RESULT}
end)
load_runtime("lua/semantic_layer/compiler/semantic_sql_syntax.lua", function()
    return {ESV_SEMANTIC_SQL_SYNTAX}
end)
load_runtime("lua/semantic_layer/compiler/request_json.lua", function()
    return {compile_request_json, compile_sql, compile_sql_debug,
        compile_sql_for_preprocessor, suggest_grain_metadata,
        ESV_COMPILER_TEST_API}
end)
load_runtime("lua/semantic_layer/admin/validator.lua", function()
    return {validate_model, ESV_VALIDATOR_TEST_API}
end)
load_runtime("lua/semantic_layer/compiler/materializations.lua", function()
    return {select_materialization, ESV_MATERIALIZATION_TEST_API}
end)
load_runtime("lua/semantic_layer/admin/databricks_import.lua", function()
    return {ESV_DATABRICKS_IMPORT}
end)
load_runtime("lua/semantic_layer/admin/semantic_definition.lua", function()
    return {apply_semantic_definition, apply_normalized_osi_import,
        import_databricks_metric_view, describe_semantic_metric,
        explain_semantic_metric, export_semantic_definition, preprocess_sql,
        ESV_SEMANTIC_DEFINITION_TEST_API}
end)
load_runtime("lua/semantic_layer/admin/fusion_declaration.lua", function()
    return {export_fusion_declaration, export_document_json,
        apply_fusion_declaration, ESV_FUSION_DECLARATION_TEST_API}
end)
load_runtime("lua/semantic_layer/agent/runtime.lua", function()
    return {add_agent_instruction, add_verified_query, search_semantic_objects,
        describe_semantic_object, get_business_glossary, explain_compiled_sql,
        record_agent_feedback, propose_model_evolution, review_model_evolution,
        ESV_AGENT_TEST_API}
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

-- Run fn(case, index) for every case, naming the case a failure came from.
-- A loop of assertions otherwise reports only that something in the list
-- failed, and the list has to be bisected by hand.
function each(cases, fn)
    for index, case in ipairs(cases) do
        local ok, err = pcall(fn, case, index)
        if not ok then
            local label = render(case)
            if #label > 240 then label = label:sub(1, 240) .. "..." end
            error(string.format("case %d of %d (%s): %s", index, #cases, label, tostring(err)), 0)
        end
    end
end

-- Register cleanup to run after the current test, even if it fails; the
-- latest registered runs first. For setup a test cannot wrap in a function.
local deferred = {}
function defer(fn)
    deferred[#deferred + 1] = fn
end

-- Exasol's query() global, replaced by a fixture for the duration of fn.
-- Restored even when fn fails, so one failing test cannot leave its mock
-- installed for the next.
function with_query(mock, fn)
    local original = query
    query = mock
    local result = table.pack(xpcall(fn, debug.traceback))
    query = original
    if not result[1] then error(result[2], 0) end
    return table.unpack(result, 2, result.n)
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
    "tests/lua/json_unit_test.lua",
    "tests/lua/rows_unit_test.lua",
    "tests/lua/sql_text_unit_test.lua",
    "tests/lua/grain_graph_unit_test.lua",
    "tests/lua/grain_planner_unit_test.lua",
    "tests/lua/compiler_unit_test.lua",
    "tests/lua/validator_unit_test.lua",
    "tests/lua/materialization_unit_test.lua",
    "tests/lua/semantic_definition_unit_test.lua",
    "tests/lua/fusion_declaration_unit_test.lua",
    "tests/lua/agent_unit_test.lua",
}
for _, spec in ipairs(specs) do dofile(repo_root .. "/" .. spec) end

local filter = arg[1] or os.getenv("ESV_TEST_FILTER")
if filter then
    local selected = {}
    for _, case in ipairs(tests) do
        if case.name:find(filter, 1, true) then selected[#selected + 1] = case end
    end
    tests = selected
end

-- Shuffled by default, so a test that depends on another having run first
-- fails here rather than when someone reorders a file. The seed is printed;
-- ESV_TEST_SEED reproduces the order.
local seed = os.getenv("ESV_TEST_SEED") or "random"
if seed ~= "none" then
    seed = seed == "random" and os.time() or assert(tonumber(seed), "ESV_TEST_SEED must be a number")
    math.randomseed(seed)
    for index = #tests, 2, -1 do
        local other = math.random(index)
        tests[index], tests[other] = tests[other], tests[index]
    end
    io.write("shuffled with ESV_TEST_SEED=", seed, "\n")
end

-- A test must leave the globals as it found them: a mock left installed, or a
-- global set and not cleared, otherwise passes here and changes what every
-- later test sees. The difference fails the test that made it, and is undone.
local function snapshot()
    local copy = {}
    for key, value in pairs(_G) do copy[key] = value end
    return copy
end

local function leaked(before)
    local names = {}
    for key, value in pairs(_G) do
        if before[key] ~= value then names[#names + 1] = tostring(key) end
    end
    for key, _ in pairs(before) do
        if rawget(_G, key) == nil then names[#names + 1] = tostring(key) end
    end
    table.sort(names)
    for _, key in ipairs(names) do rawset(_G, key, before[key]) end
    return names
end

local failures = 0
for _, case in ipairs(tests) do
    local before = snapshot()
    local ok, err = xpcall(case.fn, debug.traceback)
    for index = #deferred, 1, -1 do
        local cleaned, cleanup_err = xpcall(deferred[index], debug.traceback)
        if ok and not cleaned then ok, err = false, cleanup_err end
    end
    deferred = {}
    local changed = leaked(before)
    if ok and #changed > 0 then
        ok, err = false, "left global state changed: " .. table.concat(changed, ", ")
    end
    if ok then
        io.write("PASS ", case.name, "\n")
    else
        failures = failures + 1
        io.write("FAIL ", case.name, "\n", err, "\n")
    end
end
debug.sethook()

if filter then
    io.write(string.format("\n%d tests matching %q, %d test failures (coverage gate skipped)\n",
        #tests, filter, failures))
    os.exit(failures > 0 and 1 or 0)
end

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
    if os.getenv("ESV_COVERAGE_DETAILS") == "1" then
        local missed = {}
        for line, _ in pairs(possible[source] or {}) do
            if not (executed[source] and executed[source][line]) then
                missed[#missed + 1] = line
            end
        end
        table.sort(missed)
        io.write("    missed: ", table.concat(missed, ","), "\n")
    end
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
