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

local function with_query(mock, fn)
    local original = query
    query = mock
    local ok, result = xpcall(fn, debug.traceback)
    query = original
    if not ok then error(result, 0) end
    return result
end

local function contains(text, fragment)
    return tostring(text):find(fragment, 1, true) ~= nil
end

test("validator structural rules reject invisible and dangling catalog objects", function()
    local ctx = validation_context({
        version_id = 2,
        entities = {
            {name = "orders", source_schema = "MART", source_object = "ORDERS"},
            {name = "missing", source_schema = "MART", source_object = "MISSING"},
        },
    })
    with_query(function(sql, params)
        if contains(sql, "FROM SYS.EXA_ALL_TABLES") then
            return {{params.object_name == "ORDERS" and 1 or 0}}
        elseif contains(sql, "HAVING COUNT(*) > 1") then
            return {{SOURCE_ALIAS = "O"}}
        elseif contains(sql, "AND e.ENTITY_ID IS NULL") then
            return {{OBJECT_NAME = "BROKEN_OBJECT"}}
        elseif contains(sql, "oc.COLUMN_KIND NOT IN") then
            return {{OBJECT_NAME = "SALES", COLUMN_KIND = "METRIC", COLUMN_NAME = "missing_metric"}}
        end
        error("unexpected structural SQL: " .. tostring(sql))
    end, function()
        api.validate_structural_rules(ctx)
    end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_001"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_003"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_004"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_005"))
    assert_branch("validator.structure.valid", ctx.error_count == 0, false)

    local valid = validation_context({version_id = 2, entities = {
        {name = "orders", source_schema = "MART", source_object = "ORDERS"},
    }})
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_TABLES") then return {{1}} end
        return {}
    end, function() api.validate_structural_rules(valid) end)
    assert_branch("validator.structure.valid", valid.error_count == 0, true)
end)

