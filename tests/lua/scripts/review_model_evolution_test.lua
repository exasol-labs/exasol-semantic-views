local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("review_model_evolution")

test_script("forwards arguments and result columns", function()
    local supplied = {SUGGESTION_ID = 7}
    local fixture = delegate("SEMANTIC_ADMIN.AGENT_RUNTIME", "review_model_evolution", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "SUGGESTION_ID ")
end)
