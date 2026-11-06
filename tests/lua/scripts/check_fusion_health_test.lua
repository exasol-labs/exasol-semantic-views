local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("check_fusion_health")

test_script("shapes source and unresolved counts", function()
    local supplied = {MODEL_NAME = "sales"}
    local finding = {entity = "orders", attribute_type = "DIMENSION", attribute = "region",
        strategy = "COALESCE", first_source = "crm", total_keys = 8, from_first_source = 5,
        filled = 2, unresolved = 1}
    local fixture = delegate("SEMANTIC_ADMIN.COMPILER_RUNTIME", "fusion_health", supplied, {finding})
    local result = run(supplied, fixture)
    H.same(result.rows[1], {"orders", "DIMENSION", "region", "COALESCE", "crm", 8, 5, 2, 1, null}, "health row")
    assert_contains(result.columns, "UNRESOLVED DECIMAL")
end)
