local H = SCRIPT_BODY
local run, test_script = H.for_script("apply_semantic_definition_or_fail")
local name = "SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME"

test_script("returns success", function()
    local ok = run({
        DEFINITION_SQL = "ALTER SEMANTIC VIEW sales.orders DROP METRIC x", DRY_RUN = true,
    }, {imports = {[name] = {apply_semantic_definition = function(_, dry)
        assert_equal(dry, true)
        return {{"OK", null, "applied", null, 1, 7}}
    end}}})
    assert_equal(ok.rows[1][1], "OK")
end)

test_script("raises returned refusals", function()
    run({}, {imports = {[name] = {
        apply_semantic_definition = function() return {{"ERROR", "SEMANTIC_DDL_010", "bad statement"}} end,
    }}, error = "SEMANTIC_DDL_010: bad statement"})
end)
