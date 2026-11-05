local H = SCRIPT_BODY
local name = "SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME"

test("script body: apply_semantic_definition_or_fail returns success", function()
    local ok = H.run("apply_semantic_definition_or_fail", {
        DEFINITION_SQL = "ALTER SEMANTIC VIEW sales.orders DROP METRIC x", DRY_RUN = true,
    }, {imports = {[name] = {apply_semantic_definition = function(_, dry)
        assert_equal(dry, true)
        return {{"OK", null, "applied", null, 1, 7}}
    end}}})
    assert_equal(ok.rows[1][1], "OK")
end)

test("script body: apply_semantic_definition_or_fail raises returned refusals", function()
    H.run("apply_semantic_definition_or_fail", {}, {imports = {[name] = {
        apply_semantic_definition = function() return {{"ERROR", "SEMANTIC_DDL_010", "bad statement"}} end,
    }}, error = "SEMANTIC_DDL_010: bad statement"})
end)
