local H = SCRIPT_BODY
local run, test_script = H.for_script("enable_semantic_sql")

test_script("activates the session preprocessor", function()
    local result = run({}, {sql = {
        H.step("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"),
    }})
    assert_equal(result.rows[1][1], "OK")
    assert_equal(result.rows[1][3], "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR")
    assert_contains(result.columns, "ACTIVATION_SCOPE VARCHAR")
end)