test("validator expressions enforce ownership reachability functions and columns", function()
    local orders = {id = 1, name = "orders", alias = "o", source_schema = "MART", source_object = "ORDERS"}
    local customers = {id = 2, name = "customers", alias = "c", source_schema = "MART", source_object = "CUSTOMERS"}
    local ctx = validation_context({
        entities = {orders, customers},
        entity_by_id = {['1'] = orders, ['2'] = customers},
        entity_name_by_id = {['1'] = "orders", ['2'] = "customers"},
        entity_alias_by_id = {['1'] = "O", ['2'] = "C"},
        dimensions = {
            {name = "bad_dimension", entity_id = 1, expression = "c.region + QUARTER(o.missing_day)"},
            {name = "orphan_dimension", entity_id = 99, expression = "x.value"},
        },
        facts = {
            {name = "bad_fact", entity_id = 1, expression = "c.amount + MAGIC(o.missing_amount)"},
            {name = "orphan_fact", entity_id = 98, expression = "x.value"},
        },
        metrics = {
            {name = "bad_metric", base_entity_id = 1,
                expression = "UNKNOWN_AGG(net_revenue)", filter_expr = "x.flag = 1 OR c.missing_status = 'A'"},
            {name = "orphan_metric", base_entity_id = 97, expression = "SUM(net_revenue)"},
        },
    })
    local safe_edges = {['1'] = {{to_id = 2, name = "orders_customer", safe = true, reason = "OK"}}}
    with_query(function(sql, params)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            return {{params.column_name == "ID" and 1 or 0}}
        end
        error("unexpected expression SQL: " .. tostring(sql))
    end, function() api.validate_expressions(ctx, safe_edges) end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_004"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_013"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_014"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_016"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_017"))
end)

test("validator extracts and deduplicates fact and metric dependencies", function()
    local inserted = {}
    local fact = {id = 10, name = "net_revenue"}
    local base = {id = 20, name = "total_revenue", expression = "net_revenue + net_revenue"}
    local derived = {id = 21, name = "margin", expression = "total_revenue - missing_input"}
    local ctx = validation_context({
        version_id = 2,
        metrics = {base, derived},
        fact_by_name = {NET_REVENUE = fact},
        metric_by_name = {TOTAL_REVENUE = base, MARGIN = derived},
    })
    with_query(function(sql, params)
        if contains(sql, "INSERT INTO SYS_SEMANTIC.METRIC_DEPENDENCIES") then
            inserted[#inserted + 1] = params
        end
        return {}
    end, function() api.extract_metric_dependencies(ctx) end)
    assert_equal(#inserted, 2)
    assert_equal(inserted[1].object_type, "FACT")
    assert_equal(inserted[2].object_type, "METRIC")
    assert_equal(ctx.metric_edges['21'][1], "20")
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_011"))
end)

test("validator checks agent metadata quality and referential integrity", function()
    local ctx = validation_context({
        version_id = 2,
        metrics = {
            {name = "revenue", data_type = "DECIMAL(18,2)", is_private = false,
                description = nil, unit_hint = nil, format_hint = nil},
            {name = "private_metric", data_type = "DECIMAL(18,2)", is_private = true},
        },
        metric_by_name = {REVENUE = {id = 1}},
        dimension_by_name = {REGION = {id = 2}},
    })
    with_query(function(sql)
        if contains(sql, "GROUP BY UPPER(s.SYNONYM)") then
            return {{SYNONYM_TEXT = "sales"}}
        elseif contains(sql, "LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so") and contains(sql, "VERIFIED_QUERY_ID") then
            return {{VERIFIED_QUERY_ID = 4, QUERY_NAME = "dangling", OBJECT_ID = 99}}
        elseif contains(sql, "SELECT QUERY_NAME, REQUEST_JSON") then
            return {{QUERY_NAME = "bad_request", REQUEST_JSON =
                '{"metrics":["revenue","missing_metric"],"dimensions":["region","missing_dimension"]}'}}
        elseif contains(sql, "FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS") then
            return {{INSTRUCTION_ID = 7, SCOPE_TYPE = "ALIEN", INSTRUCTION_KIND = "MAGIC"}}
        end
        error("unexpected agent metadata SQL: " .. tostring(sql))
    end, function() api.validate_agent_metadata(ctx) end)
    for _, rule in ipairs({"SEMANTIC_MODEL_020", "SEMANTIC_MODEL_021", "SEMANTIC_MODEL_022",
        "SEMANTIC_MODEL_023", "SEMANTIC_MODEL_024", "SEMANTIC_MODEL_025"}) do
        assert_true(has_rule(ctx, rule), "missing rule " .. rule)
    end
    assert_equal(ctx.warning_count, 2)
end)

test("validator computes safe fanout and missing-entity matrix outcomes", function()
    local inserted = {}
    local ctx = validation_context({
        version_id = 2,
        validation_run_id = 9,
        semantic_objects = {},
        entity_name_by_id = {['1'] = "orders", ['2'] = "customers", ['3'] = "items"},
        metrics = {
            {id = 10, name = "revenue", base_entity_id = 1},
            {id = 11, name = "orphan", base_entity_id = 99},
        },
        dimensions = {
            {id = 20, name = "order_id", entity_id = 1},
            {id = 21, name = "region", entity_id = 2},
            {id = 22, name = "item", entity_id = 3},
            {id = 23, name = "missing", entity_id = 98},
        },
    })
    local safe = {['1'] = {{to_id = 2, name = "orders_customer", safe = true, reason = "OK"}}}
    local all = {
        ['1'] = {
            {to_id = 2, name = "orders_customer", safe = true, reason = "OK"},
            {to_id = 3, name = "orders_items", safe = false, reason = "FANOUT_REQUIRES_POLICY"},
        },
    }
    with_query(function(sql, params)
        if contains(sql, "INSERT INTO SYS_SEMANTIC.METRIC_DIMENSION_MATRIX") then
            inserted[#inserted + 1] = params
        end
        return {}
    end, function() api.compute_metric_dimension_matrix(ctx, safe, all) end)
    assert_equal(#inserted, 8)
    assert_true(ctx.matrix['10']['20'].is_valid)
    assert_equal(ctx.matrix['10']['21'].reason_code, "OK")
    assert_equal(ctx.matrix['10']['22'].reason_code, "FANOUT_REQUIRES_POLICY")
    assert_equal(ctx.matrix['10']['23'].reason_code, "MISSING_DIMENSION_ENTITY")
    assert_equal(ctx.matrix['11']['20'].reason_code, "MISSING_BASE_ENTITY")
    assert_branch("validator.matrix.safe", ctx.matrix['10']['21'].is_valid, true)
    assert_branch("validator.matrix.safe", ctx.matrix['10']['22'].is_valid, false)

    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
            return {{"SALES", 10, "revenue", 22, "item"}}
        end
        return {}
    end, function() api.validate_visible_metric_dimension_pairs(ctx) end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_030"))
end)

test("validator matrix rejects metrics unreachable from published roots", function()
    local ctx = validation_context({
        version_id = 2,
        semantic_objects = {{root_entity_id = 3}},
        entity_name_by_id = {['1'] = "orders", ['2'] = "customers", ['3'] = "isolated"},
        metrics = {{id = 10, name = "revenue", base_entity_id = 1}},
        dimensions = {{id = 20, name = "region", entity_id = 2}},
    })
    local safe = {['1'] = {{to_id = 2, name = "orders_customer", safe = true, reason = "OK"}}}
    with_query(function() return {} end, function()
        api.compute_metric_dimension_matrix(ctx, safe, safe)
    end)
    assert_equal(ctx.matrix['10']['20'].reason_code, "NO_SAFE_JOIN_PATH")
end)

test("validator public entry point loads and validates a coherent catalog", function()
    local lifecycle = {started = false, finished = false, cache_cleared = false,
        matrix_inserted = false, dependency_inserted = false}
    local function mock(sql)
        if contains(sql, "FROM SYS_SEMANTIC.MODELS m") then
            return {{MODEL_ID = 1, VERSION_ID = 2, VERSION_NUMBER = 1}}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.VALIDATION_RUNS") then
            lifecycle.started = true
            return {}
        elseif contains(sql, "SELECT MAX(VALIDATION_RUN_ID)") then
            return {{77}}
        elseif contains(sql, "SELECT ENTITY_ID, ENTITY_NAME") then
            return {{1, "orders", "MART", "ORDERS", "o"}}
        elseif contains(sql, "SELECT DIMENSION_ID, DIMENSION_NAME") then
            return {{10, "order_status", 1, "o.status", "VARCHAR(20)",
                "Order status", nil, nil, false, true}}
        elseif contains(sql, "SELECT FACT_ID, FACT_NAME") then
            return {{20, "net_revenue", 1, "o.amount", "DECIMAL(18,2)",
                "Revenue input", "USD", "currency", false, true}}
        elseif contains(sql, "SELECT METRIC_ID, METRIC_NAME") and not contains(sql, "metric_col") then
            return {{30, "total_revenue", 1, "SUM(net_revenue)", nil, "ADDITIVE",
                "DECIMAL(18,2)", "Total revenue", "USD", "currency", false, true}}
        elseif contains(sql, "SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME") then
            return {}
        elseif contains(sql, "SELECT OBJECT_ID, OBJECT_NAME, ROOT_ENTITY_ID") then
            return {{40, "SALES", 1}}
        elseif contains(sql, "SELECT UNIQUE_KEY_ID, ENTITY_ID") then
            return {{50, 1, "orders_pk", "PRIMARY", "NATIVE"}}
        elseif contains(sql, "SELECT ukc.UNIQUE_KEY_ID") then
            return {{50, 1, "order_id", nil}}
        elseif contains(sql, "SELECT CUSTOM_EXTENSION_ID") then
            return {{60, "MODEL", 1, "acme", "quality", "JSON", '{"level":"gold"}'}}
        elseif contains(sql, "FROM SYS.EXA_ALL_TABLES") then
            return {{1}}
        elseif contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            return {{1}}
        elseif contains(sql, "HAVING COUNT(*) > 1") then
            return {}
        elseif contains(sql, "AND e.ENTITY_ID IS NULL") then
            return {}
        elseif contains(sql, "oc.COLUMN_KIND NOT IN") then
            return {}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.METRIC_DEPENDENCIES") then
            lifecycle.dependency_inserted = true
            return {}
        elseif contains(sql, "SELECT vq.VERIFIED_QUERY_ID")
            or contains(sql, "SELECT QUERY_NAME, REQUEST_JSON")
            or contains(sql, "FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS") then
            return {}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.METRIC_DIMENSION_MATRIX") then
            lifecycle.matrix_inserted = true
            return {}
        elseif contains(sql, "JOIN SYS_SEMANTIC.OBJECT_COLUMNS metric_col") then
            return {{"SALES", 30, "total_revenue", 10, "order_status"}}
        elseif contains(sql, "DELETE FROM SYS_SEMANTIC.COMPILE_CACHE") then
            lifecycle.cache_cleared = true
            return {}
        elseif contains(sql, "UPDATE SYS_SEMANTIC.VALIDATION_RUNS") then
            lifecycle.finished = true
            return {}
        elseif contains(sql, "DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES")
            or contains(sql, "DELETE FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX") then
            return {}
        end
        error("unexpected validate_model SQL: " .. tostring(sql))
    end
    local issues = with_query(mock, function() return validate_model("sales") end)
    assert_equal(#issues, 0)
    assert_true(lifecycle.started)
    assert_true(lifecycle.finished)
    assert_true(lifecycle.cache_cleared)
    assert_true(lifecycle.matrix_inserted)
    assert_true(lifecycle.dependency_inserted)
    assert_branch("validator.model.valid", #issues == 0, true)
end)

test("validator public entry point reports missing model contracts", function()
    local next_validation_id = 80
    local function mock(sql)
        if contains(sql, "FROM SYS_SEMANTIC.MODELS m") then return {} end
        if contains(sql, "INSERT INTO SYS_SEMANTIC.VALIDATION_RUNS") then return {} end
        if contains(sql, "SELECT MAX(VALIDATION_RUN_ID)") then
            next_validation_id = next_validation_id + 1
            return {{next_validation_id}}
        end
        if contains(sql, "INSERT INTO SYS_SEMANTIC.VALIDATION_RESULTS")
            or contains(sql, "UPDATE SYS_SEMANTIC.VALIDATION_RUNS") then return {} end
        error("unexpected missing-model SQL: " .. tostring(sql))
    end
    with_query(mock, function()
        local missing_name = validate_model(nil)
        assert_equal(missing_name[1].rule_code, "SEMANTIC_MODEL_000")
        local missing_model = validate_model("unknown")
        assert_equal(missing_model[1].rule_code, "SEMANTIC_MODEL_000")
        assert_branch("validator.model.valid", #missing_model == 0, false)
    end)
end)
