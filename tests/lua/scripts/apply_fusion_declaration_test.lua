local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("apply_fusion_declaration")

test_script("forwards arguments and result columns", function()
    local supplied = {MODEL_NAME = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.FUSION_RUNTIME", "apply_fusion_declaration", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "STATUS ")
end)
