local H = SCRIPT_BODY
local run, test_script = H.for_script("disable_semantic_sql")

test_script("clears the session preprocessor", function()
    local result = run({}, {sql = {H.step("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")}})
    assert_equal(result.rows[1][1], "OK")
    assert_equal(result.rows[1][3], null)
    assert_contains(result.columns, "ACTIVATION_SCOPE VARCHAR")
end)
