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

local function validation_context(overrides)
    local ctx = {
        model_id = 1,
        issues = {},
        issue_seen = {},
        error_count = 0,
        warning_count = 0,
        semantic_object_by_id = {},
        entity_by_id = {},
        entity_name_by_id = {},
        entity_alias_by_id = {},
        relationship_by_id = {},
        dimension_by_id = {},
        fact_by_id = {},
        metric_by_id = {},
    }
    for name, value in pairs(overrides or {}) do ctx[name] = value end
    return ctx
end

local function has_rule(ctx, rule_code)
    for _, issue in ipairs(ctx.issues) do
        if issue.rule_code == rule_code then return true end
    end
    return false
end

test("validator rejects malformed and dangling custom extensions", function()
    local ctx = validation_context({
        metric_by_id = {['7'] = {id = 7, name = "revenue"}},
        custom_extensions = {
            {id = 1, scope_type = "METRIC", scope_id = 7, vendor_name = "acme",
                extension_name = "quality", source_format = "JSON", data_json = '{"ok":true}'},
            {id = 2, scope_type = "METRIC", scope_id = 99, vendor_name = "acme",
                extension_name = "missing", source_format = "JSON", data_json = '{}'},
            {id = 3, scope_type = "UNKNOWN", scope_id = 1, vendor_name = nil,
                extension_name = nil, source_format = nil, data_json = '{broken'},
        },
    })
    api.validate_custom_extensions(ctx)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_026"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_027"))
    assert_equal(ctx.error_count, 6)
end)

test("validator relationship graph distinguishes safe joins and fanout", function()
    local ctx = validation_context({
        entity_name_by_id = {['1'] = "orders", ['2'] = "customers"},
        entity_alias_by_id = {['1'] = "O", ['2'] = "C"},
        relationships = {
            {name = "orders_customer", from_entity_id = 1, to_entity_id = 2,
                cardinality = "MANY_TO_ONE", join_type = "LEFT",
                join_condition = "o.customer_id = c.customer_id"},
            {name = "unsafe_bridge", from_entity_id = 1, to_entity_id = 2,
                cardinality = "MANY_TO_MANY", join_type = "INNER",
                join_condition = "o.id = x.id"},
        },
    })
    local safe, all = api.relationship_edges(ctx)
    assert_equal(safe['1'][1].to_id, 2)
    assert_branch("validator.relationship.safe_edge", safe['1'] ~= nil, true)
    assert_equal(all['2'][1].reason, "FANOUT_REQUIRES_POLICY")
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_007"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_010"))
end)

test("validator reports invalid relationship contracts", function()
    local ctx = validation_context({
        entity_name_by_id = {['1'] = "orders"},
        entity_alias_by_id = {['1'] = "O"},
        relationships = {
            {name = "broken", from_entity_id = 1, to_entity_id = 99,
                cardinality = "SOME_TO_ONE", join_type = "SIDEWAYS",
                join_condition = "1 = 1"},
        },
    })
    local safe = api.relationship_edges(ctx)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_006"))
    assert_branch("validator.relationship.safe_edge", safe['1'] ~= nil, false)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_007"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_008"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_009"))
end)

test("validator detects cyclic metric dependencies once per cycle", function()
    local ctx = validation_context({
        metrics = {{id = 1, name = "a"}, {id = 2, name = "b"}, {id = 3, name = "c"}},
        metric_by_id = {
            ['1'] = {id = 1, name = "a"},
            ['2'] = {id = 2, name = "b"},
            ['3'] = {id = 3, name = "c"},
        },
        metric_edges = {['1'] = {'2'}, ['2'] = {'1'}, ['3'] = {}},
    })
    api.detect_metric_cycles(ctx)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_012"))
    assert_branch("validator.metric.cycle", has_rule(ctx, "SEMANTIC_MODEL_012"), true)
    assert_equal(ctx.error_count, 1)

    local acyclic = validation_context({
        metrics = {{id = 1, name = "a"}, {id = 2, name = "b"}},
        metric_by_id = {['1'] = {id = 1, name = "a"}, ['2'] = {id = 2, name = "b"}},
        metric_edges = {['1'] = {'2'}, ['2'] = {}},
    })
    api.detect_metric_cycles(acyclic)
    assert_branch("validator.metric.cycle", has_rule(acyclic, "SEMANTIC_MODEL_012"), false)
end)

test("validator rejects malformed unique-key contracts", function()
    local entity = {id = 1, name = "orders", alias = "o", source_schema = "MART",
        source_object = "ORDERS"}
    local ctx = validation_context({
        entity_by_id = {['1'] = entity},
        entity_name_by_id = {['1'] = "orders"},
        unique_keys = {
            {entity_id = 99, name = nil, kind = "UNKNOWN", columns = {}},
            {entity_id = 1, name = "bad_columns", kind = "PRIMARY", columns = {
                {ordinal_position = nil, column_name = nil, expression = nil},
                {ordinal_position = 2, column_name = "id", expression = "o.id"},
            }},
        },
    })
    api.validate_unique_keys(ctx)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_028"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_029"))
    assert_equal(ctx.error_count, 7)
end)
