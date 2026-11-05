local H = SCRIPT_BODY
local step = H.step
test("script body: semantic_preprocessor passes ordinary SQL unchanged", function()
    local result = H.run("semantic_preprocessor", {}, {sql_text = "SELECT 1"})
    assert_equal(result.sql_text, "SELECT 1")
    assert_equal(#result.imports, 0)
end)

test("script body: semantic_preprocessor rewrites DDL", function()
    local ddl = "ALTER SEMANTIC VIEW sales.orders DROP METRIC x"
    local result = H.run("semantic_preprocessor", {}, {
        sql_text = ddl,
        imports = {["SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME"] = {
            preprocess_sql = function(value)
                assert_equal(value, ddl)
                return {status = "OK", generated_sql = "EXECUTE SCRIPT APPLY(...)"}
            end,
        }},
    })
    assert_equal(result.sql_text, "EXECUTE SCRIPT APPLY(...)")
end)

test("script body: semantic_preprocessor rejects compiler errors", function()
    H.run("semantic_preprocessor", {}, {
        sql_text = "SELECT * FROM SEMANTIC_SALES.ORDERS",
        sql = {step("SELECT UPPER(PUBLISHED_SCHEMA)", {{"SEMANTIC_SALES"}})},
        imports = {["SEMANTIC_ADMIN.COMPILER_RUNTIME"] = {
            compile_sql_for_preprocessor = function()
                return {status = "ERROR", error_code = "SEMANTIC_QUERY_005", error_message = "refused"}
            end,
        }},
        error = "SEMANTIC_QUERY_005: refused",
    })
end)
