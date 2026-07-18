local api = ESV_VALIDATOR_TEST_API

test("validator accepts valid JSON and rejects malformed JSON", function()
    assert_branch("validator.valid_json", api.valid_json_text('{"a":[1,true,null]}'), true)
    assert_branch("validator.valid_json", api.valid_json_text('{"a":01}'), false)
end)

test("validator expression inspection ignores strings and permits qualified UDFs", function()
    local aliases = api.aliases_in_expression("f.amount + d.rate + 'x.fake'")
    assert_true(aliases.F and aliases.D)
    assert_true(not aliases.X)
    local unsupported = api.unsupported_functions("SUM(f.amount) + QUARTER(d.day) + ML.PREDICT(f.x)")
    assert_branch("validator.unsupported_function", unsupported.QUARTER, true)
    assert_branch("validator.unsupported_function", unsupported.SUM, false)
    assert_true(not unsupported.PREDICT)
end)

test("validator extracts dependency identifiers without SQL words", function()
    local deps = api.dependency_tokens("gross_margin / NULLIF(total_revenue, 0)")
    assert_equal(deps.GROSS_MARGIN, "gross_margin")
    assert_equal(deps.TOTAL_REVENUE, "total_revenue")
    assert_true(deps.NULLIF == nil)
end)

test("validator graph search reports safe blocked and missing paths", function()
    local edges = {
        ["1"] = {{to_id = 2, name = "orders_customer", safe = true, reason = "OK"}},
        ["2"] = {{to_id = 3, name = "customer_region", safe = false, reason = "FANOUT"}},
    }
    local ok, _, path = api.find_path(edges, 1, 2, true)
    assert_branch("validator.path_found", ok, true)
    assert_equal(path, "orders_customer")
    local blocked, reason = api.find_path(edges, 1, 3, true)
    assert_branch("validator.path_found", blocked, false)
    assert_equal(reason, "FANOUT")
    local allowed, _, unsafe_path = api.find_path(edges, 1, 3, false)
    assert_true(allowed)
    assert_equal(unsafe_path, "orders_customer > customer_region")
end)

test("validator JSON array extraction is case insensitive", function()
    local values = api.extract_json_array_values('{"Synonyms":["revenue","sales"]}', "synonyms")
    assert_equal(values[1], "revenue")
    assert_equal(values[2], "sales")
end)
