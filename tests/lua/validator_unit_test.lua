local api = ESV_VALIDATOR_TEST_API

test("validator accepts valid JSON and rejects malformed JSON", function()
    assert_branch("validator.valid_json", api.valid_json_text('{"a":[1,true,null]}'), true)
    assert_branch("validator.valid_json", api.valid_json_text('{"a":01}'), false)

    -- The validator no longer carries its own JSON parser; it uses the strict
    -- mode of shared/json.lua. What must survive that is the strictness, which
    -- is why `01` is still refused: extension data_json is written by a model
    -- author, and a payload the compiler's lenient decoder would tolerate is
    -- still not a payload worth storing.
    assert_equal(api.valid_json_text('{"a":1.}'), false)
    assert_equal(api.valid_json_text('"\\uZZZZ"'), false)
    assert_equal(api.valid_json_text('"\\u00e9"'), true)
    assert_equal(api.valid_json_text(null), false)
    assert_equal(api.valid_json_text(""), false)
end)

test("validator expression inspection ignores strings and permits qualified UDFs", function()
    local aliases = api.aliases_in_expression("f.amount + d.rate + 'x.fake'")
    assert_true(aliases.F and aliases.D)
    assert_true(not aliases.X)
    local quoted_aliases = api.aliases_in_expression('li."_parent" = o."_id"')
    assert_true(quoted_aliases.LI and quoted_aliases.O)
    local quoted_refs = api.column_refs_in_expression('li."_parent" = o."a""b"')
    assert_equal(quoted_refs[1].column_name, "_parent")
    assert_equal(quoted_refs[2].column_name, 'a"b')
    local unsupported = api.unsupported_functions("SUM(f.amount) + QUARTER(d.day) + ML.PREDICT(f.x)")
    assert_branch("validator.unsupported_function", unsupported.QUARTER, true)
    assert_branch("validator.unsupported_function", unsupported.SUM, false)
    assert_true(not unsupported.PREDICT)
end)

test("validator accepts date truncation and ignores CAST target type parameters", function()
    local supported = api.unsupported_functions(
        "TRUNC(o.order_ts, 'MM') + CAST(YEAR(o.order_ts) AS VARCHAR(4)) || LPAD('8', 2, '0')")
    assert_equal(next(supported), nil)

    local decimal_cast = api.unsupported_functions("CAST(o.amount AS DECIMAL(18,2))")
    assert_equal(next(decimal_cast), nil)

    local invalid_constructor = api.unsupported_functions("VARCHAR(4)")
    assert_true(invalid_constructor.VARCHAR)

    local dependencies = api.dependency_tokens("TRUNC(order_ts, 'MM') || LPAD(month_no, 2, '0')")
    assert_equal(dependencies.TRUNC, nil)
    assert_equal(dependencies.LPAD, nil)
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
        precondition_count = 0,
        warning_count = 0,
        semantic_object_by_id = {},
        entity_by_id = {},
        entity_name_by_id = {},
        entity_alias_by_id = {},
        relationship_by_id = {},
        dimension_by_id = {},
        fact_by_id = {},
        metric_by_id = {},
        representations = {},
        representations_by_entity = {},
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

local function issue_for_rule(ctx, rule_code)
    for _, issue in ipairs(ctx.issues) do
        if issue.rule_code == rule_code then return issue end
    end
    return nil
end

test("validator accepts relationship joins with quoted columns on both endpoints", function()
    local ctx = validation_context({
        entity_name_by_id = {['1'] = "order_line", ['2'] = "order"},
        entity_alias_by_id = {['1'] = "LI", ['2'] = "O"},
        relationships = {{
            name = "line_to_order",
            from_entity_id = 1,
            to_entity_id = 2,
            cardinality = "MANY_TO_ONE",
            join_type = "INNER",
            join_condition = 'li."_parent" = o."_id"',
        }},
    })
    api.relationship_edges(ctx)
    assert_true(not has_rule(ctx, "SEMANTIC_MODEL_007"))
end)

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
    assert_equal(all['2'][1].reason, "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_007"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_010"))
end)

test("validator flags fanout policy values that carry no meaning", function()
    -- ADD_RELATIONSHIP rejects unknown values on write, so a row carrying one
    -- predates that check: warn without failing an otherwise valid model.
    local legacy = validation_context({
        entity_name_by_id = {['1'] = "orders", ['2'] = "shipments"},
        entity_alias_by_id = {['1'] = "O", ['2'] = "S"},
        relationships = {
            {name = "orders_shipments", from_entity_id = 1, to_entity_id = 2,
                cardinality = "MANY_TO_MANY", join_type = "LEFT",
                fanout_policy = "banana",
                join_condition = "o.order_id = s.order_id"},
        },
    })
    api.relationship_edges(legacy)
    assert_true(has_rule(legacy, "SEMANTIC_MODEL_053"))
    assert_true(not has_rule(legacy, "SEMANTIC_MODEL_010"))
    assert_contains(issue_for_rule(legacy, "SEMANTIC_MODEL_053").message,
        "Unrecognized fanout policy: banana")
    assert_equal(issue_for_rule(legacy, "SEMANTIC_MODEL_053").severity, "WARNING")

    -- A recognized value on a cardinality where it means nothing is the shape
    -- that made FANOUT_REQUIRES_POLICY read as an available remedy.
    local misplaced = validation_context({
        entity_name_by_id = {['1'] = "lines", ['2'] = "orders"},
        entity_alias_by_id = {['1'] = "L", ['2'] = "O"},
        relationships = {
            {name = "line_to_order", from_entity_id = 1, to_entity_id = 2,
                cardinality = "MANY_TO_ONE", join_type = "LEFT",
                fanout_policy = "allocate",
                join_condition = "l.order_id = o.order_id"},
        },
    })
    api.relationship_edges(misplaced)
    assert_contains(issue_for_rule(misplaced, "SEMANTIC_MODEL_053").message,
        "declared on a MANY_TO_ONE relationship, where it has no meaning")

    -- A recognized value on a many-to-many relationship is silent.
    local accepted = validation_context({
        entity_name_by_id = {['1'] = "orders", ['2'] = "shipments"},
        entity_alias_by_id = {['1'] = "O", ['2'] = "S"},
        relationships = {
            {name = "orders_shipments", from_entity_id = 1, to_entity_id = 2,
                cardinality = "MANY_TO_MANY", join_type = "LEFT",
                fanout_policy = "REFERENCE_ONLY",
                join_condition = "o.order_id = s.order_id"},
        },
    })
    api.relationship_edges(accepted)
    assert_true(not has_rule(accepted, "SEMANTIC_MODEL_053"))
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

test("validator accepts composite relationship mappings backed by a unique key", function()
    local from_entity = {id = 1, name = "orders", alias = "o"}
    local to_entity = {id = 2, name = "customers", alias = "c"}
    local customer_key = {
        id = 8,
        entity_id = 2,
        name = "customer_tenant",
        kind = "PRIMARY",
        columns = {
            {ordinal_position = 1, column_name = "tenant_id"},
            {ordinal_position = 2, column_name = "customer_id"},
        },
    }
    local ctx = validation_context({
        entities = {from_entity, to_entity},
        unique_keys_by_entity = {['2'] = {customer_key}},
        relationships = {{
            name = "orders_customer",
            from_entity_id = 1,
            to_entity_id = 2,
            cardinality = "MANY_TO_ONE",
            key_mappings = {
                {ordinal_position = 1, from_column_name = "tenant_id",
                    to_column_name = "tenant_id"},
                {ordinal_position = 2, from_column_name = "customer_id",
                    to_column_name = "customer_id"},
            },
        }},
    })
    api.validate_relationship_key_mappings(ctx)
    assert_equal(ctx.error_count, 0)
    assert_equal(ctx.warning_count, 0)
end)

test("validator accepts JSON Tables object-reference key mappings", function()
    local ctx = validation_context({
        unique_keys_by_entity = {['2'] = {{
            entity_id = 2,
            columns = {{ordinal_position = 1, column_name = "_id"}},
        }}},
        relationships = {{
            name = "customer_profile",
            from_entity_id = 1,
            to_entity_id = 2,
            cardinality = "MANY_TO_ONE",
            key_mappings = {{
                ordinal_position = 1,
                from_column_name = "profile|object",
                to_column_name = "_id",
            }},
        }},
    })
    api.validate_relationship_key_mappings(ctx)
    assert_equal(ctx.error_count, 0)
    assert_equal(ctx.warning_count, 0)
end)

test("validator rejects expression relationship key mappings before publication", function()
    local ctx = validation_context({
        unique_keys_by_entity = {['2'] = {{
            entity_id = 2,
            columns = {{ordinal_position = 1, column_name = "CUSTOMER_ID"}},
        }}},
        relationships = {{
            name = "session_to_customer",
            from_entity_id = 1,
            to_entity_id = 2,
            cardinality = "MANY_TO_ONE",
            key_mappings = {{
                ordinal_position = 1,
                from_expression = "CAST(w.CUSTOMER_ID AS DECIMAL(18,0))",
                to_column_name = "CUSTOMER_ID",
            }},
        }},
    })
    api.validate_relationship_key_mappings(ctx)
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_032")
    assert_true(issue ~= nil)
    assert_contains(issue.message, "normalize the expression into a source view")
end)

test("validator distinguishes legacy and invalid relationship mappings", function()
    local from_entity = {id = 1, name = "orders", alias = "o"}
    local to_entity = {id = 2, name = "customers", alias = "c"}
    local legacy = validation_context({
        entity_by_id = {['1'] = from_entity, ['2'] = to_entity},
        unique_keys_by_entity = {},
        relationships = {{
            name = "legacy",
            from_entity_id = 1,
            to_entity_id = 2,
            cardinality = "MANY_TO_ONE",
            key_mappings = {},
        }},
    })
    api.validate_relationship_key_mappings(legacy)
    local missing_mapping = issue_for_rule(legacy, "SEMANTIC_MODEL_031")
    assert_true(missing_mapping ~= nil)
    assert_contains(missing_mapping.message, "declare a unique key")
    assert_equal(legacy.error_count, 0)

    local invalid = validation_context({
        entity_by_id = {['1'] = from_entity, ['2'] = to_entity},
        unique_keys_by_entity = {},
        relationships = {{
            name = "invalid",
            from_entity_id = 1,
            to_entity_id = 2,
            cardinality = "MANY_TO_ONE",
            key_mappings = {{
                ordinal_position = 2,
                from_column_name = "customer_id",
                from_expression = "o.customer_id",
                to_expression = "x.customer_id",
            }},
        }},
    })
    api.validate_relationship_key_mappings(invalid)
    assert_true(has_rule(invalid, "SEMANTIC_MODEL_032"))
    assert_true(has_rule(invalid, "SEMANTIC_MODEL_033"))
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

test("source catalog probes preserve non-uppercase identifiers", function()
    with_query(function(sql, params)
        if contains(sql, "FROM SYS.EXA_ALL_TABLES") then
            assert_true(contains(sql, "TABLE_SCHEMA = :schema_name"))
            assert_true(contains(sql, "TABLE_NAME = :object_name"))
            assert_equal(params.schema_name, "SRC_MONGO_ORDERS")
            assert_equal(params.object_name, "ORDERS_line_items_arr")
            return {{1}}
        elseif contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            assert_true(contains(sql, "COLUMN_TABLE = :object_name"))
            assert_true(contains(sql, "COLUMN_NAME = :column_name"))
            assert_equal(params.object_name, "campaigns")
            assert_equal(params.column_name, "_id")
            return {{1}}
        end
        error("unexpected source catalog SQL: " .. tostring(sql))
    end, function()
        assert_true(api.source_object_exists("SRC_MONGO_ORDERS", "ORDERS_line_items_arr"))
        assert_true(api.source_column_exists("EJT_CAMPAIGNS_VIEW", "campaigns", "_id"))
    end)
end)

test("validator rejects type-incompatible relationship endpoints", function()
    local from_entity = {id = 1, name = "order_line", alias = "li"}
    local to_entity = {id = 2, name = "campaign", alias = "cp"}
    local ctx = validation_context({
        entities = {from_entity, to_entity},
        entity_by_id = {['1'] = from_entity, ['2'] = to_entity},
        entity_name_by_id = {['1'] = "order_line", ['2'] = "campaign"},
        entity_alias_by_id = {['1'] = "LI", ['2'] = "CP"},
        representations_by_entity = {
            ['1'] = {{id = 11, entity_id = 1, name = "primary",
                source_schema = "HUBV", source_object = "ORDER_LINES", alias = "li"}},
            ['2'] = {{id = 12, entity_id = 2, name = "primary",
                source_schema = "HUBV", source_object = "CAMPAIGNS", alias = "cp"}},
        },
        relationships = {{
            name = "line_campaign", from_entity_id = 1, to_entity_id = 2,
            cardinality = "MANY_TO_ONE", join_type = "LEFT",
            join_condition = "li.PRODUCT_ID = cp.CAMPAIGN_ID",
        }},
    })
    with_query(function(sql, params)
        if contains(sql, "SELECT COUNT(*)")
            and contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            return {{1}}
        elseif contains(sql, "SELECT COLUMN_TYPE") then
            if params.column_name == "PRODUCT_ID" then
                return {{COLUMN_TYPE = "DECIMAL(10,0)"}}
            end
            return {{COLUMN_TYPE = "VARCHAR(2000000) UTF8"}}
        end
        error("unexpected relationship type SQL: " .. tostring(sql))
    end, function()
        api.relationship_edges(ctx)
    end)
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_051")
    assert_true(issue ~= nil)
    assert_contains(issue.message, "LI.PRODUCT_ID")
    assert_contains(issue.message, "DECIMAL(10,0)")
    assert_contains(issue.message, "CP.CAMPAIGN_ID")
    assert_contains(issue.message, "VARCHAR(2000000) UTF8")
end)

test("validator structural rules reject invisible and dangling catalog objects", function()
    local ctx = validation_context({
        version_id = 2,
        entities = {
            {id = 1, name = "orders", alias = "o", source_schema = "MART", source_object = "ORDERS",
                primary_representation = {id = 1}},
            {id = 2, name = "missing", alias = "m", source_schema = "MART", source_object = "MISSING",
                primary_representation = {id = 2}},
        },
        entity_by_id = {
            ["1"] = {id = 1, name = "orders", alias = "o"},
            ["2"] = {id = 2, name = "missing", alias = "m"},
        },
        representations = {
            {id = 1, entity_id = 1, name = "primary", source_kind = "RELATION",
                source_schema = "MART", source_object = "ORDERS", alias = "o",
                role = "PRIMARY", priority = 1},
            {id = 2, entity_id = 2, name = "primary", source_kind = "RELATION",
                source_schema = "MART", source_object = "MISSING", alias = "m",
                role = "PRIMARY", priority = 1},
        },
    })
    with_query(function(sql, params)
        if contains(sql, "COUNT(er.REPRESENTATION_ID)") then
            return {{ENTITY_NAME = "unbound", PRIMARY_COUNT = 0}}
        elseif contains(sql, "FROM SYS.EXA_ALL_TABLES") then
            return {{params.object_name == "ORDERS" and 1 or 0}}
        elseif contains(sql, "HAVING COUNT(*) > 1") then
            return {{SOURCE_ALIAS = "O"}}
        elseif contains(sql, "JOIN SYS.EXA_SQL_KEYWORDS") then
            return {{ENTITY_NAME = "attribution", SOURCE_ALIAS = "at"}}
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
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_034"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_004"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_005"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_035"))
    assert_branch("validator.structure.valid", ctx.error_count == 0, false)

    local valid = validation_context({version_id = 2, entities = {
        {id = 1, name = "orders", alias = "o", source_schema = "MART", source_object = "ORDERS",
            primary_representation = {id = 1}},
    }, entity_by_id = {['1'] = {id = 1, name = "orders", alias = "o"}},
    representations = {{
        id = 1, entity_id = 1, name = "primary", source_kind = "RELATION",
        source_schema = "MART", source_object = "ORDERS", alias = "o",
        role = "PRIMARY", priority = 1,
    }}})
    with_query(function(sql)
        if contains(sql, "COUNT(er.REPRESENTATION_ID)") then return {} end
        if contains(sql, "FROM SYS.EXA_ALL_TABLES") then return {{1}} end
        return {}
    end, function() api.validate_structural_rules(valid) end)
    assert_branch("validator.structure.valid", valid.error_count == 0, true)
end)

test("validator rejects malformed and column-incompatible F1 representations", function()
    local entity = {
        id = 1, name = "orders", alias = "o", source_schema = "MART",
        source_object = "ORDERS", primary_representation = {id = 1},
    }
    local primary = {
        id = 1, entity_id = 1, name = "primary", source_kind = "RELATION",
        source_schema = "MART", source_object = "ORDERS", alias = "o",
        role = "PRIMARY", priority = 1,
    }
    local archive = {
        id = 2, entity_id = 1, name = "archive", source_kind = "UNION",
        source_schema = "ARCHIVE", source_object = "ORDERS", alias = "old",
        role = "HISTORICAL", priority = 0, coverage_predicate = "year < 2020",
    }
    local ctx = validation_context({
        version_id = 2,
        entities = {entity},
        entity_by_id = {["1"] = entity},
        entity_name_by_id = {["1"] = "orders"},
        entity_alias_by_id = {["1"] = "O"},
        representations = {primary, archive},
        representations_by_entity = {["1"] = {primary, archive}},
        dimensions = {{id = 10, name = "amount", entity_id = 1,
            expression = "o.amount"}},
        facts = {}, metrics = {},
    })
    with_query(function(sql, params)
        if contains(sql, "COUNT(er.REPRESENTATION_ID)") then return {} end
        if contains(sql, "FROM SYS.EXA_ALL_TABLES") then return {{1}} end
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            return {{params.schema_name == "MART" and 1 or 0}}
        end
        return {}
    end, function()
        api.validate_structural_rules(ctx)
        api.validate_expressions(ctx, {})
    end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_036"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_017"))
    assert_contains(issue_for_rule(ctx, "SEMANTIC_MODEL_017").message, "archive")
end)

test("validator warns when the legacy key expression misses declared key columns", function()
    -- The legacy expression is a bootstrap hint, not a proof source, so a
    -- reader inspecting ENTITIES is the one it misleads: an order-grain
    -- expression on a line-grain entity is not unique at that grain.
    local entity = {id = 1, name = "order_line", alias = "ol",
        primary_key_expr = "CAST(ol.order_id AS VARCHAR(36))"}
    local composite = {
        id = 5, entity_id = 1, name = "order_line_pk", kind = "PRIMARY",
        columns = {
            {ordinal_position = 1, column_name = "order_id"},
            {ordinal_position = 2, column_name = "line_id"},
        },
    }
    local function context_for(key_expression)
        entity.primary_key_expr = key_expression
        return validation_context({
            version_id = 2,
            entities = {entity},
            entity_by_id = {["1"] = entity},
            entity_name_by_id = {["1"] = "order_line"},
            entity_alias_by_id = {["1"] = "OL"},
            unique_keys = {composite},
            unique_keys_by_entity = {["1"] = {composite}},
            dimensions = {}, facts = {}, metrics = {},
        })
    end

    local partial = context_for("CAST(ol.order_id AS VARCHAR(36))")
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_TABLES") then return {{1}} end
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{1}} end
        return {}
    end, function() api.validate_structural_rules(partial) end)
    assert_true(has_rule(partial, "SEMANTIC_MODEL_054"))
    local issue = issue_for_rule(partial, "SEMANTIC_MODEL_054")
    assert_equal(issue.severity, "WARNING")
    assert_contains(issue.message, "line_id")
    assert_contains(issue.message, "bootstrap hint only")

    -- Covering every key column is silent, whatever shape the expression has.
    local complete = context_for(
        "CAST(ol.order_id AS VARCHAR(36)) || '-' || CAST(ol.line_id AS VARCHAR(36))")
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_TABLES") then return {{1}} end
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{1}} end
        return {}
    end, function() api.validate_structural_rules(complete) end)
    assert_true(not has_rule(complete, "SEMANTIC_MODEL_054"))
