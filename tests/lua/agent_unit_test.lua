local api = ESV_AGENT_TEST_API

test("agent JSON encoding distinguishes arrays and objects", function()
    local encoded = api.json_encode({status = "OK", fields = {"a", "b"}})
    assert_contains(encoded, '"fields":["a","b"]')
    assert_contains(encoded, '"status":"OK"')
end)

test("agent materialization extraction handles selected and absent plans", function()
    local selected = api.extract_selected_materialization(
        '{"selected_materialization":{"materialization_name":"sales_by_region"}}')
    assert_equal(selected, "sales_by_region")
    assert_branch("agent.materialization", selected ~= null, true)
    local absent = api.extract_selected_materialization('{}')
    assert_branch("agent.materialization", absent ~= null, false)
end)

test("agent extracts request arrays and escapes LIKE patterns", function()
    assert_equal(api.extract_json_array_text('{"metrics":["a","b"]}', "metrics"), '["a","b"]')
    local pattern = api.like_pattern("50%_off")
    assert_contains(pattern, "\\%")
    assert_contains(pattern, "\\_")
end)

test("agent rows convert to named objects", function()
    local objects = api.rows_to_objects({{1, "sales"}, {2, "orders"}}, {"id", "name"})
    assert_equal(objects[2].id, 2)
    assert_equal(objects[2].name, "orders")
end)
