local api = ESV_VALIDATOR_TEST_API

test("validator accepts valid JSON and rejects malformed JSON", function()
    assert_branch("validator.valid_json", api.valid_json_text('{"a":[1,true,null]}'), true)
    assert_branch("validator.valid_json", api.valid_json_text('{"a":01}'), false)
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
    assert_contains(key_issue.message, "certified F5 semantic identity")
    assert_contains(mapping_issue.message, "mongo")
    assert_contains(mapping_issue.message, "anchored DIRECT F5 identity")
end)

test("validator proves F1 representation grain and key-set equivalence", function()
    local entity = {id = 1, name = "customers", alias = "c"}
    local primary = {id = 1, entity_id = 1, name = "primary", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMERS"}
    local duplicate = {id = 2, entity_id = 1, name = "duplicate", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMERS_DUP"}
    local half = {id = 3, entity_id = 1, name = "half", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMERS_HALF"}
    local swapped = {id = 4, entity_id = 1, name = "swapped", alias = "c",
        source_schema = "HUB", source_object = "CUSTOMERS_SWAPPED"}
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
    assert_equal(ctx.matrix['10']['22'].path,
        "orders_items (rejected: FANOUT_REQUIRES_POLICY)")
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
    assert_contains(issue_for_rule(ctx, "SEMANTIC_MODEL_030").message,
        "orders_items (rejected: FANOUT_REQUIRES_POLICY)")
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
            reason = "FANOUT_REQUIRES_POLICY"}},
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
        "line_to_order > shipment_to_order (rejected: FANOUT_REQUIRES_POLICY)")
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