end)

test("validator enforces F2 attribute binding ownership and expressions", function()
    local entity = {id = 1, name = "orders", alias = "o"}
    local representation = {id = 2, entity_id = 1, name = "archive", alias = "o",
        source_schema = "ARCHIVE", source_object = "ORDERS"}
    local dimension = {id = 10, name = "status", entity_id = 1,
        expression = "o.status"}
    local ctx = validation_context({
        entity_by_id = {["1"] = entity},
        entity_name_by_id = {["1"] = "orders"},
        entity_alias_by_id = {["1"] = "O"},
        representations = {representation},
        dimensions = {dimension}, dimension_by_id = {["10"] = dimension},
        facts = {}, fact_by_id = {}, metrics = {},
        bindings_by_attribute = {['DIMENSION:10'] = {{id = 1}}},
        attribute_bindings = {
            {id = 1, entity_id = 1, attribute_type = "DIMENSION", attribute_id = 10,
                representation_id = 2, expression = "x.missing + QUARTER(o.created_at)",
                role = "INVALID", priority = 0},
            {id = 2, entity_id = 1, attribute_type = "DIMENSION", attribute_id = 10,
                representation_id = 2, expression = "o.status", role = "FALLBACK", priority = 2},
        },
    })
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {} end
        return {}
    end, function() api.validate_expressions(ctx, {}) end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_039"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_040"))
    assert_contains(issue_for_rule(ctx, "SEMANTIC_MODEL_040").message,
        "outside its representation")
end)

test("validator accepts valid F2 bindings and rejects dangling ownership", function()
    local entity = {id = 1, name = "orders", alias = "o"}
    local representation = {id = 2, entity_id = 1, name = "archive", alias = "o",
        source_schema = "ARCHIVE", source_object = "ORDERS"}
    local fact = {id = 20, name = "amount", entity_id = 1, expression = "o.amount"}
    local ctx = validation_context({
        entity_by_id = {["1"] = entity}, entity_name_by_id = {["1"] = "orders"},
        entity_alias_by_id = {["1"] = "O"}, representations = {representation},
        dimensions = {}, dimension_by_id = {}, facts = {fact}, fact_by_id = {["20"] = fact},
        metrics = {}, bindings_by_attribute = {['FACT:20'] = {{id = 1}}},
        attribute_bindings = {
            {id = 1, entity_id = 1, attribute_type = "FACT", attribute_id = 20,
                representation_id = 2, expression = "o.amount", role = "PREFER", priority = 1},
            {id = 2, entity_id = 9, attribute_type = "UNKNOWN", attribute_id = 99,
                representation_id = 99, expression = "o.amount", role = "FALLBACK", priority = 2},
        },
    })
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{1}} end
        return {}
    end, function() api.validate_expressions(ctx, {}) end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_039"))
    assert_true(not has_rule(ctx, "SEMANTIC_MODEL_040"))
end)

test("validator accepts canonical string functions in F2 bindings", function()
    local entity = {id = 1, name = "orders", alias = "o"}
    local representation = {id = 2, entity_id = 1, name = "archive", alias = "o",
        source_schema = "ARCHIVE", source_object = "ORDERS"}
    local dimension = {id = 10, name = "status", entity_id = 1,
        expression = "o.status"}
    local ctx = validation_context({
        entity_by_id = {["1"] = entity}, entity_name_by_id = {["1"] = "orders"},
        entity_alias_by_id = {["1"] = "O"}, representations = {representation},
        dimensions = {dimension}, dimension_by_id = {["10"] = dimension},
        facts = {}, fact_by_id = {}, metrics = {},
        bindings_by_attribute = {['DIMENSION:10'] = {{id = 1}}},
        attribute_bindings = {
            {id = 1, entity_id = 1, attribute_type = "DIMENSION", attribute_id = 10,
                representation_id = 2,
                expression = "REPLACE(SUBSTR(TRIM(LTRIM(RTRIM(UPPER(LOWER(o.status))))), 1, 3), '_', '-')",
                role = "PREFER", priority = 1},
        },
    })
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{1}} end
        return {}
    end, function() api.validate_expressions(ctx, {}) end)
    assert_true(not has_rule(ctx, "SEMANTIC_MODEL_040"))
end)

test("SEMANTIC_MODEL_040 names the permitted function set", function()
    local entity = {id = 1, name = "orders", alias = "o"}
    local representation = {id = 2, entity_id = 1, name = "archive", alias = "o",
        source_schema = "ARCHIVE", source_object = "ORDERS"}
    local dimension = {id = 10, name = "status", entity_id = 1,
        expression = "o.status"}
    local ctx = validation_context({
        entity_by_id = {["1"] = entity}, entity_name_by_id = {["1"] = "orders"},
        entity_alias_by_id = {["1"] = "O"}, representations = {representation},
        dimensions = {dimension}, dimension_by_id = {["10"] = dimension},
        facts = {}, fact_by_id = {}, metrics = {},
        bindings_by_attribute = {['DIMENSION:10'] = {{id = 1}}},
        attribute_bindings = {
            {id = 1, entity_id = 1, attribute_type = "DIMENSION", attribute_id = 10,
                representation_id = 2, expression = "QUARTER(o.status)",
                role = "PREFER", priority = 1},
        },
    })
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{1}} end
        return {}
    end, function() api.validate_expressions(ctx, {}) end)
    local message = issue_for_rule(ctx, "SEMANTIC_MODEL_040").message
    assert_contains(message, "Unsupported function in binding expression: QUARTER")
    assert_contains(message, "Permitted functions: ABS")
    assert_contains(message, "TRIM")
    assert_contains(message, "UPPER")
end)

