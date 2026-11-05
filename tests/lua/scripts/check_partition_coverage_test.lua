local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("check_partition_coverage")

test_script("reports stranded keys separately from outside rows", function()
    local supplied = {MODEL_NAME = "sales"}
    local finding = {entity = "orders", representation = "archive",
        coverage_predicate = "year < 2024", outside_rows = 9, stranded_keys = 2}
    local fixture = delegate("SEMANTIC_ADMIN.VALIDATOR_RUNTIME", "check_partition_coverage",
        supplied, {finding})
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][4], 9)
    assert_equal(result.rows[1][5], 2)
    assert_contains(result.columns, "STRANDED_KEYS DECIMAL")
end)
