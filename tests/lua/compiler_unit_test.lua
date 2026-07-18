local api = ESV_COMPILER_TEST_API

test("compiler JSON round-trips nested request data", function()
    local request = {
        model = "sales", metrics = {"revenue", "margin"},
        filters = {{field = "region", op = "=", value = "O'Reilly"}},
        enabled = true,
    }
    local encoded = api.json_encode(request)
    local decoded = api.json_decode(encoded)
    assert_equal(decoded.model, "sales")
    assert_equal(decoded.metrics[2], "margin")
    assert_equal(decoded.filters[1].value, "O'Reilly")
    assert_branch("compiler.json.boolean", decoded.enabled, true)
end)

test("compiler JSON rejects malformed input", function()
    assert_error(function() api.json_decode('{"model":]') end)
    assert_branch("compiler.json.boolean", false, false)
end)

test("cache normalization ignores logging metadata and key order", function()
    local left = {model = "sales", metrics = {"m"}, client = "one", purpose = "a"}
    local right = {metrics = {"m"}, model = "sales", client = "two",
        natural_language_text = "question"}
    local a = api.canonical_request_text(left)
    local b = api.canonical_request_text(right)
    assert_equal(a, b)
    assert_equal(#api.compile_cache_key(a), 16)
    assert_branch("compiler.cache.empty", api.compile_cache_key("") == nil, true)
    assert_branch("compiler.cache.empty", api.compile_cache_key(a) == nil, false)
end)

test("request normalization property holds for varied ignored metadata", function()
    local seed = 1729
    local function next_number()
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed
    end
    for index = 1, 250 do
        local metric = "metric_" .. tostring(next_number() % 31)
        local base = {model = "m" .. tostring(index % 7), metrics = {metric}, limit = index}
        local noisy = {limit = index, metrics = {metric}, model = base.model,
            client = tostring(next_number()), purpose = tostring(next_number())}
        assert_equal(api.canonical_request_text(base), api.canonical_request_text(noisy))
    end
end)

test("SQL tokenizer handles comments quoted names and nested commas", function()
    local tokens = api.sql_tokens([[SELECT "Region", MEASURE(total_revenue), 'a''b'
        FROM SEMANTIC_SALES.SALES -- ignored
        WHERE x >= 10;]])
    assert_equal(tokens[1].upper, "SELECT")
    assert_equal(tokens[2].value, "Region")
    local parts = api.split_top_level(tokens, 2, 10, ",")
    assert_equal(#parts, 3)
    local rewritten, unwrapped = api.unwrap_measure_part(parts[2])
    assert_branch("compiler.measure.unwrap", unwrapped, true)
    assert_equal(api.identifier_from_part(rewritten), "total_revenue")
    local unchanged, not_unwrapped = api.unwrap_measure_part(parts[1])
    assert_branch("compiler.measure.unwrap", not_unwrapped, false)
    assert_equal(api.identifier_from_part(unchanged), "Region")
end)

test("SQL tokenizer property survives deterministic whitespace and comments", function()
    local whitespace = {" ", "  ", "\n", "\t", " /* probe */ "}
    for index = 1, 300 do
        local gap = whitespace[(index % #whitespace) + 1]
        local tokens = api.sql_tokens("SELECT" .. gap .. "region" .. gap
            .. "FROM" .. gap .. "semantic_sales.sales;")
        assert_equal(tokens[1].upper, "SELECT")
        assert_equal(tokens[2].value, "region")
        assert_equal(tokens[3].upper, "FROM")
        assert_equal(tokens[#tokens].value, "sales")
    end
end)

test("SQL literals and predicates preserve semantic types", function()
    assert_equal(api.sql_literal("O'Reilly", "VARCHAR(20)"), "'O''Reilly'")
    assert_equal(api.sql_literal(true, "BOOLEAN"), "TRUE")
    assert_equal(api.sql_literal("2026-07-18", "DATE"), "DATE '2026-07-18'")
    local predicate = api.build_dimension_predicate("c.region", "=", "west", "VARCHAR(20)")
    assert_equal(predicate, "UPPER(c.region) = UPPER('west')")
    local between = api.build_dimension_predicate("o.amount", "BETWEEN", {10, 20}, "DECIMAL(18,2)")
    assert_equal(between, "o.amount BETWEEN 10 AND 20")
end)

test("metric filter rewriting covers supported and fallback aggregates", function()
    assert_equal(api.apply_metric_filter("SUM(f.amount)", "d.active = TRUE"),
        "SUM(CASE WHEN d.active = TRUE THEN f.amount ELSE 0 END)")
    assert_equal(api.apply_metric_filter("COUNT(f.id)", "d.active = TRUE"),
        "COUNT(CASE WHEN d.active = TRUE THEN f.id ELSE NULL END)")
    assert_equal(api.apply_metric_filter("AVG(f.amount)", "d.active = TRUE"),
        "CASE WHEN d.active = TRUE THEN AVG(f.amount) ELSE NULL END")
end)

test("collision classification distinguishes retryable errors", function()
    assert_branch("compiler.collision", api.collision_error("GlobalTransactionRollback"), true)
    assert_branch("compiler.collision", api.collision_error("invalid metric"), false)
end)

local function parse_where(text)
    local tokens = api.sql_tokens(text)
    return api.parse_where_filters(tokens, 1, #tokens)
end

test("WHERE parser preserves conjunctions ranges lists and expressions", function()
    local filters, err = parse_where(
        "region IN ('North', 'O''Reilly') AND amount BETWEEN 10 AND 20 "
        .. "AND created_at >= CURRENT_DATE")
    assert_equal(err, nil)
    assert_equal(#filters, 3)
    assert_equal(filters[1].field, "region")
    assert_equal(filters[1].op, "IN")
    assert_equal(filters[1].value[2], "O'Reilly")
    assert_equal(filters[2].op, "BETWEEN")
    assert_equal(filters[2].value[1], 10)
    assert_equal(filters[2].value[2], 20)
    assert_equal(filters[3].op, ">=")
    assert_equal(filters[3].value, "CURRENT_DATE")
end)

test("WHERE parser returns stable errors for unsafe predicate shapes", function()
    local cases = {
        {"region", "SEMANTIC_QUERY_030"},
        {"UPPER(region) = 'NORTH'", "SEMANTIC_QUERY_031"},
        {"region IN 'North'", "SEMANTIC_QUERY_032"},
        {"region IN (other + 1)", "SEMANTIC_QUERY_033"},
        {"amount BETWEEN 10", "SEMANTIC_QUERY_034"},
        {"amount BETWEEN other + 1 AND 20", "SEMANTIC_QUERY_035"},
        {"region =", "SEMANTIC_QUERY_033"},
    }
    for _, case in ipairs(cases) do
        local filters, err = parse_where(case[1])
        assert_equal(filters, nil)
        assert_equal(err.error_code, case[2])
    end
end)

test("ORDER BY parser resolves aliases ordinals and directions", function()
    local tokens = api.sql_tokens("revenue_alias DESC, 1, region ASC")
    local order_by, err = api.parse_order_by(tokens, 1, #tokens,
        {REVENUE_ALIAS = "total_revenue"}, {"customer_region", "total_revenue"})
    assert_equal(err, nil)
    assert_equal(order_by[1].field, "total_revenue")
    assert_equal(order_by[1].direction, "DESC")
    assert_equal(order_by[2].field, "customer_region")
    assert_equal(order_by[2].direction, "ASC")
    assert_equal(order_by[3].field, "region")

    local invalid = api.sql_tokens("total_revenue + 1")
    local result, invalid_err = api.parse_order_by(invalid, 1, #invalid, {}, {})
    assert_equal(result, nil)
    assert_equal(invalid_err.error_code, "SEMANTIC_QUERY_060")
end)

test("SQL literal parser covers scalar and temporal forms", function()
    local cases = {
        {"'O''Reilly'", "O'Reilly"},
        {"12.5", 12.5},
        {"TRUE", "TRUE"},
        {"DATE '2026-07-18'", "2026-07-18"},
        {"TIMESTAMP '2026-07-18 12:30:00'", "2026-07-18 12:30:00"},
    }
    for _, case in ipairs(cases) do
        assert_equal(api.literal_from_tokens(api.sql_tokens(case[1])), case[2])
    end
    assert_equal(api.literal_from_tokens(api.sql_tokens("-12.5")), nil)
    assert_equal(api.literal_from_tokens(api.sql_tokens("1 + 2")), nil)
end)

local function compiler_context()
    local orders = {id = 1, name = "orders", alias = "o", source_schema = "MART",
        source_object = "ORDERS"}
    local customers = {id = 2, name = "customers", alias = "c", source_schema = "MART",
        source_object = "CUSTOMERS"}
    local region = {id = 10, kind = "DIMENSION", name = "customer_region",
        entity_id = 2, expression = "c.region", data_type = "VARCHAR(50)"}
    local revenue_fact = {id = 20, kind = "FACT", name = "net_revenue",
        entity_id = 1, expression = "o.net_revenue", data_type = "DECIMAL(18,2)"}
    local revenue = {id = 30, kind = "METRIC", name = "total_revenue",
        base_entity_id = 1, expression = "SUM(net_revenue)", data_type = "DECIMAL(18,2)"}
    return {
        object = {root_entity_id = 1},
        entity_by_id = {['1'] = orders, ['2'] = customers},
        entity_by_alias = {O = orders, C = customers},
        relationships = {{id = 100, name = "orders_customer", from_entity_id = 1,
            to_entity_id = 2, cardinality = "MANY_TO_ONE", join_type = "LEFT",
            join_condition = "o.customer_id = c.customer_id"}},
        canonical_fields = {
            CUSTOMER_REGION = region,
            NET_REVENUE = revenue_fact,
            TOTAL_REVENUE = revenue,
        },
        synonym_fields = {REGION = {region}, SALES = {revenue},
            AMBIGUOUS = {region, revenue}},
        dimensions = {region},
        facts = {revenue_fact},
        metrics = {revenue},
        fact_by_name = {NET_REVENUE = revenue_fact},
        fact_by_id = {['20'] = revenue_fact},
        metric_by_id = {['30'] = revenue},
    }, region, revenue
end

test("compiler field resolution handles canonical synonyms and ambiguity", function()
    local ctx = compiler_context()
    local exact = api.resolve_field(ctx, " customer_region ", "DIMENSION")
    assert_equal(exact.name, "customer_region")
    assert_branch("compiler.field.ambiguous", exact == nil, false)
    local synonym = api.resolve_field(ctx, "sales", "METRIC")
    assert_equal(synonym.name, "total_revenue")

    local missing, missing_err = api.resolve_field(ctx, "unknown", nil)
    assert_equal(missing, nil)
    assert_equal(missing_err.error_code, "SEMANTIC_REQUEST_020")
    local wrong, wrong_err = api.resolve_field(ctx, "customer_region", "METRIC")
    assert_equal(wrong, nil)
    assert_equal(wrong_err.error_code, "SEMANTIC_REQUEST_022")
    local ambiguous, ambiguous_err = api.resolve_field(ctx, "ambiguous", nil)
    assert_equal(ambiguous, nil)
    assert_equal(ambiguous_err.error_code, "SEMANTIC_REQUEST_021")
    assert_branch("compiler.field.ambiguous", ambiguous == nil, true)
    local clarification = api.json_decode(ambiguous_err.clarification_json)
    assert_equal(#clarification.candidates, 2)
end)

test("compiler join planner follows safe cardinality direction", function()
    local ctx = compiler_context()
    local joins, paths, err = api.plan_joins(ctx, {['2'] = true})
    assert_equal(err, nil)
    assert_equal(#joins, 1)
    assert_branch("compiler.join.path", joins ~= nil, true)
    assert_equal(joins[1].entity.name, "customers")
    assert_equal(paths[1], "orders_customer")

    local reverse = compiler_context()
    reverse.object.root_entity_id = 2
    local none, _, reverse_err = api.plan_joins(reverse, {['1'] = true})
    assert_equal(none, nil)
    assert_branch("compiler.join.path", none ~= nil, false)
    assert_equal(reverse_err.error_code, "SEMANTIC_REQUEST_042")
end)

test("compiler builds filters ordering and physical SQL", function()
    local ctx, region, revenue = compiler_context()
    local needed = {}
    local filters, filter_dimensions, filter_err = api.build_filters(ctx, {
        {field = "region", op = "IN", value = {"North", "West"}},
    }, {}, needed)
    assert_equal(filter_err, nil)
    assert_equal(#filter_dimensions, 1)
    assert_true(needed['2'])
    assert_contains(filters[1].predicate, "UPPER(c.region) IN")

    local output = {[region.kind .. ":" .. region.id] = true,
        [revenue.kind .. ":" .. revenue.id] = true}
    local order_by, order_err = api.build_order_by(ctx, {
        {field = "sales", direction = "DESC"},
    }, output)
    assert_equal(order_err, nil)
    assert_equal(order_by[1], '"total_revenue" DESC')

    local joins = api.plan_joins(ctx, needed)
    local sql = api.build_sql(ctx, {region}, {revenue}, filters, joins, order_by, 25,
        {'SUM(o.net_revenue) > 100'})
    assert_contains(sql, 'LEFT JOIN "MART"."CUSTOMERS" c')
    assert_contains(sql, 'SUM((o.net_revenue)) AS "total_revenue"')
    assert_contains(sql, "GROUP BY c.region")
    assert_contains(sql, "HAVING SUM(o.net_revenue) > 100")
    assert_contains(sql, "LIMIT 25")
end)

test("compiler rejects malformed filters and ordering contracts", function()
    local ctx, region = compiler_context()
    local output = {[region.kind .. ":" .. region.id] = true}
    local cases = {
        {{"not-an-object"}, "SEMANTIC_REQUEST_030"},
        {{{op = "="}}, "SEMANTIC_REQUEST_020"},
        {{{field = "total_revenue", value = 1}}, "SEMANTIC_REQUEST_031"},
        {{{field = "region", op = "IN", value = {}}}, "SEMANTIC_REQUEST_032"},
        {{{field = "region", op = "REGEXP", value = "x"}}, "SEMANTIC_REQUEST_033"},
    }
    for _, case in ipairs(cases) do
        local filters, _, err = api.build_filters(ctx, case[1], {}, {})
        assert_equal(filters, nil)
        assert_equal(err.error_code, case[2])
    end

    local clauses, type_err = api.build_order_by(ctx, {"region"}, output)
    assert_equal(clauses, nil)
    assert_equal(type_err.error_code, "SEMANTIC_REQUEST_060")
    local absent, absent_err = api.build_order_by(ctx,
        {{field = "total_revenue"}}, output)
    assert_equal(absent, nil)
    assert_equal(absent_err.error_code, "SEMANTIC_REQUEST_061")
    local direction, direction_err = api.build_order_by(ctx,
        {{field = "region", direction = "SIDEWAYS"}}, output)
    assert_equal(direction, nil)
    assert_equal(direction_err.error_code, "SEMANTIC_REQUEST_062")
end)

local function with_query(mock, fn)
    local original_query = query
    query = mock
    local ok, result, second, third = xpcall(fn, debug.traceback)
    query = original_query
    if not ok then error(result, 0) end
    return result, second, third
end

local function compiler_query_fixture(options)
    options = options or {}
    local state = {
        cache = {},
        cache_inserts = 0,
        cache_touches = 0,
        model_attempts = 0,
        request_log_attempts = 0,
        request_logs = {},
        query_logs = {},
    }

    local function mock(sql, params)
        local normalized = tostring(sql):gsub("%s+", " ")
        params = params or {}

        if normalized:find("SELECT GENERATED_SQL, PLAN_JSON, VALIDATION_RUN_ID", 1, true) then
            local cached = state.cache[params.cache_key]
            return cached and {{cached.generated_sql, cached.plan_json,
                cached.validation_run_id}} or {}
        elseif normalized:find("INSERT INTO SYS_SEMANTIC.COMPILE_CACHE", 1, true) then
            state.cache_inserts = state.cache_inserts + 1
            if options.cache_insert_error then error("cache insert unavailable") end
            state.cache[params.cache_key] = {
                generated_sql = params.generated_sql,
                plan_json = params.plan_json,
                validation_run_id = params.validation_run_id,
            }
            return {}
        elseif normalized:find("UPDATE SYS_SEMANTIC.COMPILE_CACHE", 1, true) then
            state.cache_touches = state.cache_touches + 1
            if options.cache_touch_error then error("cache touch unavailable") end
            return {}
        elseif normalized:find("INSERT INTO SYS_SEMANTIC.AGENT_REQUEST_LOG", 1, true) then
            state.request_log_attempts = state.request_log_attempts + 1
            if state.request_log_attempts <= (options.log_collisions or 0) then
                error("GlobalTransactionRollback while logging")
            end
            state.request_logs[#state.request_logs + 1] = params
            return {}
        elseif normalized:find("SELECT MAX(AGENT_REQUEST_ID)", 1, true) then
            return {{501}}
        elseif normalized:find("INSERT INTO SYS_SEMANTIC.QUERY_LOG", 1, true) then
            state.query_logs[#state.query_logs + 1] = params
            return {}
        elseif normalized:find("SELECT MAX(QUERY_LOG_ID)", 1, true) then
            return {{601}}
        elseif normalized:find("WHERE UPPER(m.MODEL_NAME)", 1, true) then
            state.model_attempts = state.model_attempts + 1
            if state.model_attempts <= (options.model_collisions or 0) then
                error("Transaction collision while loading model")
            end
            if options.model_missing then return {} end
            return {{1, 2, 3}}
        elseif normalized:find("WHERE UPPER(m.PUBLISHED_SCHEMA)", 1, true) then
            if options.schema_missing or params.schema_name ~= "SEMANTIC_SALES" then
                return {}
            end
            return {{1, "sales", 2, 3}}
        elseif normalized:find("FROM SYS_SEMANTIC.SEMANTIC_OBJECTS", 1, true) then
            if options.object_missing then return {} end
            return {{40, "SALES", 1}}
        elseif normalized:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {{1, "orders", "MART", "ORDERS", "o"}}
        elseif normalized:find("JOIN SYS_SEMANTIC.DIMENSIONS", 1, true) then
            return {{10, "order_status", 1, "o.status", "VARCHAR(20)",
                "Order Status"}}
        elseif normalized:find("JOIN SYS_SEMANTIC.METRICS", 1, true) then
            return {{30, "total_revenue", 1, "SUM(net_revenue)", nil,
                "ADDITIVE", "DECIMAL(18,2)", "Total Revenue", "SIMPLE"}}
        elseif normalized:find("FROM SYS_SEMANTIC.FACTS", 1, true) then
            return {{20, "net_revenue", 1, "o.amount", "DECIMAL(18,2)"}}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIPS", 1, true) then
            return {}
        elseif normalized:find("FROM SYS_SEMANTIC.SYNONYMS", 1, true) then
            return {{"METRIC", 30, "revenue"}, {"DIMENSION", 10, "status"}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_DEPENDENCIES", 1, true) then
            return {{"FACT", 20}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_FILTERS", 1, true) then
            return {}
        elseif normalized:find("FROM SYS_SEMANTIC.VALIDATION_RUNS", 1, true) then
            if options.no_validation then return {} end
            return {{77, "OK", 0}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX", 1, true) then
            if options.missing_matrix then return {} end
            if options.invalid_matrix then
                return {{false, "FANOUT_REQUIRES_POLICY", nil}}
            end
            return {{true, "OK", "SELF"}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_INPUTS", 1, true) then
            return {{"MEASURE", "FACT", "net_revenue"}}
        end
        error("unexpected compiler fixture query: " .. normalized)
    end
    return mock, state
end

local function compile_with_fixture(request, options)
    local mock, state = compiler_query_fixture(options)
    local result = with_query(mock, function()
        return compile_request_json(api.json_encode(request))
    end)
    return result, state, mock
end

test("structured compiler executes catalog pipeline and reuses cache", function()
    local mock, state = compiler_query_fixture()
    local request_json = api.json_encode({
        model = "sales",
        object = "SALES",
        metrics = {"revenue"},
        dimensions = {"status"},
        filters = {{field = "status", op = "=", value = "COMPLETE"}},
        having = {{field = "total_revenue", op = ">", value = 100}},
        order_by = {{field = "total_revenue", direction = "DESC"}},
        limit = 25,
        client = "lua-tests",
        purpose = "compiler pipeline coverage",
    })

    local first = with_query(mock, function()
        return compile_request_json(request_json)
    end)
    assert_equal(first.status, "OK")
    assert_equal(first.agent_request_id, 501)
    assert_branch("compiler.public.cache", first.cache_hit == true, false)
    assert_contains(first.generated_sql, 'FROM "MART"."ORDERS" o')
    assert_contains(first.generated_sql, "UPPER(o.status) = UPPER('COMPLETE')")
    assert_contains(first.generated_sql, "HAVING SUM((o.amount)) > 100")
    assert_contains(first.generated_sql, 'ORDER BY "total_revenue" DESC')
    assert_contains(first.generated_sql, "LIMIT 25")
    assert_contains(first.plan_json, '"validation_run_id":77')
    assert_contains(first.plan_json, '"input_roles"')
    assert_equal(state.cache_inserts, 1)
    assert_equal(#state.request_logs, 1)
    assert_equal(state.request_logs[1].client_name, "lua-tests")

    local second = with_query(mock, function()
        return compile_request_json(request_json)
    end)
    assert_equal(second.status, "OK")
    assert_branch("compiler.public.cache", second.cache_hit == true, true)
    assert_equal(second.generated_sql, first.generated_sql)
    assert_equal(second.agent_request_id, 501)
    assert_equal(state.cache_touches, 1)
    assert_equal(state.cache_inserts, 1)
    assert_equal(#state.request_logs, 2)
end)

test("structured compiler maps request and validation failures", function()
    local malformed_mock = compiler_query_fixture()
    local malformed = with_query(malformed_mock, function()
        return compile_request_json('{"model":]')
    end)
    assert_equal(malformed.error_code, "SEMANTIC_REQUEST_001")

    local cases = {
        {{object = "SALES", metrics = {"revenue"}}, nil, "SEMANTIC_REQUEST_002"},
        {{model = "sales", metrics = {"revenue"}}, nil, "SEMANTIC_REQUEST_003"},
        {{model = "sales", object = "SALES", metrics = {"revenue"}},
            {model_missing = true}, "SEMANTIC_REQUEST_011"},
        {{model = "sales", object = "SALES", metrics = {"revenue"}},
            {object_missing = true}, "SEMANTIC_REQUEST_012"},
        {{model = "sales", object = "SALES"}, nil, "SEMANTIC_REQUEST_023"},
        {{model = "sales", object = "SALES", metrics = {"revenue"}},
            {no_validation = true}, "SEMANTIC_REQUEST_010"},
        {{model = "sales", object = "SALES", metrics = {"revenue"},
            dimensions = {"status"}}, {missing_matrix = true}, "SEMANTIC_REQUEST_040"},
        {{model = "sales", object = "SALES", metrics = {"revenue"},
            dimensions = {"status"}}, {invalid_matrix = true}, "SEMANTIC_REQUEST_041"},
        {{model = "sales", object = "SALES", metrics = {"revenue"}, limit = 0},
            nil, "SEMANTIC_REQUEST_050"},
        {{model = "sales", object = "SALES", metrics = {"revenue"}, limit = 10001},
            nil, "SEMANTIC_REQUEST_051"},
        {{model = "sales", object = "SALES", dimensions = {"status"},
            having = {{field = "total_revenue", op = ">", value = 1}}},
            nil, "SEMANTIC_REQUEST_026"},
    }
    for _, case in ipairs(cases) do
        local result, state = compile_with_fixture(case[1], case[2])
        assert_equal(result.status, "ERROR")
        assert_equal(result.error_code, case[3])
        assert_equal(state.cache_inserts, 0)
        assert_equal(#state.request_logs, 1)
    end
end)

test("semantic SQL public APIs compile debug and preserve non-semantic SQL", function()
    local mock, state = compiler_query_fixture()
    local semantic_sql = [[
        SELECT order_status, MEASURE(total_revenue)
        FROM SEMANTIC_SALES.SALES
        WHERE order_status = 'COMPLETE'
        GROUP BY ALL
        ORDER BY total_revenue DESC
        LIMIT 5
    ]]
    local compiled, request, model = with_query(mock, function()
        return compile_sql(semantic_sql)
    end)
    assert_equal(compiled.status, "OK")
    assert_equal(model.model_name, "sales")
    assert_equal(request.metrics[1], "total_revenue")
    assert_contains(compiled.generated_sql, "GROUP BY o.status")
    assert_contains(compiled.generated_sql, "LIMIT 5")

    local debugged = with_query(mock, function()
        return compile_sql_debug(semantic_sql, "lua-debug")
    end)
    assert_equal(debugged.status, "OK")
    assert_equal(debugged.query_log_id, 601)
    assert_equal(#state.query_logs, 1)
    assert_equal(state.query_logs[1].client_name, "lua-debug")

    local unchanged = compile_sql_for_preprocessor("UPDATE MART.ORDERS SET amount = 1")
    assert_equal(unchanged.status, "UNCHANGED")
    assert_equal(unchanged.generated_sql, "UPDATE MART.ORDERS SET amount = 1")

    local unknown_mock = compiler_query_fixture({schema_missing = true})
    local unknown = with_query(unknown_mock, function()
        return compile_sql_for_preprocessor("SELECT * FROM OTHER_SCHEMA.ORDERS")
    end)
    assert_equal(unknown.status, "UNCHANGED")
    assert_equal(unknown.generated_sql, "SELECT * FROM OTHER_SCHEMA.ORDERS")

    local rejected = compile_sql("DELETE FROM SEMANTIC_SALES.SALES")
    assert_equal(rejected.status, "ERROR")
    assert_equal(rejected.error_code, "SEMANTIC_QUERY_009")
end)

test("materialized SQL renders every supported rollup policy", function()
    local ctx = compiler_context()
    local dimension = ctx.dimensions[1]
    local metric = ctx.metrics[1]
    local materialization = {
        physical_schema = "MART",
        physical_object = "SALES_AGG",
        columns = {
            [dimension.kind .. ":" .. dimension.id] = {physical_column = "REGION"},
            [metric.kind .. ":" .. metric.id] = {physical_column = "REVENUE"},
        },
        metric_rollup_policies = {},
    }
    local expected = {
        DIRECT = 'mat."REVENUE" AS "total_revenue"',
        SUM = 'SUM(mat."REVENUE") AS "total_revenue"',
        MIN = 'MIN(mat."REVENUE") AS "total_revenue"',
        MAX = 'MAX(mat."REVENUE") AS "total_revenue"',
        COUNT = 'SUM(mat."REVENUE") AS "total_revenue"',
    }
    for policy, fragment in pairs(expected) do
        materialization.metric_rollup_policies[metric.kind .. ":" .. metric.id] = policy
        local sql = api.build_materialized_sql(ctx, {dimension}, {metric}, {}, {}, 10,
            materialization)
        assert_contains(sql, fragment)
        assert_contains(sql, 'FROM "MART"."SALES_AGG" mat')
        if policy == "DIRECT" then
            assert_equal(sql:find("GROUP BY", 1, true), nil)
        else
            assert_contains(sql, 'GROUP BY mat."REGION"')
        end
    end

    materialization.metric_rollup_policies[metric.kind .. ":" .. metric.id] = "DIRECT"
    local filtered = api.build_materialized_sql(ctx, {dimension}, {metric}, {{
        field_kind = dimension.kind, field_id = dimension.id, op = "=",
        value = "West", data_type = dimension.data_type,
    }}, {}, 5, materialization)
    assert_contains(filtered, 'WHERE UPPER(mat."REGION") = UPPER(\'West\')')
end)

test("compiler retries collisions and tolerates best-effort cache failures", function()
    local request = {model = "sales", object = "SALES", metrics = {"revenue"}}
    local retried, state = compile_with_fixture(request,
        {model_collisions = 2, log_collisions = 2})
    assert_equal(retried.status, "OK")
    assert_equal(retried.agent_request_id, 501)
    assert_equal(state.model_attempts, 3)
    assert_equal(state.request_log_attempts, 3)

    local cache_error, cache_state = compile_with_fixture(request,
        {cache_insert_error = true})
    assert_equal(cache_error.status, "OK")
    assert_equal(cache_state.cache_inserts, 1)

    local mock, touch_state = compiler_query_fixture({cache_touch_error = true})
    local payload = api.json_encode(request)
    local first = with_query(mock, function() return compile_request_json(payload) end)
    local second = with_query(mock, function() return compile_request_json(payload) end)
    assert_equal(first.status, "OK")
    assert_equal(second.status, "OK")
    assert_equal(second.cache_hit, true)
    assert_equal(touch_state.cache_touches, 1)
end)