test("F2 bindings monotonically repair renamed representation columns", function()
    local entity = {id = 1, name = "customer", alias = "c"}
    local primary = {id = 1, entity_id = 1, name = "primary", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMERS"}
    local alternate = {id = 2, entity_id = 1, name = "renamed", alias = "c",
        source_schema = "F2PROBE", source_object = "CUSTOMERS_RENAMED"}
    local loyalty = {id = 10, name = "loyalty_tier", entity_id = 1,
        expression = "c.loyalty_tier"}
    local city = {id = 11, name = "city", entity_id = 1,
        expression = "c.city"}
    local default_loyalty = {id = 100, entity_id = 1, attribute_type = "DIMENSION",
        attribute_id = 10, representation_id = 1, expression = "c.loyalty_tier",
        role = "PREFER", priority = 1, is_default = true}
    local default_city = {id = 101, entity_id = 1, attribute_type = "DIMENSION",
        attribute_id = 11, representation_id = 1, expression = "c.city",
        role = "PREFER", priority = 1, is_default = true}
    local tier_binding = {id = 102, entity_id = 1, attribute_type = "DIMENSION",
        attribute_id = 10, representation_id = 2, expression = "c.tier_code",
        role = "PREFER", priority = 1, is_default = false}
    local city_binding = {id = 103, entity_id = 1, attribute_type = "DIMENSION",
        attribute_id = 11, representation_id = 2, expression = "c.town_name",
        role = "PREFER", priority = 1, is_default = false}

    local function context(explicit_city)
        local bindings = {default_loyalty, default_city, tier_binding}
        if explicit_city then bindings[#bindings + 1] = city_binding end
        return validation_context({
            entity_by_id = {["1"] = entity}, entity_name_by_id = {["1"] = "customer"},
            entity_alias_by_id = {["1"] = "C"},
            representations = {primary, alternate},
            representations_by_entity = {["1"] = {primary, alternate}},
            dimensions = {loyalty, city},
            dimension_by_id = {["10"] = loyalty, ["11"] = city},
            facts = {}, fact_by_id = {}, metrics = {},
            bindings_by_attribute = {
                ["DIMENSION:10"] = {default_loyalty, tier_binding},
                ["DIMENSION:11"] = explicit_city
                    and {default_city, city_binding} or {default_city},
            },
            attribute_bindings = bindings,
        })
    end
    local function validate(ctx)
        with_query(function(sql, params)
            if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
                local column_name = string.lower(tostring(params.column_name))
                local available = params.object_name == "CUSTOMERS"
                    and (column_name == "loyalty_tier" or column_name == "city")
                    or params.object_name == "CUSTOMERS_RENAMED"
                    and (column_name == "tier_code" or column_name == "town_name")
                return {{available and 1 or 0}}
            end
            return {}
        end, function() api.validate_expressions(ctx, {}) end)
    end

    local partial = context(false)
    validate(partial)
    assert_true(has_rule(partial, "SEMANTIC_MODEL_017"))
    assert_contains(issue_for_rule(partial, "SEMANTIC_MODEL_017").message, "CITY")
    assert_true(not string.find(issue_for_rule(partial, "SEMANTIC_MODEL_017").message,
        "LOYALTY_TIER", 1, true))

    local complete = context(true)
    validate(complete)
    assert_true(not has_rule(complete, "SEMANTIC_MODEL_017"))
    assert_true(not has_rule(complete, "SEMANTIC_MODEL_040"))
end)

test("F2 identity mismatches prescribe canonical views and Phase F5", function()
    local customer = {id = 1, name = "customer", alias = "c"}
    local order = {id = 2, name = "order", alias = "o"}
    local primary = {id = 10, entity_id = 1, name = "primary", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMERS"}
    local lowercase = {id = 11, entity_id = 1, name = "mongo", alias = "c",
        source_schema = "SRC_MONGO", source_object = "CUSTOMERS"}
    local order_primary = {id = 12, entity_id = 2, name = "primary", alias = "o",
        source_schema = "HUB", source_object = "ORDERS"}
    local unique_key = {id = 20, entity_id = 1, name = "customer_pk",
        kind = "PRIMARY", columns = {
            {ordinal_position = 1, column_name = "CUSTOMER_ID"},
        }}
    local relationship = {name = "order_customer", from_entity_id = 2,
        to_entity_id = 1, cardinality = "MANY_TO_ONE", key_mappings = {
            {ordinal_position = 1, from_column_name = "CUSTOMER_ID",
                to_column_name = "CUSTOMER_ID"},
        }}
    local ctx = validation_context({
        entities = {customer, order},
        entity_by_id = {["1"] = customer, ["2"] = order},
        entity_name_by_id = {["1"] = "customer", ["2"] = "order"},
        representations = {primary, lowercase, order_primary},
        representations_by_entity = {
            ["1"] = {primary, lowercase}, ["2"] = {order_primary},
        },
        unique_keys = {unique_key},
        unique_keys_by_entity = {["1"] = {unique_key}},
        relationships = {relationship},
    })
    with_query(function(sql, params)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            -- The quoted MongoDB key is physically lowercase and therefore
            -- does not satisfy the model's canonical CUSTOMER_ID contract.
            return {{params.schema_name == "SRC_MONGO" and 0 or 1}}
        end
        return {}
    end, function()
        api.validate_unique_keys(ctx)
        api.validate_relationship_key_mappings(ctx)
    end)
    local key_issue = issue_for_rule(ctx, "SEMANTIC_MODEL_029")
    local mapping_issue = issue_for_rule(ctx, "SEMANTIC_MODEL_050")
    assert_true(key_issue ~= nil)
    assert_true(mapping_issue ~= nil)
    assert_contains(key_issue.message, "certified semantic identity")
    assert_contains(mapping_issue.message, "mongo")
    assert_contains(mapping_issue.message, "anchored DIRECT identity")
end)

test("a metric must be based on the entity its facts belong to", function()
    -- The compiler renders a fact's expression against the *metric's* base
    -- entity FROM clause and never joins the fact's own entity, so a mismatch
    -- compiled to SQL referencing an alias it never joined -- STATUS = OK and a
    -- runtime "object O.FREIGHT_AMOUNT not found". Both directions failed that
    -- way, so this is not the fan-out question the grain proofs already answer.
    local order_line = {id = 1, name = "order_line", alias = "ol"}
    local order = {id = 2, name = "order", alias = "o"}
    local fact = {id = 30, entity_id = 2, name = "freight_fact",
        expression = "o.freight_amount"}
    local metric = {id = 40, name = "freight_total", base_entity_id = 1,
        expression = "SUM(freight_fact)", metric_type = "SIMPLE"}
    local ctx = validation_context({
        entities = {order_line, order},
        facts = {fact},
        metrics = {metric},
        -- load_model builds this from the catalog; a synthetic ctx has to supply
        -- it, and the message is only useful if it can name both entities.
        entity_by_id = {["1"] = order_line, ["2"] = order},
    })
    ctx.metric_by_id = {[tostring(metric.id)] = metric}
    with_query(function(sql)
        if contains(sql, "METRIC_DEPENDENCIES") then
            return {{40, "FACT", 30}}
        end
        return {}
    end, function()
        api.validate_metric_plannability(ctx)
    end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_061"))
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_061")
    -- Both entities and the fact are named, or the reader cannot tell which end
    -- to move.
    assert_contains(issue.message, "order_line")
    assert_contains(issue.message, "order")
    assert_contains(issue.message, "freight_fact")

    -- The matching case is silent.
    local matched_metric = {id = 41, name = "ok_metric", base_entity_id = 2,
        expression = "SUM(freight_fact)", metric_type = "SIMPLE"}
    local clean = validation_context({
        entities = {order_line, order}, facts = {fact}, metrics = {matched_metric},
        entity_by_id = {["1"] = order_line, ["2"] = order},
    })
    clean.metric_by_id = {[tostring(matched_metric.id)] = matched_metric}
    with_query(function(sql)
        if contains(sql, "METRIC_DEPENDENCIES") then return {{41, "FACT", 30}} end
        return {}
    end, function()
        api.validate_metric_plannability(clean)
    end)
    assert_true(not has_rule(clean, "SEMANTIC_MODEL_061"))
end)

test("validator proves F1 representation grain and key-set equivalence", function()
    local entity = {id = 1, name = "customers", alias = "c"}
    -- Roles are set because the recovery suffix on _037/_038 is only offered for
    -- an ALTERNATE -- there is nothing to "complete or remove" about a primary.
    local primary = {id = 1, entity_id = 1, name = "primary", alias = "c",
        role = "PRIMARY", source_schema = "HUB", source_object = "CUSTOMERS"}
    local duplicate = {id = 2, entity_id = 1, name = "duplicate", alias = "c",
        role = "ALTERNATE", source_schema = "HUB", source_object = "CUSTOMERS_DUP"}
    local half = {id = 3, entity_id = 1, name = "half", alias = "c",
        role = "ALTERNATE", source_schema = "HUB", source_object = "CUSTOMERS_HALF"}
    local swapped = {id = 4, entity_id = 1, name = "swapped", alias = "c",
        role = "ALTERNATE", source_schema = "HUB", source_object = "CUSTOMERS_SWAPPED"}
    entity.primary_representation = primary
    local unique_key = {id = 10, entity_id = 1, name = "customer_pk",
        columns = {{ordinal_position = 1, column_name = "CUSTOMER_ID"}}}
    local ctx = validation_context({
        entities = {entity},
        representations = {primary, duplicate, half, swapped},
        representations_by_entity = {["1"] = {primary, duplicate, half, swapped}},
        unique_keys_by_entity = {["1"] = {unique_key}},
        entity_name_by_id = {["1"] = "customers"},
    })
    local primary_distinct_probes = 0
    with_query(function(sql)
        local normalized = tostring(sql):gsub("%s+", " ")
        if contains(normalized, "FROM SYS.EXA_ALL_COLUMNS") then
            return {{"CUSTOMER_ID"}}
        end
        if contains(normalized, " MINUS ") then return {{1}} end
        local grouped = contains(normalized, "FROM (SELECT")
        if contains(normalized, '"CUSTOMERS_DUP"') then return {{grouped and 2 or 4}} end
        if contains(normalized, '"CUSTOMERS_HALF"') then return {{1}} end
        if contains(normalized, '"CUSTOMERS_SWAPPED"') then return {{2}} end
        if contains(normalized, '"CUSTOMERS"') then
            if grouped then primary_distinct_probes = primary_distinct_probes + 1 end
            return {{2}}
        end
        error("unexpected equivalence probe: " .. normalized)
    end, function()
        api.validate_representation_data_equivalence(ctx)
    end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_037"))
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_038"))
    assert_contains(issue_for_rule(ctx, "SEMANTIC_MODEL_037").message,
        "does not preserve grain")
    assert_equal(primary_distinct_probes, 1)
    -- _038 carries the recovery suffix its siblings do. It was the one message
    -- in the family without it across three studies, and it is the most likely
    -- first F3 encounter -- a modeller who hits it otherwise sees two row counts
    -- and nothing to do about them. A key-set difference means the source is not
    -- an *equivalent* representation, so the remedy is exactly the one the
    -- shared helper states: declare coverage, give it an identity, or remove it.
    assert_contains(issue_for_rule(ctx, "SEMANTIC_MODEL_038").message,
        "REMOVE_ENTITY_REPRESENTATION")
end)

test("validator accepts contiguous F3 coverage and rejects boundary gaps", function()
    local entity = {id = 1, name = "orders", alias = "o"}
    local cold = {id = 1, entity_id = 1, name = "cold", alias = "o",
        source_schema = "LAKE", source_object = "ORDERS", source_kind = "VIRTUAL_SCHEMA",
        coverage_predicate = "o.order_ts < TIMESTAMP '2026-01-01 00:00:00'",
        valid_to = "2026-01-01 00:00:00"}
    local hot = {id = 2, entity_id = 1, name = "hot", alias = "o",
        source_schema = "MART", source_object = "ORDERS", source_kind = "RELATION",
        coverage_predicate = "o.order_ts >= TIMESTAMP '2026-01-01 00:00:00'",
        valid_from = "2026-01-01 00:00:00"}
    local function context()
        return validation_context({
            entities = {entity},
            metrics = {{id = 10, name = "revenue", base_entity_id = 1}},
            representations_by_entity = {["1"] = {cold, hot}},
        })
    end
    local valid = context()
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{1}} end
        error("unexpected coverage SQL: " .. tostring(sql))
    end, function() api.validate_partition_coverage(valid, entity) end)
    assert_equal(valid.error_count, 0)

    local invalid = context()
    cold.valid_to = "2025-12-31 00:00:00"
    with_query(function() return {{1}} end, function()
        api.validate_partition_coverage(invalid, entity)
    end)
    assert_true(has_rule(invalid, "SEMANTIC_MODEL_042"))
    cold.valid_to = "2026-01-01 00:00:00"
end)

test("validator enumerates missing dimension and fact bindings on F3 partitions", function()
    local entity = {id = 1, name = "shipment", alias = "s"}
    local cold = {id = 1, entity_id = 1, name = "cold", alias = "s",
        coverage_predicate = "s.ship_date < TIMESTAMP '2026-07-01 00:00:00'"}
    local hot = {id = 2, entity_id = 1, name = "hot", alias = "s",
        coverage_predicate = "s.ship_date >= TIMESTAMP '2026-07-01 00:00:00'"}
    local ship_date = {id = 10, name = "ship_date", entity_id = 1,
        expression = "s.ship_date"}
    local ship_cost = {id = 20, name = "ship_cost", entity_id = 1,
        expression = "s.cost_usd"}
    local date_binding = {representation_id = 1}
    local cost_binding = {representation_id = 2}
    local ctx = validation_context({
        entities = {entity}, entity_by_id = {["1"] = entity},
        representations_by_entity = {["1"] = {cold, hot}},
        dimensions = {ship_date}, facts = {ship_cost},
        bindings_by_attribute = {
            ["DIMENSION:10"] = {date_binding},
            ["FACT:20"] = {cost_binding},
        },
    })

    api.validate_partition_attribute_bindings(ctx)

    assert_equal(ctx.error_count, 2)
    assert_equal(ctx.issues[1].rule_code, "SEMANTIC_MODEL_052")
    assert_contains(ctx.issues[1].object_name, "ship_date@hot")
    assert_contains(ctx.issues[1].message, "ADD_ATTRIBUTE_BINDING")
    assert_contains(ctx.issues[2].object_name, "ship_cost@cold")
end)

test("validator rejects F3 predicates that disagree with declared intervals", function()
    local entity = {id = 1, name = "web_session", alias = "w"}
    local cold = {id = 1, entity_id = 1, name = "cold", alias = "w",
        source_schema = "LAKE", source_object = "WEB_SESSION",
        coverage_predicate = "w.ts < TIMESTAMP '2026-06-01 00:00:00'",
        valid_to = "2026-05-01 00:00:00.000000"}
    local hot = {id = 2, entity_id = 1, name = "hot", alias = "w",
        source_schema = "MART", source_object = "WEB_SESSION",
        coverage_predicate = "w.ts >= TIMESTAMP '2026-05-01 00:00:00'",
        valid_from = "2026-05-01 00:00:00"}
    local function validate()
        local ctx = validation_context({
            entities = {entity},
            metrics = {{id = 10, name = "conversions", base_entity_id = 1}},
            representations_by_entity = {["1"] = {cold, hot}},
        })
        with_query(function(sql)
            if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{1}} end
            error("unexpected coverage SQL: " .. tostring(sql))
        end, function() api.validate_partition_coverage(ctx, entity) end)
        return ctx
    end

    local overlap = validate()
    assert_true(has_rule(overlap, "SEMANTIC_MODEL_042"))
    assert_contains(issue_for_rule(overlap, "SEMANTIC_MODEL_042").message,
        "timestamp literals must exactly match")

    cold.coverage_predicate = "w.ts < TIMESTAMP '2026-04-01 00:00:00'"
    local gap = validate()
    assert_true(has_rule(gap, "SEMANTIC_MODEL_042"))

    cold.coverage_predicate = "w.ts < TIMESTAMP '2026-05-01 00:00:00'"
    local valid = validate()
    assert_equal(valid.error_count, 0,
        valid.issues[1] and valid.issues[1].message or "valid coverage rejected")
end)

test("validator certifies bounded F3 predicates only in canonical form", function()
    local parsed = api.parse_partition_predicate(
        "o.order_ts >= TIMESTAMP '2026-01-01 00:00:00' "
            .. "AND o.order_ts < TIMESTAMP '2026-02-01 00:00:00'")
    assert_equal(#parsed, 2)
    assert_equal(parsed[1].key_expression, "O.order_ts")
    assert_equal(parsed[1].operator, ">=")
    assert_equal(parsed[2].operator, "<")
    assert_equal(api.parse_partition_predicate(
        "YEAR(o.order_ts) >= TIMESTAMP '2026-01-01 00:00:00'"), nil)
    assert_equal(api.parse_partition_predicate(
        "o.order_ts < TIMESTAMP '2026-01-01 00:00:00' OR 1 = 1"), nil)
end)

test("validator rejects partitioning an entity used only as a joined dimension", function()
    local customer = {id = 1, name = "customer", alias = "c"}
    local primary = {id = 1, entity_id = 1, name = "primary", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMER",
        coverage_predicate = "c.signup_date < TIMESTAMP '2025-01-01 00:00:00'",
        valid_to = "2025-01-01 00:00:00"}
    local local_copy = {id = 2, entity_id = 1, name = "cust_local", alias = "c",
        source_schema = "MART", source_object = "CUSTOMER",
        coverage_predicate = "c.signup_date >= TIMESTAMP '2025-01-01 00:00:00'",
        valid_from = "2025-01-01 00:00:00"}
    local metrics = {
        {id = 10, name = "sessions", base_entity_id = 2},
        {id = 11, name = "orders", base_entity_id = 3},
    }
    local function validate(metric_rows)
        local ctx = validation_context({
            entities = {customer}, metrics = metric_rows,
            representations_by_entity = {["1"] = {primary, local_copy}},
        })
        with_query(function(sql)
            if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{1}} end
            error("unexpected coverage SQL: " .. tostring(sql))
        end, function() api.validate_partition_coverage(ctx, customer) end)
        return ctx
    end

    local invalid = validate(metrics)
    assert_true(has_rule(invalid, "SEMANTIC_MODEL_043"))
    local issue = issue_for_rule(invalid, "SEMANTIC_MODEL_043")
    assert_equal(issue.object_name, "customer")
    assert_contains(issue.message, "base entity of no active metric")
    assert_contains(issue.message, "partitioned joined dimensions are unsupported")

    local authoring = validate({})
    assert_true(not has_rule(authoring, "SEMANTIC_MODEL_043"))

    metrics[#metrics + 1] = {id = 12, name = "customer_count", base_entity_id = 1}
    local valid = validate(metrics)
    assert_true(not has_rule(valid, "SEMANTIC_MODEL_043"))
end)

test("validator rejects partial and malformed F3 coverage contracts", function()
    local entity = {id = 1, name = "orders", alias = "o"}
    local primary = {id = 1, entity_id = 1, name = "primary", alias = "o",
        source_schema = "MART", source_object = "ORDERS",
        coverage_predicate = "x.other_day < MAGIC(o.missing_day)"}
    local alternate = {id = 2, entity_id = 1, name = "archive", alias = "o",
        source_schema = "LAKE", source_object = "ORDERS",
        coverage_predicate = "o.order_ts >= TIMESTAMP '2026-02-01 00:00:00'",
        valid_from = "2026-02-01 00:00:00", valid_to = "2026-01-01 00:00:00"}
    local malformed = validation_context({
        entities = {entity},
        representations_by_entity = {["1"] = {primary, alternate}},
    })
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {} end
        error("unexpected malformed coverage SQL: " .. tostring(sql))
    end, function() api.validate_partition_coverage(malformed, entity) end)
    assert_true(has_rule(malformed, "SEMANTIC_MODEL_042"))
    assert_true(malformed.error_count >= 5)

    alternate.coverage_predicate = nil
    alternate.valid_from = nil
    alternate.valid_to = nil
    local partial = validation_context({
        entities = {entity},
        representations_by_entity = {["1"] = {primary, alternate}},
    })
    api.validate_partition_coverage(partial, entity)
    assert_true(has_rule(partial, "SEMANTIC_MODEL_042"))
end)

test("validator proves partition grain without requiring equal key sets", function()
    local entity = {id = 1, name = "orders", alias = "o"}
    local cold = {id = 1, entity_id = 1, name = "cold", alias = "o",
        source_schema = "LAKE", source_object = "ORDERS",
        coverage_predicate = "o.order_ts < TIMESTAMP '2026-01-01 00:00:00'"}
    local hot = {id = 2, entity_id = 1, name = "hot", alias = "o",
        source_schema = "MART", source_object = "ORDERS",
        coverage_predicate = "o.order_ts >= TIMESTAMP '2026-01-01 00:00:00'"}
    entity.primary_representation = hot
    local unique_key = {id = 10, entity_id = 1, name = "order_pk",
        columns = {{ordinal_position = 1, column_name = "ORDER_ID"}}}
    local ctx = validation_context({
        entities = {entity},
        representations_by_entity = {["1"] = {cold, hot}},
        unique_keys_by_entity = {["1"] = {unique_key}},
        entity_name_by_id = {["1"] = "orders"},
    })
    local minus_count = 0
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then return {{"ORDER_ID"}} end
        if contains(sql, " MINUS ") then minus_count = minus_count + 1 end
        return {{4}}
    end, function() api.validate_representation_data_equivalence(ctx) end)
    assert_equal(ctx.error_count, 0)
    assert_equal(minus_count, 0)
end)

test("validator skips F1 source probes after a local validation error", function()
    local entity = {id = 1, name = "customers", alias = "c"}
    local primary = {id = 1, entity_id = 1, name = "primary", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMERS"}
    local alternate = {id = 2, entity_id = 1, name = "remote", alias = "c",
        source_schema = "REMOTE", source_object = "CUSTOMERS"}
    entity.primary_representation = primary
    local unique_key = {id = 10, entity_id = 1, name = "customer_pk",
        columns = {{ordinal_position = 1, column_name = "CUSTOMER_ID"}}}
    local ctx = validation_context({
        error_count = 1,
        entities = {entity},
        representations_by_entity = {["1"] = {primary, alternate}},
        unique_keys_by_entity = {["1"] = {unique_key}},
    })
    local query_count = 0
    with_query(function()
        query_count = query_count + 1
        return {}
    end, function()
        api.validate_representation_data_equivalence(ctx)
    end)
    assert_equal(query_count, 0)
end)

test("validator requires a bounded session timeout for every multi-representation probe", function()
    local entity = {id = 1, name = "customers"}
    local primary = {id = 1, entity_id = 1, name = "primary",
        source_kind = "RELATION"}
    local remote = {id = 2, entity_id = 1, name = "remote",
        source_kind = "RELATION"}
    local function context()
        return validation_context({
            model_name = "sales",
            entities = {entity},
            representations_by_entity = {["1"] = {primary, remote}},
        })
    end

    local unlimited = context()
    with_query(function(sql)
        assert_contains(sql, "FROM EXA_PARAMETERS")
        return {{0}}
    end, function()
        assert_true(not api.validate_representation_probe_timeout(unlimited))
    end)
    assert_true(has_rule(unlimited, "SEMANTIC_MODEL_041"))
    assert_equal(issue_for_rule(unlimited, "SEMANTIC_MODEL_041").severity,
        "PRECONDITION")
    assert_equal(unlimited.error_count, 0)
    assert_equal(unlimited.precondition_count, 1)
    assert_contains(issue_for_rule(unlimited, "SEMANTIC_MODEL_041").message,
        "ALTER SESSION SET QUERY_TIMEOUT=60")

    local bounded = context()
    with_query(function() return {{30}} end, function()
        assert_true(api.validate_representation_probe_timeout(bounded))
    end)
    assert_equal(bounded.error_count, 0)

    local excessive = context()
    with_query(function() return {{120}} end, function()
        assert_true(not api.validate_representation_probe_timeout(excessive))
    end)
    assert_true(has_rule(excessive, "SEMANTIC_MODEL_041"))
end)

local function fusion_validation_context(strategy)
    local entity = {id = 1, name = "customers", alias = "c"}
    local primary = {id = 10, entity_id = 1, name = "mdm", alias = "c",
        source_schema = "MDM", source_object = "CUSTOMERS", authority_role = "AUTHORITATIVE"}
    local alternate = {id = 11, entity_id = 1, name = "crm", alias = "c",
        source_schema = "CRM", source_object = "CUSTOMERS", authority_role = "SUPPLEMENTAL"}
    entity.primary_representation = primary
    local dimension = {id = 20, entity_id = 1, name = "customer_name"}
    local unique_key = {id = 30, entity_id = 1, name = "customer_pk",
        columns = {{ordinal_position = 1, column_name = "CUSTOMER_ID"}}}
    return validation_context({
        entities = {entity},
        entity_by_id = {["1"] = entity},
        representations = {primary, alternate},
        representations_by_entity = {["1"] = {primary, alternate}},
        dimension_by_id = {["20"] = dimension},
        unique_keys_by_entity = {["1"] = {unique_key}},
        bindings_by_attribute = {["DIMENSION:20"] = {
            {id = 40, entity_id = 1, attribute_type = "DIMENSION", attribute_id = 20,
                representation_id = 10, expression = "c.customer_name", role = "PREFER", priority = 1},
            {id = 41, entity_id = 1, attribute_type = "DIMENSION", attribute_id = 20,
                representation_id = 11, expression = "c.display_name", role = "PREFER", priority = 1},
        }},
        attribute_fusion_policies = {{entity_id = 1, attribute_type = "DIMENSION",
            attribute_id = 20, strategy = strategy}},
    })
end

test("F4 validator requires coherent authority identity and contributors", function()
    local valid = fusion_validation_context("RECONCILE")
    api.validate_fusion_policies(valid)
    assert_equal(valid.error_count, 0)

    local malformed = fusion_validation_context("RECONCILE")
    malformed.representations[1].authority_role = "UNKNOWN"
    malformed.representations[2].authority_role = "AUTHORITATIVE"
    malformed.attribute_fusion_policies[#malformed.attribute_fusion_policies + 1] = {
        entity_id = 1, attribute_type = "MEASURE", attribute_id = 999, strategy = "MERGE"}
    api.validate_fusion_policies(malformed)
    assert_true(has_rule(malformed, "SEMANTIC_MODEL_044"))
    assert_true(malformed.error_count >= 2)

    local unsafe = fusion_validation_context("COALESCE")
    unsafe.bindings_by_attribute["DIMENSION:20"] = {
        unsafe.bindings_by_attribute["DIMENSION:20"][1]}
    unsafe.unique_keys_by_entity["1"][1].columns[1].expression = "c.customer_id"
    unsafe.representations[1].coverage_predicate = "c.customer_id < 10"
    unsafe.representations[2].coverage_predicate = "c.customer_id >= 10"
    api.validate_fusion_policies(unsafe)
    assert_true(unsafe.error_count >= 3)
end)

test("F4 validator rejects COALESCE conflicts and reports RECONCILE decisions", function()
    local function run(strategy, count)
        local ctx = fusion_validation_context(strategy)
        with_query(function(sql, params)
            if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
                return {{params.column_name}}
            end
            assert_contains(sql, 'FROM "MDM"."CUSTOMERS" f4_left')
            assert_contains(sql, 'JOIN "CRM"."CUSTOMERS" f4_right')
            assert_contains(sql, 'f4_left."CUSTOMER_ID" = f4_right."CUSTOMER_ID"')
            assert_contains(sql, "f4_left.customer_name")
            assert_contains(sql, "f4_right.display_name")
            return {{count}}
        end, function()
            api.validate_fusion_conflicts(ctx)
        end)
        return ctx
    end

    local coalesced = run("COALESCE", 2)
    assert_true(has_rule(coalesced, "SEMANTIC_MODEL_045"))
    assert_equal(coalesced.error_count, 1)

    local reconciled = run("RECONCILE", 3)
    assert_true(has_rule(reconciled, "SEMANTIC_MODEL_046"))
    assert_equal(reconciled.warning_count, 1)

    local clean = run("COALESCE", 0)
    assert_equal(clean.error_count, 0)
end)

local function f5_identity_context()
    local entity = {id = 1, name = "customer", alias = "c"}
    local primary = {id = 10, entity_id = 1, name = "mdm", alias = "c",
        role = "PRIMARY", source_schema = "MDM", source_object = "CUSTOMERS"}
    local alternate = {id = 11, entity_id = 1, name = "crm", alias = "c",
        role = "ALTERNATE", source_schema = "CRM", source_object = "ACCOUNTS"}
    entity.primary_representation = primary
    local identity = {id = 20, entity_id = 1, name = "customer_identity",
        kind = "GLOBAL", data_type = "DECIMAL(18,0)", bindings = {}}
    local direct = {id = 30, entity_id = 1, identity_id = 20,
        representation_id = 10, expression = "c.customer_id", kind = "DIRECT"}
    local mapped = {id = 31, entity_id = 1, identity_id = 20,
        representation_id = 11, expression = "c.account_id", kind = "MAPPED",
        mapping = {id = 40, source_schema = "IDENTITY_MAP",
            source_object = "CUSTOMER_XREF", local_column = "ACCOUNT_ID",
            semantic_column = "CUSTOMER_ID", certification = "CERTIFIED"}}
    identity.bindings = {direct, mapped}
    identity.binding_by_representation = {["10"] = direct, ["11"] = mapped}
    return validation_context({
        entities = {entity}, entity_by_id = {["1"] = entity},
        entity_name_by_id = {["1"] = "customer"},
        representations = {primary, alternate},
        representations_by_entity = {["1"] = {primary, alternate}},
        semantic_identities = {identity}, identity_by_id = {["20"] = identity},
        identities_by_entity = {["1"] = {identity}},
        identity_bindings = {direct, mapped},
    })
end

test("F5 validator accepts complete certified representation identity metadata", function()
    local ctx = f5_identity_context()
    with_query(function(sql)
        if contains(sql, "SELECT COUNT(*)") then return {{1}} end
        error("unexpected F5 structural SQL: " .. tostring(sql))
    end, function()
        api.validate_semantic_identities(ctx)
    end)
    assert_equal(ctx.error_count, 0)

    local invalid = f5_identity_context()
    invalid.semantic_identities[1].kind = "FUZZY"
    invalid.semantic_identities[1].bindings[1].kind = "MAPPED"
    invalid.semantic_identities[1].bindings[1].mapping = nil
    invalid.semantic_identities[1].bindings[2].mapping.certification = "PROPOSED"
    invalid.semantic_identities[1].bindings[#invalid.semantic_identities[1].bindings + 1] =
        invalid.semantic_identities[1].bindings[2]
    with_query(function() return {{1}} end, function()
        api.validate_semantic_identities(invalid)
    end)
    assert_true(has_rule(invalid, "SEMANTIC_MODEL_047"))
    assert_true(has_rule(invalid, "SEMANTIC_MODEL_048"))
    assert_true(invalid.error_count >= 4)

    local malformed = f5_identity_context()
    local direct = malformed.semantic_identities[1].bindings[1]
    direct.mapping = {certification = "CERTIFIED"}
    direct.expression = "MEDIAN(other.customer_id)"
    malformed.semantic_identities[1].bindings[2].expression = "c.missing_account_id"
    malformed.semantic_identities[1].bindings[#malformed.semantic_identities[1].bindings + 1] = {
        id = 32, entity_id = 1, identity_id = 20, representation_id = 999,
        expression = "", kind = "DIRECT"}
    malformed.representations[1].coverage_predicate = "c.customer_id < 10"
    malformed.semantic_identities[#malformed.semantic_identities + 1] = {
        id = 21, entity_id = 999, name = "orphan", kind = "BUSINESS",
        data_type = nil, bindings = {}}
    malformed.semantic_identities[#malformed.semantic_identities + 1] = {
        id = 22, entity_id = 1, name = "customer_identity", kind = "GLOBAL",
        data_type = "DECIMAL(18,0)", bindings = {}}
    with_query(function(sql, params)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            return {{params.column_name == "missing_account_id" and 0 or 1}}
        end
        return {{1}}
    end, function()
        api.validate_semantic_identities(malformed)
    end)
    assert_true(malformed.error_count >= 4)
    assert_true(has_rule(malformed, "SEMANTIC_MODEL_047"))
    assert_true(has_rule(malformed, "SEMANTIC_MODEL_048"))
end)

test("F5 validator proves local grain mapping bijection and canonical key sets", function()
    local function run(mapping_semantic_count, key_difference)
        local ctx = f5_identity_context()
        with_query(function(sql)
            if contains(sql, "f5_map_semantic") then return {{mapping_semantic_count}} end
            if contains(sql, " MINUS ") then return {{key_difference}} end
            return {{3}}
        end, function()
            api.validate_semantic_identity_data(ctx)
        end)
        return ctx
    end

    local valid = run(3, 0)
    assert_equal(valid.error_count, 0)

    local non_bijective = run(2, 0)
    assert_true(has_rule(non_bijective, "SEMANTIC_MODEL_049"))
    assert_contains(issue_for_rule(non_bijective, "SEMANTIC_MODEL_049").message,
        "one-to-one")

    local divergent = run(3, 1)
    assert_true(has_rule(divergent, "SEMANTIC_MODEL_049"))
    local found_key_set = false
    for _, issue in ipairs(divergent.issues) do
        if issue.rule_code == "SEMANTIC_MODEL_049"
            and contains(issue.message, "Canonical semantic key set differs") then
            found_key_set = true
        end
    end
    assert_true(found_key_set)

    local duplicate_local = f5_identity_context()
    local probe_index = 0
    with_query(function(sql)
        if contains(sql, "f5_local_keys") then
            probe_index = probe_index + 1
            return {{probe_index == 1 and 2 or 3}}
        end
        if contains(sql, " MINUS ") then return {{0}} end
        return {{3}}
    end, function()
        api.validate_semantic_identity_data(duplicate_local)
    end)
    assert_true(has_rule(duplicate_local, "SEMANTIC_MODEL_049"))
    assert_contains(issue_for_rule(duplicate_local, "SEMANTIC_MODEL_049").message,
        "null or non-unique")

    local incomplete_mapping = f5_identity_context()
    with_query(function(sql)
        if contains(sql, "f5_mapped_local_keys") then return {{2}} end
        if contains(sql, " MINUS ") then return {{0}} end
        return {{3}}
    end, function()
        api.validate_semantic_identity_data(incomplete_mapping)
    end)
    assert_true(has_rule(incomplete_mapping, "SEMANTIC_MODEL_049"))
    assert_contains(issue_for_rule(incomplete_mapping, "SEMANTIC_MODEL_049").message,
        "not total")

    local probe_failure = f5_identity_context()
    with_query(function(sql)
        if contains(sql, "MINUS") then error("remote set comparison failed") end
        if contains(sql, "f5_map_semantic") then error("mapping scan failed") end
        return {{3}}
    end, function()
        api.validate_semantic_identity_data(probe_failure)
    end)
    assert_true(probe_failure.error_count >= 2)
    local saw_probe_failure = false
    for _, issue in ipairs(probe_failure.issues) do
        if contains(issue.message, "Could not probe certified identity mapping")
            or contains(issue.message, "Could not compare canonical semantic key sets") then
            saw_probe_failure = true
        end
    end
    assert_true(saw_probe_failure)
end)

test("F5 validator detects fusion conflicts through mapped semantic identity", function()
    local ctx = fusion_validation_context("COALESCE")
    local identity_ctx = f5_identity_context()
    local identity = identity_ctx.semantic_identities[1]
    ctx.semantic_identities = {identity}
    ctx.identities_by_entity = {['1'] = {identity}}
    local conflict_sql
    with_query(function(sql)
        conflict_sql = sql
        return {{1}}
    end, function()
        api.validate_fusion_conflicts(ctx)
    end)
    assert_contains(conflict_sql, 'FROM "MDM"."CUSTOMERS" f4_left')
    assert_contains(conflict_sql, 'FROM "CRM"."CUSTOMERS" f5_conflict_src_11')
    assert_contains(conflict_sql, 'JOIN "IDENTITY_MAP"."CUSTOMER_XREF" f5_conflict_map_31')
    assert_contains(conflict_sql, 'AS "F5_SEMANTIC_KEY"')
    assert_contains(conflict_sql, 'f4_left.customer_id = f4_right."F5_SEMANTIC_KEY"')
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_045"))
end)

test("F5.1 validator accepts anchored DIRECT relationship remaps", function()
    local order = {id = 1, name = "order", alias = "o"}
    local customer = {id = 2, name = "customer", alias = "c"}
    local order_primary = {id = 5, entity_id = 1, name = "primary", alias = "o",
        role = "PRIMARY", source_schema = "MART", source_object = "ORDERS"}
    local customer_primary = {id = 10, entity_id = 2, name = "primary", alias = "c",
        role = "PRIMARY", source_schema = "MDM", source_object = "CUSTOMERS"}
    local mongo = {id = 11, entity_id = 2, name = "mongo", alias = "c",
        role = "ALTERNATE", source_schema = "MONGO", source_object = "CUSTOMERS"}
    order.primary_representation = order_primary
    customer.primary_representation = customer_primary
    local unique_key = {id = 50, entity_id = 2, name = "customer_pk",
        columns = {{ordinal_position = 1, column_name = "CUSTOMER_ID"}}}
    local identity = {id = 60, entity_id = 2, name = "customer_identity",
        binding_by_representation = {}, bindings = {}}
    local primary_binding = {id = 70, representation_id = 10,
        kind = "DIRECT", expression = "c.CUSTOMER_ID"}
    local mongo_binding = {id = 71, representation_id = 11,
        kind = "DIRECT", expression = 'CAST(c."customer_id" AS DECIMAL(18,0))'}
    identity.bindings = {primary_binding, mongo_binding}
    identity.binding_by_representation = {['10'] = primary_binding, ['11'] = mongo_binding}
    local relationship = {id = 80, name = "order_to_customer",
        from_entity_id = 1, to_entity_id = 2,
        join_condition = "o.CUSTOMER_ID = c.CUSTOMER_ID",
        cardinality = "MANY_TO_ONE", join_type = "LEFT",
        key_mappings = {{ordinal_position = 1, from_column_name = "CUSTOMER_ID",
            to_column_name = "CUSTOMER_ID"}}}
    local function context()
        return validation_context({
            entities = {order, customer},
            entity_by_id = {['1'] = order, ['2'] = customer},
            entity_name_by_id = {['1'] = "order", ['2'] = "customer"},
            entity_alias_by_id = {['1'] = "O", ['2'] = "C"},
            representations = {order_primary, customer_primary, mongo},
            representations_by_entity = {
                ['1'] = {order_primary}, ['2'] = {customer_primary, mongo}},
            unique_keys_by_entity = {['2'] = {unique_key}},
            semantic_identities = {identity},
            identities_by_entity = {['2'] = {identity}},
            relationships = {relationship},
        })
    end
    local function run(ctx)
        with_query(function(sql, params)
            if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
                if params.schema_name == "MONGO"
                    and params.column_name == "CUSTOMER_ID" then return {{0}} end
                return {{1}}
            end
            return {}
        end, function()
            api.validate_relationship_key_mappings(ctx)
            api.relationship_edges(ctx)
        end)
    end

    local valid = context()
    run(valid)
    assert_equal(valid.error_count, 0)
    assert_equal(valid.warning_count, 0)

    mongo_binding.kind = "MAPPED"
    local excluded = context()
    run(excluded)
    assert_equal(excluded.error_count, 0)
    assert_true(has_rule(excluded, "SEMANTIC_MODEL_050"))
    mongo_binding.kind = "DIRECT"
end)

test("validator bounds views over virtual schemas without dependency classification", function()
    local entity = {id = 1, name = "customers"}
    local primary = {id = 1, entity_id = 1, name = "primary",
        source_kind = "RELATION", source_schema = "HUB"}
    local remote = {id = 2, entity_id = 1, name = "remote",
        source_kind = "RELATION", source_schema = "HUBV",
        source_object = "CUSTOMERS_NORMALIZED"}
    local function context()
        return validation_context({
            model_name = "hub",
            entities = {entity},
            representations_by_entity = {["1"] = {primary, remote}},
        })
    end

    local unlimited = context()
    with_query(function(sql)
        assert_contains(sql, "FROM EXA_PARAMETERS")
        assert_true(not string.find(sql, "EXA_ALL_VIRTUAL_SCHEMAS", 1, true))
        assert_true(not string.find(sql, "EXA_ALL_DEPENDENCIES", 1, true))
        return {{0}}
    end, function()
        assert_true(not api.validate_representation_probe_timeout(unlimited))
    end)
    assert_true(has_rule(unlimited, "SEMANTIC_MODEL_041"))

    local bounded = context()
    with_query(function() return {{30}} end, function()
        assert_true(api.validate_representation_probe_timeout(bounded))
    end)
    assert_equal(bounded.error_count, 0)

    local single = validation_context({
        model_name = "hub",
        entities = {entity},
        representations_by_entity = {["1"] = {primary}},
    })
    local query_count = 0
    with_query(function(sql)
        query_count = query_count + 1
        return {{0}}
    end, function()
        assert_true(api.validate_representation_probe_timeout(single))
    end)
    assert_equal(query_count, 0)
end)

test("validator requires a key before claiming F1 equivalence", function()
    local entity = {id = 1, name = "customers", alias = "c"}
    local primary = {id = 1, entity_id = 1, name = "primary"}
    local alternate = {id = 2, entity_id = 1, name = "alternate"}
    entity.primary_representation = primary
    local ctx = validation_context({
        entities = {entity},
        representations_by_entity = {["1"] = {primary, alternate}},
        unique_keys_by_entity = {},
    })
    api.validate_representation_data_equivalence(ctx)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_037"))
end)

test("validator fails closed when an F1 data probe cannot execute", function()
    local entity = {id = 1, name = "customers", alias = "c"}
    local primary = {id = 1, entity_id = 1, name = "primary", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMERS"}
    local alternate = {id = 2, entity_id = 1, name = "remote", alias = "c",
        source_schema = "REMOTE", source_object = "CUSTOMERS"}
    entity.primary_representation = primary
    local unique_key = {id = 10, entity_id = 1, name = "customer_pk",
        columns = {{ordinal_position = 1, column_name = "CUSTOMER_ID"}}}
    local ctx = validation_context({
        entities = {entity},
        representations_by_entity = {["1"] = {primary, alternate}},
        unique_keys_by_entity = {["1"] = {unique_key}},
        entity_name_by_id = {["1"] = "customers"},
    })
    with_query(function(sql)
        if contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            return {{"CUSTOMER_ID"}}
        end
        error("remote source unavailable")
    end, function()
        api.validate_representation_data_equivalence(ctx)
    end)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_037"))
    assert_contains(issue_for_rule(ctx, "SEMANTIC_MODEL_037").message,
        "Could not prove")
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
        elseif contains(sql, "SELECT OBJECT_TYPE, OBJECT_ID, SYNONYM") then
            return {}
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

test("verified queries accept a renamed metric through its retained synonym", function()
    local renamed_metric = {id = 1, name = "gross_merchandise_value"}
    local ctx = validation_context({
        version_id = 2,
        metrics = {},
        metric_by_id = {['1'] = renamed_metric},
        metric_by_name = {GROSS_MERCHANDISE_VALUE = renamed_metric},
        dimension_by_id = {},
        dimension_by_name = {},
    })
    with_query(function(sql)
        if contains(sql, "GROUP BY UPPER(s.SYNONYM)")
            or contains(sql, "LEFT JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS so")
            or contains(sql, "FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS") then
            return {}
        elseif contains(sql, "SELECT OBJECT_TYPE, OBJECT_ID, SYNONYM") then
            return {{OBJECT_TYPE = "METRIC", OBJECT_ID = 1, SYNONYM = "total_revenue"}}
        elseif contains(sql, "SELECT QUERY_NAME, REQUEST_JSON") then
            return {{QUERY_NAME = "GMV by category", REQUEST_JSON =
                '{"metrics":["total_revenue"],"dimensions":[]}'}}
        end
        error("unexpected verified query synonym SQL: " .. tostring(sql))
    end, function() api.validate_agent_metadata(ctx) end)
    assert_true(not has_rule(ctx, "SEMANTIC_MODEL_023"))
end)

test("validator warns when a semantic view has metrics and no dimensions", function()
    -- BUG-F15's aggravating factor: dimensions refused during authoring left an
    -- object publishing a single grand-total column, and PUBLISH_MODEL only
    -- refuses at *zero* columns, so it shipped quietly.
    local ctx = validation_context({version_id = 2})
    with_query(function() return {{"ORDER_HEADER", 0, 2}} end, function()
        api.validate_object_dimension_coverage(ctx)
    end)
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_058")
    assert_equal(issue.severity, "WARNING")
    assert_contains(issue.message, "2 metric(s) and no dimensions")
    assert_contains(issue.message, "SEMANTIC_ADMIN_019")
    assert_branch("validator.object.dimension_coverage",
        has_rule(ctx, "SEMANTIC_MODEL_058"), true)

    -- An object with dimensions, and one with neither, are both left alone.
    local quiet = validation_context({version_id = 2})
    with_query(function()
        return {{"SALES", 3, 2}, {"EMPTY", 0, 0}}
    end, function() api.validate_object_dimension_coverage(quiet) end)
    assert_equal(#quiet.issues, 0)
    assert_branch("validator.object.dimension_coverage",
        has_rule(quiet, "SEMANTIC_MODEL_058"), false)
end)

test("validator rejects a metric the planner could never compile", function()
    -- BUG-F01 / BUG-F02: COUNT(*) has no fact input and AVG has no mergeable
    -- state on a partitioned entity. Both validated clean, published, and were
    -- reported ready by every agent surface, failing only when queried -- and
    -- taking SELECT * on the object with them. The gate uses the planner's own
    -- classification so it cannot disagree with what the compiler will decide.
    local function context_with(metric, entity_overrides)
        local entity = {id = 1, name = "order"}
        for name, value in pairs(entity_overrides or {}) do entity[name] = value end
        local ctx = validation_context({
            metrics = {metric},
            metric_by_id = {['30'] = metric},
            facts = {{id = 20, name = "freight", entity_id = 1,
                data_type = "DECIMAL(18,2)"}},
            entities = {entity},
            entity_by_id = {['1'] = entity},
            entity_name_by_id = {['1'] = "order"},
            representations_by_entity = {['1'] = entity_overrides
                and entity_overrides.representations or {}},
        })
        return ctx
    end

    local counted = {id = 30, name = "line_count", base_entity_id = 1,
        expression = "COUNT(*)", aggregation_function = "COUNT",
        metric_kind = "SIMPLE", inputs = {}, filters = {}}
    local no_grain = context_with(counted)
    with_query(function() return {} end, function()
        api.validate_metric_plannability(no_grain)
    end)
    local grain_issue = issue_for_rule(no_grain, "SEMANTIC_MODEL_056")
    assert_equal(grain_issue.severity, "ERROR")
    assert_contains(grain_issue.message, "METRIC_INPUT_GRAIN_MISSING")
    -- The remedy names both supported row-count forms.
    assert_contains(grain_issue.message, "COUNT(<fact>)")
    assert_contains(grain_issue.message, "SUM(<name>)")
    assert_branch("validator.metric.plannable", has_rule(no_grain, "SEMANTIC_MODEL_056"), true)

    -- A mergeable SUM over one fact is fine, partitioned or not.
    local summed = {id = 30, name = "total_freight", base_entity_id = 1,
        expression = "SUM(freight)", aggregation_function = "SUM",
        metric_kind = "SIMPLE", filters = {},
        inputs = {{role = "MEASURE", object_type = "FACT", object_id = 20,
            ordinal_position = 1}}}
    local clean = context_with(summed, {representations = {
        {id = 5, name = "primary", role = "PRIMARY",
            coverage_predicate = "o.order_date >= TIMESTAMP '2026-07-01 00:00:00'"},
        {id = 6, name = "cold", role = "ALTERNATE",
            coverage_predicate = "o.order_date < TIMESTAMP '2026-07-01 00:00:00'"},
    }})
    with_query(function() return {} end, function()
        api.validate_metric_plannability(clean)
    end)
    assert_equal(#clean.issues, 0)
    assert_branch("validator.metric.plannable", has_rule(clean, "SEMANTIC_MODEL_056"), false)

    -- AVG over the same partitioned entity can never be compiled.
    local averaged = {id = 30, name = "mean_freight", base_entity_id = 1,
        expression = "AVG(freight)", aggregation_function = "AVG",
        metric_kind = "SIMPLE", filters = {},
        inputs = {{role = "MEASURE", object_type = "FACT", object_id = 20,
            ordinal_position = 1}}}
    local partitioned = context_with(averaged, {representations = {
        {id = 5, name = "primary", role = "PRIMARY",
            coverage_predicate = "o.order_date >= TIMESTAMP '2026-07-01 00:00:00'"},
        {id = 6, name = "cold", role = "ALTERNATE",
            coverage_predicate = "o.order_date < TIMESTAMP '2026-07-01 00:00:00'"},
    }})
    with_query(function() return {} end, function()
        api.validate_metric_plannability(partitioned)
    end)
    local state_issue = issue_for_rule(partitioned, "SEMANTIC_MODEL_057")
    assert_equal(state_issue.severity, "ERROR")
    assert_contains(state_issue.message, "AVG")
    assert_contains(state_issue.message, "no mergeable aggregate state")
    assert_contains(state_issue.message, "'order' is partitioned")

    -- The same AVG on an unpartitioned entity stays valid: the single-branch
    -- renderer handles it, and the compiler still accepts it.
    local unpartitioned = context_with(averaged)
    with_query(function() return {} end, function()
        api.validate_metric_plannability(unpartitioned)
    end)
    assert_true(not has_rule(unpartitioned, "SEMANTIC_MODEL_057"))

    -- A model that already failed a structural rule is left to that rule.
    local already_broken = context_with(counted)
    already_broken.error_count = 1
    with_query(function() return {} end, function()
        api.validate_metric_plannability(already_broken)
    end)
    assert_equal(#already_broken.issues, 0)
end)

test("validator rejects metrics whose input grain spans entities", function()
    -- The other two shapes the planner cannot compile: one aggregate state over
    -- facts from two entities, and a non-mergeable aggregate over the same.
    local function context_with(metric)
        local order = {id = 1, name = "order"}
        local line = {id = 2, name = "order_line"}
        return validation_context({
            metrics = {metric},
            metric_by_id = {['30'] = metric},
            facts = {
                {id = 20, name = "freight", entity_id = 1, data_type = "DECIMAL(18,2)"},
                {id = 21, name = "net_revenue", entity_id = 2, data_type = "DECIMAL(18,2)"},
            },
            entities = {order, line},
            entity_by_id = {['1'] = order, ['2'] = line},
            entity_name_by_id = {['1'] = "order", ['2'] = "order_line"},
        })
    end
    local two_entity_inputs = {
        {role = "MEASURE", object_type = "FACT", object_id = 20, ordinal_position = 1},
        {role = "MEASURE", object_type = "FACT", object_id = 21, ordinal_position = 2},
    }

    local summed = {id = 30, name = "mixed_sum", base_entity_id = 1,
        expression = "SUM(freight)", aggregation_function = "SUM",
        metric_kind = "SIMPLE", filters = {}, inputs = two_entity_inputs}
    local ambiguous = context_with(summed)
    with_query(function() return {} end, function()
        api.validate_metric_plannability(ambiguous)
    end)
    assert_contains(issue_for_rule(ambiguous, "SEMANTIC_MODEL_056").message,
        "METRIC_INPUT_GRAIN_AMBIGUOUS")

    local averaged = {id = 30, name = "mixed_avg", base_entity_id = 1,
        expression = "AVG(freight)", aggregation_function = "AVG",
        metric_kind = "SIMPLE", filters = {}, inputs = two_entity_inputs}
    local unmergeable = context_with(averaged)
    with_query(function() return {} end, function()
        api.validate_metric_plannability(unmergeable)
    end)
    local issue = issue_for_rule(unmergeable, "SEMANTIC_MODEL_057")
    assert_contains(issue.message, "over facts from 2 entities")

    -- A metric with no inputs that is not a count gets the diagnosis without
    -- the row-count remedy, which would make no sense for it. (MIN and MAX are
    -- legacy aggregates rather than states: the single-branch renderer still
    -- compiles them from the expression, so they are not rejected here.)
    local summed_nothing = {id = 30, name = "orphan_sum", base_entity_id = 1,
        expression = "SUM(freight)", aggregation_function = "SUM",
        metric_kind = "SIMPLE", filters = {}, inputs = {}}
    local no_inputs = context_with(summed_nothing)
    with_query(function() return {} end, function()
        api.validate_metric_plannability(no_inputs)
    end)
    local plain = issue_for_rule(no_inputs, "SEMANTIC_MODEL_056")
    assert_contains(plain.message, "METRIC_INPUT_GRAIN_MISSING")
    assert_true(not string.find(plain.message, "row count", 1, true))
end)

test("validator invalidates a partitioned entity used as a joined dimension", function()
    -- BUG-F07: F3 applies only to an entity a metric is based on. Declaring
    -- coverage on an entity that another object reaches as a joined dimension
    -- made that object's published dimensions permanently unqueryable
    -- (SEMANTIC_REQUEST_074) with no validation error at all.
    local order = {id = 1, name = "order"}
    local line = {id = 2, name = "order_line"}
    local partitions = {
        {id = 5, name = "primary", role = "PRIMARY",
            coverage_predicate = "o.order_ts >= TIMESTAMP '2026-07-01 00:00:00'"},
        {id = 6, name = "cold", role = "ALTERNATE",
            coverage_predicate = "o.order_ts < TIMESTAMP '2026-07-01 00:00:00'"},
    }
    local freight = {id = 30, name = "total_freight", base_entity_id = 1,
        expression = "SUM(freight)", aggregation_function = "SUM",
        metric_kind = "SIMPLE", filters = {},
        inputs = {{role = "MEASURE", object_type = "FACT", object_id = 20,
            ordinal_position = 1}}}
    local revenue = {id = 31, name = "total_revenue", base_entity_id = 2,
        expression = "SUM(net_revenue)", aggregation_function = "SUM",
        metric_kind = "SIMPLE", filters = {},
        inputs = {{role = "MEASURE", object_type = "FACT", object_id = 21,
            ordinal_position = 1}}}
    local ship_mode = {id = 40, name = "ship_mode", entity_id = 1}
    local ctx = validation_context({
        version_id = 2,
        semantic_objects = {{root_entity_id = 1}, {root_entity_id = 2}},
        entities = {order, line},
        entity_by_id = {['1'] = order, ['2'] = line},
        entity_name_by_id = {['1'] = "order", ['2'] = "order_line"},
        representations_by_entity = {['1'] = partitions},
        metrics = {freight, revenue},
        metric_by_id = {['30'] = freight, ['31'] = revenue},
        dimensions = {ship_mode},
        dimension_by_id = {['40'] = ship_mode},
        facts = {
            {id = 20, name = "freight", entity_id = 1, data_type = "DECIMAL(18,2)"},
            {id = 21, name = "net_revenue", entity_id = 2, data_type = "DECIMAL(18,2)"},
        },
    })
    -- order_line reaches order safely; order reaches itself.
    local safe = {['2'] = {{from_id = 2, to_id = 1, name = "line_to_order",
        safe = true, reason = "OK"}}}
    with_query(function() return {} end, function()
        api.compute_metric_dimension_matrix(ctx, safe, safe)
    end)
    -- The order-grain metric keeps the dimension: it is based on the
    -- partitioned entity, which is exactly what F3 supports.
    assert_true(ctx.matrix['30']['40'].is_valid)
    -- The line-grain metric loses it.
    assert_true(not ctx.matrix['31']['40'].is_valid)
    assert_equal(ctx.matrix['31']['40'].reason_code,
        "FUSION_PARTITION_DIMENSION_UNSUPPORTED")
    assert_branch("validator.matrix.partitioned_dimension",
        ctx.matrix['31']['40'].is_valid, false)
    assert_branch("validator.matrix.partitioned_dimension",
        ctx.matrix['30']['40'].is_valid, true)

    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
            return {{"SALES", 31, "total_revenue", 40, "ship_mode"}}
        end
        return {}
    end, function() api.validate_visible_metric_dimension_pairs(ctx) end)
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_030")
    assert_contains(issue.message, "FUSION_PARTITION_DIMENSION_UNSUPPORTED")
    assert_contains(issue.message, "carries temporal coverage")
    assert_contains(issue.message, "metrics based at 'order'")
end)

test("coverage predicate errors name a DATE literal as the near-miss", function()
    -- BUG-F16: a DATE literal on a DATE column is the natural thing to write,
    -- and the canonical-form message read as if the interval did not match.
    local entity = {id = 1, name = "order"}
    local ctx = validation_context({
        entities = {entity},
        entity_by_id = {['1'] = entity},
        entity_name_by_id = {['1'] = "order"},
        metrics = {{id = 30, name = "total_freight", base_entity_id = 1}},
        representations_by_entity = {['1'] = {
            {id = 5, name = "primary", role = "PRIMARY", alias = "o",
                coverage_predicate = "o.order_date >= DATE '2026-07-01'",
                valid_from = "2026-07-01 00:00:00", valid_to = null},
            {id = 6, name = "cold", role = "ALTERNATE", alias = "o",
                coverage_predicate = "o.order_date < DATE '2026-07-01'",
                valid_from = null, valid_to = "2026-07-01 00:00:00"},
        }},
    })
    with_query(function() return {} end, function()
        api.validate_partition_coverage(ctx, entity)
    end)
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_042")
    assert_contains(issue.message, "Found DATE '2026-07-01'")
    assert_contains(issue.message, "must be a TIMESTAMP literal")
    assert_contains(issue.message, "TIMESTAMP '2026-07-01 00:00:00'")
    assert_branch("validator.coverage.literal_hint",
        string.find(issue.message, "Found DATE", 1, true) ~= nil, true)

    -- The canonical form gets no hint appended, and no error.
    local canonical = validation_context({
        entities = {entity},
        entity_by_id = {['1'] = entity},
        entity_name_by_id = {['1'] = "order"},
        metrics = {{id = 30, name = "total_freight", base_entity_id = 1}},
        representations_by_entity = {['1'] = {
            {id = 5, name = "primary", role = "PRIMARY", alias = "o",
                coverage_predicate = "o.order_date >= TIMESTAMP '2026-07-01 00:00:00'",
                valid_from = "2026-07-01 00:00:00", valid_to = null},
            {id = 6, name = "cold", role = "ALTERNATE", alias = "o",
                coverage_predicate = "o.order_date < TIMESTAMP '2026-07-01 00:00:00'",
                valid_from = null, valid_to = "2026-07-01 00:00:00"},
        }},
    })
    with_query(function() return {} end, function()
        api.validate_partition_coverage(canonical, entity)
    end)
    -- The canonical form gets no literal hint. (It still reports the stubbed
    -- column probe, which is what a database-free context can say about a
    -- physical column.)
    for _, reported in ipairs(canonical.issues) do
        assert_true(string.find(reported.message, "Found ", 1, true) == nil)
    end
    assert_branch("validator.coverage.literal_hint",
        string.find(canonical.issues[1].message, "Found ", 1, true) ~= nil, false)
end)

test("validator names the alternate representation blocking unrelated authoring", function()
    -- BUG-F06: registering an alternate on a draft is accepted and then blocks
    -- every later authoring call with a message about the representation. The
    -- recovery is REMOVE_ENTITY_REPRESENTATION, which no message named.
    local ctx = validation_context({representations = {
        {id = 5, name = "primary", role = "PRIMARY"},
        {id = 6, name = "crm", role = "ALTERNATE"},
    }})
    local remedy = api.alternate_representation_remedy(ctx, {"crm"})
    assert_contains(remedy, "Representation crm is registered but not yet usable")
    assert_contains(remedy, "REMOVE_ENTITY_REPRESENTATION")
    assert_contains(remedy, "SET_REPRESENTATION_COVERAGE_BATCH")
    assert_branch("validator.representation.remedy", remedy ~= "", true)

    -- Entity-qualified names resolve to the representation.
    assert_contains(api.alternate_representation_remedy(ctx, {"order.crm"}),
        "Representation order.crm is registered")

    -- A PRIMARY cannot be removed, so no remedy is offered for it, and none is
    -- offered when any named representation is not an alternate.
    assert_equal(api.alternate_representation_remedy(ctx, {"primary"}), "")
    assert_equal(api.alternate_representation_remedy(ctx, {"crm", "primary"}), "")
    assert_equal(api.alternate_representation_remedy(ctx, {}), "")
    assert_equal(api.alternate_representation_remedy(ctx, {"unknown"}), "")
    assert_branch("validator.representation.remedy",
        api.alternate_representation_remedy(ctx, {"primary"}) ~= "", false)

    -- BUG-G04: when the entity carries an F5 identity and this representation
    -- has no binding for it, the missing piece is knowable, so offering three
    -- ways to "complete the declaration" sends the reader looking. The
    -- documented F4-over-F5 use case reaches this every time, because
    -- ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY registers the representation and
    -- no compound form also binds the identity.
    local identity = {id = 90, name = "customer_identity", entity_id = 1,
        binding_by_representation = {['5'] = {id = 70, kind = "DIRECT"}}}
    local with_identity = validation_context({
        representations = {
            {id = 5, name = "primary", role = "PRIMARY", entity_id = 1},
            {id = 6, name = "crm", role = "ALTERNATE", entity_id = 1},
        },
        identities_by_entity = {['1'] = {identity}},
    })
    local specific = api.alternate_representation_remedy(with_identity, {"crm"})
    assert_contains(specific, "no binding for semantic identity 'customer_identity'")
    assert_contains(specific, "SEMANTIC_MODEL_060")
    assert_contains(specific, "ADD_IDENTITY_BINDING")
    assert_contains(specific, "ADD_IDENTITY_MAPPING_RELATION")
    assert_contains(specific, "REMOVE_ENTITY_REPRESENTATION")
    -- The generic three-option text must give way, not accumulate.
    if string.find(specific, "SET_REPRESENTATION_COVERAGE_BATCH", 1, true) ~= nil then
        error("specific remedy still offers the generic options: " .. specific)
    end
    assert_branch("validator.representation.identity_remedy",
        string.find(specific, "ADD_IDENTITY_BINDING", 1, true) ~= nil, true)

    -- The representation that *does* have a binding falls back to the generic
    -- remedy, so the specific one cannot fire on a complete identity.
    local bound = api.alternate_representation_remedy(
        validation_context({
            representations = {
                {id = 5, name = "primary", role = "PRIMARY", entity_id = 1},
                {id = 6, name = "crm", role = "ALTERNATE", entity_id = 1},
            },
            identities_by_entity = {['1'] = {{id = 90, name = "customer_identity",
                entity_id = 1,
                binding_by_representation = {['5'] = {id = 70, kind = "DIRECT"},
                    ['6'] = {id = 71, kind = "DIRECT"}}}}},
        }), {"crm"})
    assert_contains(bound, "SET_REPRESENTATION_COVERAGE_BATCH")
    assert_branch("validator.representation.identity_remedy",
        string.find(bound, "ADD_IDENTITY_BINDING", 1, true) ~= nil, false)
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
        metric_by_id = {
            ['10'] = {id = 10, name = "revenue", base_entity_id = 1},
            ['11'] = {id = 11, name = "orphan", base_entity_id = 99},
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
            {to_id = 3, name = "orders_items", safe = false, reason = "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED"},
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
    assert_equal(ctx.matrix['10']['22'].reason_code, "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED")
    assert_equal(ctx.matrix['10']['22'].path,
        "orders_items (rejected: ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED)")
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
    local fanout_issue = issue_for_rule(ctx, "SEMANTIC_MODEL_030")
    assert_contains(fanout_issue.message,
        "orders_items (rejected: ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED)")
    -- The remedy named must be one that exists. A fanning edge cannot be
    -- declared safe, so the message points at object membership.
    assert_contains(fanout_issue.message,
        "No relationship declaration makes a fanning traversal safe.")
    assert_contains(fanout_issue.message, "reachable from 'orders' without fan-out")
    assert_contains(fanout_issue.message, "object 'SALES'")
end)

test("validator warns when a shorter safe path won over a longer one", function()
    -- A tie in path length is an ERROR (AMBIGUOUS_RELATIONSHIP_PATH). An
    -- alternative of a different length passes the same gate silently, because
    -- the shortest path simply wins — yet the two can attribute an order to a
    -- different customer. The model has to say the choice exists.
    local ctx = validation_context({
        version_id = 2,
        semantic_objects = {{root_entity_id = 1}},
        entity_name_by_id = {['1'] = "orders", ['2'] = "stores", ['3'] = "customers"},
        metrics = {{id = 10, name = "revenue", base_entity_id = 1}},
        metric_by_id = {['10'] = {id = 10, name = "revenue", base_entity_id = 1}},
        dimensions = {{id = 20, name = "customer_region", entity_id = 3}},
        dimension_by_id = {['20'] = {id = 20, name = "customer_region", entity_id = 3}},
    })
    local safe = {
        ['1'] = {
            {from_id = 1, to_id = 3, name = "order_customer", safe = true, reason = "OK"},
            {from_id = 1, to_id = 2, name = "order_store", safe = true, reason = "OK"},
        },
        ['2'] = {{from_id = 2, to_id = 3, name = "store_customer", safe = true, reason = "OK"}},
    }
    with_query(function() return {} end, function()
        api.compute_metric_dimension_matrix(ctx, safe, safe)
    end)
    assert_true(ctx.matrix['10']['20'].is_valid)
    assert_equal(ctx.matrix['10']['20'].path, "order_customer")
    assert_equal(#ctx.matrix['10']['20'].alternate_paths, 1)
    assert_equal(ctx.matrix['10']['20'].alternate_paths[1].path,
        "order_store > store_customer")

    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
            return {{"SALES", 10, "revenue", 20, "customer_region"}}
        end
        return {}
    end, function() api.validate_visible_metric_dimension_pairs(ctx) end)
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_055")
    assert_equal(issue.severity, "WARNING")
    assert_contains(issue.message,
        "Entity orders reaches entity customers by more than one safe relationship path")
    assert_contains(issue.message, "selects order_customer because it is the shortest")
    assert_contains(issue.message, "not selected: order_store > store_customer")
    -- The pair is still valid: a warning, not a refusal.
    assert_true(not has_rule(ctx, "SEMANTIC_MODEL_030"))
    assert_branch("validator.matrix.path_alternatives",
        has_rule(ctx, "SEMANTIC_MODEL_055"), true)

    -- One safe path: nothing to warn about, and the matrix row stays clean.
    local single = validation_context({
        version_id = 2,
        semantic_objects = {{root_entity_id = 1}},
        entity_name_by_id = {['1'] = "orders", ['3'] = "customers"},
        metrics = {{id = 10, name = "revenue", base_entity_id = 1}},
        metric_by_id = {['10'] = {id = 10, name = "revenue", base_entity_id = 1}},
        dimensions = {{id = 20, name = "customer_region", entity_id = 3}},
        dimension_by_id = {['20'] = {id = 20, name = "customer_region", entity_id = 3}},
    })
    local one_path = {
        ['1'] = {{from_id = 1, to_id = 3, name = "order_customer", safe = true, reason = "OK"}},
    }
    with_query(function() return {} end, function()
        api.compute_metric_dimension_matrix(single, one_path, one_path)
    end)
    assert_equal(single.matrix['10']['20'].alternate_paths, nil)
    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
            return {{"SALES", 10, "revenue", 20, "customer_region"}}
        end
        return {}
    end, function() api.validate_visible_metric_dimension_pairs(single) end)
    assert_true(not has_rule(single, "SEMANTIC_MODEL_055"))
    assert_branch("validator.matrix.path_alternatives",
        has_rule(single, "SEMANTIC_MODEL_055"), false)
end)

test("validator matrix rejects metrics unreachable from published roots", function()
    local inserted = nil
    local ctx = validation_context({
        version_id = 2,
        semantic_objects = {{root_entity_id = 1}},
        entity_name_by_id = {['1'] = "order_line", ['2'] = "order", ['3'] = "shipment"},
        metrics = {{id = 10, name = "shipping_cost", base_entity_id = 3}},
        metric_by_id = {['10'] = {id = 10, name = "shipping_cost", base_entity_id = 3}},
        dimensions = {{id = 20, name = "order_id", entity_id = 2}},
    })
    local safe = {
        ['1'] = {{from_id = 1, to_id = 2, name = "line_to_order", safe = true, reason = "OK"}},
        ['3'] = {{from_id = 3, to_id = 2, name = "shipment_to_order", safe = true, reason = "OK"}},
    }
    local all = {
        ['1'] = safe['1'],
        ['2'] = {{from_id = 2, to_id = 3, name = "shipment_to_order", safe = false,
            reason = "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED"}},
        ['3'] = safe['3'],
    }
    with_query(function(sql, params)
        if contains(sql, "INSERT INTO SYS_SEMANTIC.METRIC_DIMENSION_MATRIX") then
            inserted = params
        end
        return {}
    end, function()
        api.compute_metric_dimension_matrix(ctx, safe, all)
    end)
    assert_equal(ctx.matrix['10']['20'].reason_code, "NO_SAFE_JOIN_PATH")
    assert_equal(ctx.matrix['10']['20'].path,
        "line_to_order > shipment_to_order (rejected: ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED)")
    assert_equal(inserted.relationship_path, ctx.matrix['10']['20'].path)

    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
            return {{"COMMERCE", 10, "shipping_cost", 20, "order_id"}}
        end
        return {}
    end, function() api.validate_visible_metric_dimension_pairs(ctx) end)
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_030")
    assert_contains(issue.message,
        "Declare a semantic object rooted at 'shipment', or remove this metric from object 'COMMERCE'.")
end)

test("a NULL placeholder preferred over real data is refused", function()
    -- VP-002. The canonical fusion case -- an attribute only the supplemental
    -- source carries -- forces the primary's binding to be a CAST(NULL AS ...)
    -- placeholder. The compiler picks a whole representation per entity and
    -- takes the candidate needing the fewest FALLBACK bindings first, so a
    -- PREFER placeholder beats a PREFER binding that has the data and every
    -- row comes back NULL. Each binding is individually well-formed; the pair
    -- is the defect, which is why nothing else reports it.
    local ctx = validation_context({
        model_name = "sales",
        dimension_by_id = {['10'] = {id = 10, name = "customer_churn_risk", entity_id = 1}},
        representations = {
            {id = 100, entity_id = 1, name = "primary", role = "PRIMARY"},
            {id = 101, entity_id = 1, name = "crm", role = "ALTERNATE"},
        },
        bindings_by_attribute = {
            ["DIMENSION:10"] = {
                {attribute_type = "DIMENSION", attribute_id = 10, representation_id = 100,
                    expression = "CAST(NULL AS VARCHAR(10))", role = "PREFER", priority = 1},
                {attribute_type = "DIMENSION", attribute_id = 10, representation_id = 101,
                    expression = "c.churn_risk", role = "PREFER", priority = 20},
            },
        },
    })
    api.validate_null_placeholder_bindings(ctx)
    assert_true(has_rule(ctx, "SEMANTIC_MODEL_063"))
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_063")
    assert_equal(issue.severity, "ERROR")
    assert_equal(issue.object_name, "customer_churn_risk@primary")
    -- The message has to carry the repair, not just the verdict: the caller
    -- cannot see which of two well-formed bindings the compiler will take.
    assert_contains(issue.message, "REPLACE_ATTRIBUTE_BINDING")
    assert_contains(issue.message, "'FALLBACK'")
    assert_branch("validator.null_placeholder", true, true)
end)

test("a NULL placeholder is fine as a FALLBACK, or when nothing else has data",
function()
    -- Declared FALLBACK, the placeholder is exactly right: it is how an
    -- entity says one of its sources does not carry the column.
    local declared = validation_context({
        model_name = "sales",
        dimension_by_id = {['10'] = {id = 10, name = "churn", entity_id = 1}},
        representations = {{id = 100, entity_id = 1, name = "primary", role = "PRIMARY"}},
        bindings_by_attribute = {["DIMENSION:10"] = {
            {attribute_type = "DIMENSION", attribute_id = 10, representation_id = 100,
                expression = "CAST(NULL AS VARCHAR(10))", role = "FALLBACK", priority = 100},
            {attribute_type = "DIMENSION", attribute_id = 10, representation_id = 101,
                expression = "c.churn_risk", role = "PREFER", priority = 20},
        }},
    })
    api.validate_null_placeholder_bindings(declared)
    assert_equal(#declared.issues, 0)

    -- Every binding a placeholder is a column nobody sources yet -- a stub,
    -- not a wrong answer. Refusing it would refuse an honest work in progress.
    local stub = validation_context({
        model_name = "sales",
        dimension_by_id = {['11'] = {id = 11, name = "not_available_yet", entity_id = 1}},
        representations = {{id = 100, entity_id = 1, name = "primary", role = "PRIMARY"}},
        bindings_by_attribute = {["DIMENSION:11"] = {
            {attribute_type = "DIMENSION", attribute_id = 11, representation_id = 100,
                expression = "CAST(NULL AS VARCHAR(10))", role = "PREFER", priority = 1},
            {attribute_type = "DIMENSION", attribute_id = 11, representation_id = 101,
                expression = "NULL", role = "PREFER", priority = 20},
        }},
    })
    api.validate_null_placeholder_bindings(stub)
    assert_equal(#stub.issues, 0)
    assert_branch("validator.null_placeholder", false, false)

    -- A fact reaches the same rule through the same table.
    local fact_ctx = validation_context({
        model_name = "sales",
        fact_by_id = {['20'] = {id = 20, name = "crm_score", entity_id = 1}},
        representations = {{id = 100, entity_id = 1, name = "primary", role = "PRIMARY"}},
        bindings_by_attribute = {["FACT:20"] = {
            {attribute_type = "FACT", attribute_id = 20, representation_id = 100,
                expression = "NULL", role = "PREFER", priority = 1},
            {attribute_type = "FACT", attribute_id = 20, representation_id = 101,
                expression = "c.score", role = "PREFER", priority = 20},
        }},
    })
    api.validate_null_placeholder_bindings(fact_ctx)
    assert_contains(issue_for_rule(fact_ctx, "SEMANTIC_MODEL_063").message, "crm_score")
end)

test("catalog integrity check derives its tables and names the corrupt one", function()
    -- MODEL_ID is denormalised onto 29 tables and nothing enforces that it
    -- agrees with the model its VERSION_ID belongs to: Exasol's foreign keys
    -- are DISABLE by design. A row filed under the wrong model is read by
    -- neither model, so it fails silently in both directions.
    local seen = {}
    local function mock(sql, parameters)
        seen[#seen + 1] = {sql = sql, parameters = parameters}
        if contains(sql, "HAVING COUNT(DISTINCT COLUMN_NAME) = 2") then
            return {{COLUMN_TABLE = "DIMENSIONS"}, {COLUMN_TABLE = "METRIC_INPUTS"}}
        elseif contains(sql, "SELECT CATALOG_TABLE, MISMATCH_COUNT") then
            return {{CATALOG_TABLE = "DIMENSIONS", MISMATCH_COUNT = 3}}
        end
        error("unexpected catalog integrity SQL: " .. tostring(sql))
    end
    local ctx = validation_context({model_id = 7, version_id = 2, model_name = "sales"})
    with_query(mock, function() api.validate_catalog_integrity(ctx) end)

    assert_true(has_rule(ctx, "SEMANTIC_MODEL_062"))
    assert_equal(issue_for_rule(ctx, "SEMANTIC_MODEL_062").severity, "ERROR")
    assert_contains(issue_for_rule(ctx, "SEMANTIC_MODEL_062").message,
        "SYS_SEMANTIC.DIMENSIONS")
    assert_contains(issue_for_rule(ctx, "SEMANTIC_MODEL_062").message, "3 row(s)")
    assert_branch("validator.catalog_integrity", #ctx.issues > 0, true)

    -- Derived, not restated: both table names come from EXA_ALL_COLUMNS, so a
    -- catalog table added tomorrow is checked without anyone editing a list.
    -- That is the whole reason the rule can be trusted at 29 tables.
    assert_equal(#seen, 2)
    assert_contains(seen[1].sql, "FROM SYS.EXA_ALL_COLUMNS")
    assert_contains(seen[2].sql, "FROM SYS_SEMANTIC.DIMENSIONS")
    assert_contains(seen[2].sql, "FROM SYS_SEMANTIC.METRIC_INPUTS")
    assert_equal(seen[2].parameters.model_id, 7)
    assert_equal(seen[2].parameters.version_id, 2)
end)

test("catalog integrity check stays quiet on an agreeing catalog", function()
    local ctx = validation_context({model_id = 1, version_id = 2, model_name = "sales"})
    with_query(function(sql)
        if contains(sql, "HAVING COUNT(DISTINCT COLUMN_NAME) = 2") then
            return {{COLUMN_TABLE = "ENTITIES"}}
        end
        return {}
    end, function() api.validate_catalog_integrity(ctx) end)
    assert_equal(#ctx.issues, 0)
    assert_branch("validator.catalog_integrity", #ctx.issues > 0, false)

    -- An installation with no such tables at all -- the shape a stubbed or
    -- partially installed catalog presents -- must not build an empty UNION.
    local empty = validation_context({model_id = 1, version_id = 2, model_name = "sales"})
    with_query(function() return {} end,
        function() api.validate_catalog_integrity(empty) end)
    assert_equal(#empty.issues, 0)
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
        elseif contains(sql, "SELECT e.ENTITY_ID, e.ENTITY_NAME") then
            return {{1, "orders", "MART", "ORDERS", "o", "o.order_id",
                "One order", 100, "primary", "RELATION", "PRIMARY", 1}}
        elseif contains(sql, "FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS") then
            return {
                {100, 1, "primary", "RELATION", "MART", "ORDERS", "o",
                    "PRIMARY", 1, null, null, null, null, "PREFER"},
                {101, 1, "archive", "VIRTUAL_SCHEMA", "VS_ARCHIVE", "ORDERS", "o",
                    "ALTERNATE", 20, null, null, null, null, "PREFER"},
            }
        elseif contains(sql, "SELECT DIMENSION_ID, DIMENSION_NAME") then
            return {{10, "order_status", 1, "o.status", "VARCHAR(20)",
                "Order status", nil, nil, false, true}}
        elseif contains(sql, "SELECT FACT_ID, FACT_NAME") then
            return {{20, "net_revenue", 1, "o.amount", "DECIMAL(18,2)",
                "Revenue input", "USD", "currency", false, true}}
        elseif contains(sql, "FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS") then
            return {
                {201, 1, "DIMENSION", 10, 100, "o.status", "PREFER", 1, true},
                {202, 1, "FACT", 20, 100, "o.amount", "PREFER", 1, true},
            }
        elseif contains(sql, "FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES") then
            return {}
        elseif contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES") then
            return {{301, 1, "order_identity", "GLOBAL", "DECIMAL(18,0)"}}
        elseif contains(sql, "FROM SYS_SEMANTIC.IDENTITY_BINDINGS") then
            return {
                {311, 1, 301, 100, "o.order_id", "DIRECT",
                    null, null, null, null, null, null},
                {312, 1, 301, 101, "o.order_id", "MAPPED",
                    321, "MART", "ORDER_IDENTITY_MAP", "ARCHIVE_ORDER_ID",
                    "ORDER_ID", "CERTIFIED"},
            }
        elseif contains(sql, "SELECT METRIC_ID, METRIC_NAME") and not contains(sql, "metric_col") then
            return {{30, "total_revenue", 1, "SUM(net_revenue)", nil, "ADDITIVE",
                "DECIMAL(18,2)", "Total revenue", "USD", "currency", false, true}}
        elseif contains(sql, "SELECT RELATIONSHIP_ID, RELATIONSHIP_NAME") then
            return {{70, "orders_identity", 1, 1,
                "o.order_id = o.order_id", "ONE_TO_ONE", "LEFT", nil, 100}}
        elseif contains(sql, "FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS") then
            return {{70, 1, "order_id", nil, "order_id", nil}}
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
        elseif contains(sql, "HAVING COUNT(DISTINCT COLUMN_NAME) = 2") then
            -- The MODEL_ID/VERSION_ID agreement check derives its table list.
            return {{COLUMN_TABLE = "DIMENSIONS"}, {COLUMN_TABLE = "FACTS"}}
        elseif contains(sql, "SELECT CATALOG_TABLE, MISMATCH_COUNT") then
            return {}
        elseif contains(sql, "FROM SYS.EXA_ALL_COLUMNS") then
            return {{1}}
        elseif contains(sql, "FROM EXA_PARAMETERS") then
            return {{60}}
        elseif contains(sql, "AS PROBE_COUNT") then
            return {{contains(sql, " MINUS ") and 0 or 4}}
        elseif contains(sql, "HAVING COUNT(*) > 1") then
            return {}
        elseif contains(sql, "COUNT(er.REPRESENTATION_ID)") then
            return {}
        elseif contains(sql, "JOIN SYS.EXA_SQL_KEYWORDS") then
            return {}
        elseif contains(sql, "SELECT OBJECT_TYPE, OBJECT_ID, SYNONYM") then
            return {}
        elseif contains(sql, "AND e.ENTITY_ID IS NULL") then
            return {}
        elseif contains(sql, "oc.COLUMN_KIND NOT IN") then
            return {}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.METRIC_DEPENDENCIES") then
            lifecycle.dependency_inserted = true
            return {}
        elseif contains(sql, "FROM SYS_SEMANTIC.METRIC_DEPENDENCIES md") then
            return {}
        elseif contains(sql, "SUM(CASE WHEN oc.COLUMN_KIND = 'DIMENSION'") then
            -- One object with both dimensions and metrics: nothing to warn about.
            return {{"SALES", 2, 1}}
        elseif contains(sql, "FROM SYS_SEMANTIC.METRIC_INPUTS mi") then
            -- The plannability gate classifies metrics with the planner's own
            -- code, which needs the structured inputs.
            return {{30, "MEASURE", "FACT", 20, nil, nil, 1}}
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

test("metric grain is proven against the object root in both directions", function()
    -- F18. compute_metric_dimension_matrix proves root -> base, which is what a
    -- dimension needs. Aggregation needs base -> root, and for a MANY_TO_ONE
    -- those are opposite: order_line -> order is safe, order -> order_line is
    -- not. Aggregating at order grain in a line-rooted view therefore repeats
    -- each order once per line, and nothing caught it -- the matrix reports only
    -- through a metric/dimension pair, so a view with no dimension on the
    -- offending branch validated clean and returned an inflated number.
    local order = {id = 1, name = "order"}
    local line = {id = 2, name = "order_line"}
    local freight = {id = 30, name = "total_freight", base_entity_id = 1,
        expression = "SUM(freight)", metric_type = "ADDITIVE",
        aggregation_function = "SUM",
        inputs = {{role = "MEASURE", object_type = "FACT", object_id = 20,
            ordinal_position = 1}}}
    local facts = {{id = 20, name = "freight", entity_id = 1,
        data_type = "DECIMAL(18,2)"}}
    -- order_line reaches order safely; the reverse edge exists only in the
    -- complete graph, which is what the diagnostic path is drawn from.
    local safe = {['2'] = {{from_id = 2, to_id = 1, name = "ol_to_o",
        safe = true, reason = "OK"}}}
    local all = {
        ['2'] = {{from_id = 2, to_id = 1, name = "ol_to_o", safe = true,
            reason = "OK"}},
        ['1'] = {{from_id = 1, to_id = 2, name = "ol_to_o", safe = false,
            reason = "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED"}},
    }

    local function context_rooted_at(root_entity_id, object_name)
        local object = {object_id = 50, name = object_name,
            root_entity_id = root_entity_id}
        return validation_context({
            version_id = 2,
            semantic_objects = {object},
            semantic_object_by_id = {['50'] = object},
            entities = {order, line},
            entity_by_id = {['1'] = order, ['2'] = line},
            entity_name_by_id = {['1'] = "order", ['2'] = "order_line"},
            metrics = {freight},
            metric_by_id = {['30'] = freight},
            facts = facts,
        })
    end
    local function run(ctx)
        with_query(function(sql)
            if contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
                return {{ctx.semantic_objects[1].name, 50, 30, "total_freight"}}
            end
            return {}
        end, function() api.validate_visible_metric_grain(ctx, safe, all) end)
        return ctx
    end

    -- Coarser than the root: the F18 shape, now refused.
    local fanning = run(context_rooted_at(2, "LINES"))
    local issue = issue_for_rule(fanning, "SEMANTIC_MODEL_059")
    assert_equal(issue.severity, "ERROR")
    assert_contains(issue.message, "total_freight")
    assert_contains(issue.message, "aggregates at entity 'order'")
    assert_contains(issue.message, "coarser than the root 'order_line'")
    assert_contains(issue.message, "multiplied by the fan-out")
    -- The diagnostic names the edge that blocks the walk, and the remedy is
    -- object membership rather than a FANOUT_POLICY that cannot help.
    assert_contains(issue.message, "ol_to_o")
    assert_contains(issue.message, "rooted at 'order'")
    assert_branch("validator.metric_grain.fans_out", has_rule(fanning, "SEMANTIC_MODEL_059"), true)

    -- Base == root: nothing to prove, and the guard must stay quiet or every
    -- ordinary metric in the reference model would fail.
    local aligned = run(context_rooted_at(1, "ORDERS"))
    assert_true(not has_rule(aligned, "SEMANTIC_MODEL_059"))
    assert_branch("validator.metric_grain.fans_out", has_rule(aligned, "SEMANTIC_MODEL_059"), false)

    -- The multi-fact pattern must survive. A public DERIVED metric based at the
    -- root composes a private state metric based at a sibling fact's own grain;
    -- the planner aggregates that state in its own branch, so nothing fans out
    -- even though the DAG bottoms out on the far side of an unsafe edge. Testing
    -- the DAG's leaves instead of the base entity would refuse this, and it is
    -- how grain_d1 avoids fan-out in the first place.
    local state = {id = 32, name = "ticket_count_state", base_entity_id = 2,
        expression = "COUNT(ticket_row)", metric_type = "ADDITIVE",
        aggregation_function = "COUNT",
        inputs = {{role = "MEASURE", object_type = "FACT", object_id = 21,
            ordinal_position = 1}}}
    local derived = {id = 33, name = "ticket_count", base_entity_id = 1,
        expression = "ticket_count_state + 0", metric_type = "DERIVED",
        inputs = {{role = "OPERAND", object_type = "METRIC", object_id = 32,
            ordinal_position = 1}}}
    local object = {object_id = 51, name = "D1", root_entity_id = 1}
    local composed = validation_context({
        version_id = 2,
        semantic_objects = {object},
        semantic_object_by_id = {['51'] = object},
        entities = {order, line},
        entity_by_id = {['1'] = order, ['2'] = line},
        entity_name_by_id = {['1'] = "order", ['2'] = "order_line"},
        metrics = {state, derived},
        metric_by_id = {['32'] = state, ['33'] = derived},
        facts = {{id = 21, name = "ticket_row", entity_id = 2,
            data_type = "DECIMAL(18,0)"}},
    })
    -- Only the public DERIVED metric is an exposed column; the private state
    -- metric is not checked, which is what lets it aggregate off-root.
    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
            return {{"D1", 51, 33, "ticket_count"}}
        end
        return {}
    end, function() api.validate_visible_metric_grain(composed, safe, all) end)
    assert_true(not has_rule(composed, "SEMANTIC_MODEL_059"))
end)

test("matrix refuses a partitioned entity on the join path, not just under the dimension", function()
    -- BUG-G01. The existing rule is keyed on the dimension's own entity, so a
    -- partitioned entity that is merely traversed to reach a dimension beyond it
    -- was invisible: the pair validated OK, the model published, and the
    -- compiler joined the primary partition alone. Keying on the proven path
    -- covers both, because the dimension's entity is that path's last node.
    local order_line = {id = 1, name = "order_line"}
    local order = {id = 2, name = "order"}
    local customer = {id = 3, name = "customer"}
    local revenue = {id = 30, name = "total_revenue", base_entity_id = 1,
        expression = "SUM(net_revenue)", metric_type = "ADDITIVE",
        aggregation_function = "SUM",
        inputs = {{role = "MEASURE", object_type = "FACT", object_id = 20,
            ordinal_position = 1}}}
    local region = {id = 40, name = "customer_region", entity_id = 3}
    local object = {object_id = 60, name = "SALES", root_entity_id = 1}
    -- `order` carries F3 coverage; order_line and customer do not.
    local partitions = {
        {id = 201, name = "primary", role = "PRIMARY", valid_from = "2026-07-01"},
        {id = 202, name = "cold", role = "ALTERNATE", valid_to = "2026-07-01"},
    }
    local ctx = validation_context({
        version_id = 2,
        semantic_objects = {object},
        semantic_object_by_id = {['60'] = object},
        entities = {order_line, order, customer},
        entity_by_id = {['1'] = order_line, ['2'] = order, ['3'] = customer},
        entity_name_by_id = {['1'] = "order_line", ['2'] = "order", ['3'] = "customer"},
        representations_by_entity = {['2'] = partitions},
        metrics = {revenue},
        metric_by_id = {['30'] = revenue},
        dimensions = {region},
        dimension_by_id = {['40'] = region},
        facts = {{id = 20, name = "net_revenue", entity_id = 1,
            data_type = "DECIMAL(18,2)"}},
    })
    -- order_line -> order -> customer, both hops safe.
    local safe = {
        ['1'] = {{from_id = 1, to_id = 2, name = "ol_to_o", safe = true, reason = "OK"}},
        ['2'] = {{from_id = 2, to_id = 3, name = "o_to_c", safe = true, reason = "OK"}},
    }
    with_query(function() return {} end, function()
        api.compute_metric_dimension_matrix(ctx, safe, safe)
    end)
    local row = ctx.matrix['30']['40']
    assert_true(not row.is_valid)
    assert_equal(row.reason_code, "FUSION_PARTITION_JOIN_UNSUPPORTED")
    -- The hop is reported, not the dimension's entity.
    assert_equal(row.partition_hop_name, "order")
    assert_branch("validator.matrix.partition_join_hop", row.is_valid, false)

    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
            return {{"SALES", 30, "total_revenue", 40, "customer_region"}}
        end
        return {}
    end, function() api.validate_visible_metric_dimension_pairs(ctx) end)
    local issue = issue_for_rule(ctx, "SEMANTIC_MODEL_030")
    assert_contains(issue.message, "FUSION_PARTITION_JOIN_UNSUPPORTED")
    assert_contains(issue.message, "Entity 'order'")
    assert_contains(issue.message, "sits on the join path")
    assert_contains(issue.message, "silently omit")

    -- Move the coverage off the path: the pair must go back to valid, or the
    -- guard would refuse every model that contains a partition anywhere.
    local clean = validation_context({
        version_id = 2,
        semantic_objects = {object},
        semantic_object_by_id = {['60'] = object},
        entities = {order_line, order, customer},
        entity_by_id = {['1'] = order_line, ['2'] = order, ['3'] = customer},
        entity_name_by_id = {['1'] = "order_line", ['2'] = "order", ['3'] = "customer"},
        representations_by_entity = {},
        metrics = {revenue},
        metric_by_id = {['30'] = revenue},
        dimensions = {region},
        dimension_by_id = {['40'] = region},
        facts = {{id = 20, name = "net_revenue", entity_id = 1,
            data_type = "DECIMAL(18,2)"}},
    })
    with_query(function() return {} end, function()
        api.compute_metric_dimension_matrix(clean, safe, safe)
    end)
    assert_true(clean.matrix['30']['40'].is_valid)
    assert_branch("validator.matrix.partition_join_hop",
        clean.matrix['30']['40'].is_valid, true)
end)

test("validation issues lead with the cause, not its consequences", function()
    -- BUG-G04. Every admin DDL wrapper reports validation_errors[1], so this
    -- order decides which sentence a refused authoring call shows. A
    -- representation registered without its identity binding makes the entity's
    -- key, expression and attribute checks all fail against it -- and those
    -- rules run earlier, so the caller was told to fix a dimension that was
    -- never wrong while the actionable error sat underneath.
    local knock_on_key = {rule_code = "SEMANTIC_MODEL_029", message = "unknown source column"}
    local knock_on_pk = {rule_code = "SEMANTIC_MODEL_036", message = "unknown source column"}
    local cause = {rule_code = "SEMANTIC_MODEL_060",
        message = "Semantic identity has no binding for active representation: crm."}
    local knock_on_dim = {rule_code = "SEMANTIC_MODEL_017", message = "unknown source column"}

    local ordered = api.order_root_cause_first({knock_on_pk, cause, knock_on_key, knock_on_dim})
    assert_equal(ordered[1].rule_code, "SEMANTIC_MODEL_060")
    -- The consequences keep their relative order behind it.
    assert_equal(ordered[2].rule_code, "SEMANTIC_MODEL_036")
    assert_equal(ordered[3].rule_code, "SEMANTIC_MODEL_029")
    assert_equal(ordered[4].rule_code, "SEMANTIC_MODEL_017")
    assert_equal(#ordered, 4)
    assert_branch("validator.issues.root_cause_first",
        ordered[1].rule_code == "SEMANTIC_MODEL_060", true)

    -- A model with no missing binding is left exactly as it was, so this cannot
    -- quietly reshuffle unrelated reports.
    local untouched = {knock_on_pk, knock_on_key}
    local same = api.order_root_cause_first(untouched)
    assert_equal(same, untouched)
    assert_branch("validator.issues.root_cause_first",
        same[1].rule_code == "SEMANTIC_MODEL_060", false)

    -- The promotion is now a code comparison, so the seventeen other identity
    -- defects still under SEMANTIC_MODEL_047 cannot be promoted by accident --
    -- they are causes in their own right but not causes *of other issues*. This
    -- used to depend on the exact wording of the message.
    local other_047 = {rule_code = "SEMANTIC_MODEL_047",
        message = "Identity kind must be BUSINESS or GLOBAL."}
    local unpromoted = api.order_root_cause_first({knock_on_pk, other_047})
    assert_equal(unpromoted[1].rule_code, "SEMANTIC_MODEL_036")

    -- And a _060 is promoted whatever its message says, which is the point of
    -- splitting the code out.
    local reworded = {rule_code = "SEMANTIC_MODEL_060", message = "reworded entirely"}
    assert_equal(api.order_root_cause_first({knock_on_pk, reworded})[1].rule_code,
        "SEMANTIC_MODEL_060")

    assert_equal(#api.order_root_cause_first({}), 0)
end)
