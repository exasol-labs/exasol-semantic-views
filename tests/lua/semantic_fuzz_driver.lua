-- Database-free JSON-lines bridge to the canonical Lua compiler.
-- Run from the repository root. Each line is {id, sql}; each reply carries id,
-- status, error_code and generated_sql_present.

ESV_TEST_MODE = true
null = setmetatable({}, {__tostring = function() return "null" end})

local sources = {
    "lua/semantic_layer/shared/json.lua",
    "lua/semantic_layer/shared/rows.lua",
    "lua/semantic_layer/shared/sql_text.lua",
    "lua/semantic_layer/shared/catalog_rollback.lua",
    "lua/semantic_layer/shared/grain_graph.lua",
    "lua/semantic_layer/shared/source_columns.lua",
    "lua/semantic_layer/shared/identity_join.lua",
    "lua/semantic_layer/compiler/query_spec.lua",
    "lua/semantic_layer/compiler/catalog_snapshot.lua",
    "lua/semantic_layer/compiler/metric_plan.lua",
    "lua/semantic_layer/compiler/physical_plan.lua",
    "lua/semantic_layer/compiler/grain_sql.lua",
    "lua/semantic_layer/compiler/compile_result.lua",
    "lua/semantic_layer/compiler/semantic_sql_syntax.lua",
    "lua/semantic_layer/compiler/request_json.lua",
}
for _, path in ipairs(sources) do
    local chunk, err = loadfile(path, "t", _G)
    if not chunk then error(err) end
    chunk()
end

local compiler_query_fixture = dofile("tests/lua/compiler_fixture.lua")

local function handle(line)
    local input = ESV_JSON.decode(line)
    if type(input) ~= "table" or type(input.id) ~= "number"
        or type(input.sql) ~= "string" then
        error("input needs numeric id and SQL text")
    end
    local mock = compiler_query_fixture({fuzz_sales = true})
    query = mock
    local ok, result = pcall(_G.compile_sql, input.sql)
    query = nil
    if not ok then error(result) end
    return {
        id = input.id,
        status = result.status,
        error_code = result.error_code,
        generated_sql_present = type(result.generated_sql) == "string"
            and result.generated_sql ~= "",
    }
end

for line in io.lines() do
    local ok, result = pcall(handle, line)
    if not ok then
        result = {status = "HARNESS_ERROR", error_message = tostring(result),
            generated_sql_present = false}
    end
    io.write(ESV_JSON.encode(result), "\n")
    io.flush()
end
