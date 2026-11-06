local H = SCRIPT_BODY
local run, test_script, delegate = H.for_script("import_databricks_metric_view")

test_script("forwards arguments and result columns", function()
    local supplied = {YAML_TEXT = "sales"}
    local fixture = delegate("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "import_databricks_metric_view", supplied)
    local result = run(supplied, fixture)
    assert_equal(result.rows[1][1], "DELEGATED")
    assert_contains(result.columns, "STATUS ")
end)
