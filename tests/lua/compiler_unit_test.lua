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
    local is_null = api.build_dimension_predicate("c.region", "IS NULL", nil, "VARCHAR(20)")
    assert_equal(is_null, "c.region IS NULL")
    local is_not_null = api.build_dimension_predicate("c.region", "IS NOT NULL", nil, "VARCHAR(20)")
    assert_equal(is_not_null, "c.region IS NOT NULL")
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

test("WHERE parser supports unary null predicates", function()
    local filters, err = parse_where(
        "region IS NULL AND status IS NOT NULL AND amount >= 10")
    assert_equal(err, nil)
    assert_equal(#filters, 3)
    assert_equal(filters[1].field, "region")
    assert_equal(filters[1].op, "IS NULL")
    assert_equal(filters[1].value, nil)
    assert_equal(filters[2].field, "status")
    assert_equal(filters[2].op, "IS NOT NULL")
    assert_equal(filters[2].value, nil)

    local invalid, invalid_err = parse_where("region IS NOT")
    assert_equal(invalid, nil)
    assert_equal(invalid_err.error_code, "SEMANTIC_QUERY_036")
end)

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

test("HAVING parser supports unary null predicates", function()
    local ctx = compiler_context()
    local tokens = api.sql_tokens("total_revenue IS NOT NULL")
    local filters, err = api.parse_having_filters(ctx, tokens, 1, #tokens)
    assert_equal(err, nil)
    assert_equal(#filters, 1)
    assert_equal(filters[1].field, "total_revenue")
    assert_equal(filters[1].op, "IS NOT NULL")
    assert_equal(filters[1].value, nil)
end)

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
        representation_reads = 0,
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
            if normalized:find("JOIN SYS_SEMANTIC.ENTITY_REPRESENTATIONS", 1, true) then
                state.representation_reads = state.representation_reads + 1
            end
            if options.multi_fact then
                return {
                    {1, "orders", options.missing_multi_source and "" or "MART",
                        "ORDERS", "o", "o.order_id",
                        "One row per order"},
                    {2, "tickets", "MART", "TICKETS", "t", "t.ticket_id",
                        "One row per ticket"},
                    {3, "customers", "MART", "CUSTOMERS", "c", "c.customer_id",
                        "One row per customer"},
                }
            end
            if options.strict_target then
                return {
                    {1, "orders", "MART", "ORDERS", "o", "o.order_id",
                        "One row per order"},
                    {2, "customers", "MART", "CUSTOMERS", "c", "c.customer_id",
                        "One row per customer"},
                }
            end
            if options.promoted_primary then
                return {{1, "orders", "VS_ARCHIVE", "ORDERS", "o", "o.order_id",
                    "One row per order", 104, "archive", "VIRTUAL_SCHEMA", "PRIMARY", 40}}
            end
            if options.f3_union then
                return {{1, "orders", "MART", "ORDERS_HOT", "o", "o.order_id",
                    "One row per order", 104, "hot", "RELATION", "PRIMARY", 1}}
            end
            return {{1, "orders", "MART", "ORDERS", "o", "o.order_id",
                "One row per order", 101, "primary", "RELATION", "PRIMARY", 1}}
        elseif normalized:find("FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS", 1, true) then
            if options.multi_fact then
                return {
                    {101, 1, "primary", "RELATION", options.missing_multi_source and "" or "MART", "ORDERS", "o", "PRIMARY", 1},
                    {102, 2, "primary", "RELATION", "MART", "TICKETS", "t", "PRIMARY", 1},
                    {103, 3, "primary", "RELATION", "MART", "CUSTOMERS", "c", "PRIMARY", 1},
                }
            end
            if options.promoted_primary then
                return {
                    {104, 1, "archive", "VIRTUAL_SCHEMA", "VS_ARCHIVE", "ORDERS", "o", "PRIMARY", 40},
                    {101, 1, "primary", "RELATION", "MART", "ORDERS", "o", "ALTERNATE", 1},
                }
            end
            if options.f3_union then
                return {
                    {104, 1, "hot", "RELATION", "MART", "ORDERS_HOT", "o", "PRIMARY", 1,
                        nil, "o.order_ts >= TIMESTAMP '2026-01-01 00:00:00'",
                        "2026-01-01 00:00:00", nil},
                    {105, 1, "cold", "VIRTUAL_SCHEMA", "VS_LAKE", "ORDERS", "o", "ALTERNATE", 20,
                        nil, "o.order_ts < TIMESTAMP '2026-01-01 00:00:00'",
                        nil, "2026-01-01 00:00:00"},
                }
            end
            return {
                {101, 1, "primary", "RELATION", "MART", "ORDERS", "o", "PRIMARY", 1},
                {104, 1, "archive", "VIRTUAL_SCHEMA", "VS_ARCHIVE", "ORDERS", "o", "ALTERNATE", 20},
            }
        elseif normalized:find("JOIN SYS_SEMANTIC.DIMENSIONS", 1, true) then
            if options.multi_fact then
                return {{10, "customer_region", 3, "c.region", "VARCHAR(20)",
                    "Customer Region"}}
            end
            if options.strict_target then
                return {{10, "order_status", 2, "c.status", "VARCHAR(20)",
                    "Order Status"}}
            end
            return {{10, "order_status", 1, "o.status", "VARCHAR(20)",
                "Order Status"}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_INPUTS mi", 1, true) then
            if options.multi_fact then
                return {
                    {30, "NUMERATOR", "METRIC", 31, "revenue", nil, nil, 1},
                    {30, "DENOMINATOR", "METRIC", 32, "tickets", nil, nil, 2},
                    {31, "MEASURE", "FACT", 20, "revenue", nil, nil, 1},
                    {32, "MEASURE", "FACT", 21, "tickets", nil, nil, 1},
                }
            end
            return {{30, "MEASURE", "FACT", 20, "net_revenue", nil, nil, 1}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_FILTERS mf", 1, true) then
            if options.multi_fact then return {} end
            return {{30, "LOCAL", "order_status = 'COMPLETE'",
                "o.status = 'COMPLETE'", 10, 1, 1}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_DEPENDENCIES md", 1, true) then
            if options.multi_fact then
                return {
                    {30, "METRIC", 31}, {30, "METRIC", 32},
                    {31, "FACT", 20}, {32, "FACT", 21},
                }
            end
            return {{30, "FACT", 20}}
        elseif normalized:find("JOIN SYS_SEMANTIC.METRICS", 1, true) then
            if options.multi_fact then
                return {{30, "activity_ratio", 1, "revenue / tickets", nil,
                    "RATIO", "DECIMAL(18,4)", "Activity Ratio", "RATIO",
                    nil, nil, nil, nil, nil, nil, nil, nil}}
            end
            if options.unsupported_metric then
                return {{30, "total_revenue", 1, "COUNT(DISTINCT o.customer_id)", nil,
                    "DISTINCT", "DECIMAL(18,0)", "Total Revenue", "DISTINCT",
                    "COUNT_DISTINCT", "o.customer_id", nil, nil, "o.customer_id",
                    nil, nil, nil}}
            end
            return {{30, "total_revenue", 1, "SUM(net_revenue)", nil,
                "ADDITIVE", "DECIMAL(18,2)", "Total Revenue", "SIMPLE",
                "SUM", "o.amount", nil, nil, nil, nil, nil,
                '{"metric_type":"SIMPLE"}'}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRICS", 1, true) then
            if options.multi_fact then
                return {
                    {30, "activity_ratio", 1, "revenue / tickets", nil,
                        "RATIO", "DECIMAL(18,4)", "Activity Ratio", "RATIO",
                        nil, nil, nil, nil, nil, nil, nil, nil},
                    {31, "revenue", 1, "SUM(revenue_fact)", nil,
                        "ADDITIVE", "DECIMAL(18,2)", "Revenue", "SIMPLE",
                        "SUM", "o.amount", nil, nil, nil, nil, nil, nil},
                    {32, "tickets", 2, "COUNT(ticket_fact)", nil,
                        "ADDITIVE", "DECIMAL(18,0)", "Tickets", "SIMPLE",
                        "COUNT", "t.ticket_id", nil, nil, nil, nil, nil, nil},
                }
            end
            if options.unsupported_metric then
                return {{30, "total_revenue", 1, "COUNT(DISTINCT o.customer_id)", nil,
                    "DISTINCT", "DECIMAL(18,0)", "Total Revenue", "DISTINCT",
                    "COUNT_DISTINCT", "o.customer_id", nil, nil, "o.customer_id",
                    nil, nil, nil}}
            end
            return {{30, "total_revenue", 1, "SUM(net_revenue)", nil,
                "ADDITIVE", "DECIMAL(18,2)", "Total Revenue", "SIMPLE",
                "SUM", "o.amount", nil, nil, nil, nil, nil,
                '{"metric_type":"SIMPLE"}'}}
        elseif normalized:find("FROM SYS_SEMANTIC.FACTS", 1, true) then
            if options.multi_fact then
                return {
                    {20, "revenue_fact", 1, "o.amount", "DECIMAL(18,2)"},
                    {21, "ticket_fact", 2, "t.ticket_id", "DECIMAL(18,0)"},
                }
            end
            return {{20, "net_revenue", 1, "o.amount", "DECIMAL(18,2)"}}
        elseif normalized:find("FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS", 1, true) then
            if options.f3_union then
                local bindings = {
                    {301, 1, "DIMENSION", 10, 104, "o.status", "PREFER", 1, true},
                    {302, 1, "FACT", 20, 104, "o.amount", "PREFER", 1, true},
                    {303, 1, "DIMENSION", 10, 105, "o.order_status", "PREFER", 1, false},
                    {304, 1, "FACT", 20, 105, "o.net_amount", "PREFER", 1, false},
                }
                if options.f3_missing_fact_binding then table.remove(bindings, 4) end
                return bindings
            end
            if options.promoted_primary then
                return {
                    {301, 1, "DIMENSION", 10, 101, "o.status", "PREFER", 1, true},
                    {302, 1, "FACT", 20, 101, "o.amount", "PREFER", 1, true},
                    {303, 1, "DIMENSION", 10, 104, "o.archive_status", "PREFER", 1, false},
                    {304, 1, "FACT", 20, 104, "o.archive_amount", "PREFER", 1, false},
                }
            end
            if options.f2_fallback then
                return {
                    {301, 1, "DIMENSION", 10, 104, "o.archive_status", "FALLBACK", 1},
                    {302, 1, "FACT", 20, 104, "o.archive_amount", "FALLBACK", 1},
                }
            end
            return {}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIPS", 1, true) then
            if options.multi_fact then
                return {
                    {60, "orders_customer", 1, 3,
                        "o.customer_id = c.customer_id", "MANY_TO_ONE", "LEFT", nil, 100},
                    {61, "tickets_customer", 2, 3,
                        "t.customer_id = c.customer_id", "MANY_TO_ONE", "LEFT", nil, 100},
                }
            end
            if options.strict_target then
                return {{60, "orders_customer", 1, 2,
                    "o.customer_id = c.customer_id", "MANY_TO_ONE", "LEFT", nil, 100}}
            end
            return {}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS", 1, true) then
            if options.multi_fact and not options.missing_multi_mapping then
                return {
                    {60, 1, "customer_id", nil, "customer_id", nil},
                    {61, 1, "customer_id", nil, "customer_id", nil},
                }
            end
            return {}
        elseif normalized:find("FROM SYS_SEMANTIC.UNIQUE_KEYS", 1, true) then
            if options.multi_fact then
                return {{50, 3, "customer_pk", "PRIMARY", "NATIVE"}}
            end
            return {{50, 1, "orders_pk", "PRIMARY", "NATIVE"}}
        elseif normalized:find("FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS", 1, true) then
            if options.multi_fact then
                return {{50, 1, "customer_id", nil}}
            end
            return {{50, 1, "order_id", nil}}
        elseif normalized:find("FROM SYS_SEMANTIC.SYNONYMS", 1, true) then
            if options.multi_fact then
                return {{"METRIC", 30, "ratio"}, {"DIMENSION", 10, "region"}}
            end
            return {{"METRIC", 30, "revenue"}, {"DIMENSION", 10, "status"}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_DEPENDENCIES", 1, true) then
            if options.multi_fact then
                if tonumber(params.metric_id) == 30 then
                    return {{"METRIC", 31}, {"METRIC", 32}}
                elseif tonumber(params.metric_id) == 31 then
                    return {{"FACT", 20}}
                elseif tonumber(params.metric_id) == 32 then
                    return {{"FACT", 21}}
                end
                return {}
            end
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
    assert_equal(state.representation_reads, 1)
    assert_contains(first.generated_sql, "UPPER(o.status) = UPPER('COMPLETE')")
    assert_contains(first.generated_sql, "HAVING SUM((o.amount)) > 100")
    assert_contains(first.generated_sql, 'ORDER BY "total_revenue" DESC')
    assert_contains(first.generated_sql, "LIMIT 25")
    assert_contains(first.plan_json, '"validation_run_id":77')
    assert_contains(first.plan_json, '"input_roles"')
    assert_contains(first.plan_json, '"selection_reason":"STATIC_PRIMARY"')
    assert_contains(first.plan_json, '"representation_name":"primary"')
    assert_true(not string.find(first.generated_sql, "VS_ARCHIVE", 1, true))
    assert_equal(state.cache_inserts, 1)
    assert_equal(#state.request_logs, 1)
    assert_equal(state.request_logs[1].client_name, "lua-tests")
    assert_true(type(state.request_logs[1].runtime_ms) == "number")

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

test("F2 compiler selects one complete fallback representation", function()
    local result = compile_with_fixture({
        model = "sales",
        object = "SALES",
        metrics = {"revenue"},
        dimensions = {"status"},
    }, {f2_fallback = true})
    assert_equal(result.status, "OK")
    assert_contains(result.generated_sql, 'FROM "VS_ARCHIVE"."ORDERS" o')
    assert_contains(result.generated_sql, "o.archive_status")
    assert_contains(result.generated_sql, "SUM((o.archive_amount))")
    assert_contains(result.plan_json, '"selection_reason":"ATTRIBUTE_FALLBACK"')
    assert_contains(result.plan_json, '"attribute":"DIMENSION:10"')
    assert_contains(result.plan_json, '"attribute":"FACT:20"')
end)

test("F2 compiler prefers the promoted primary when bindings are equivalent", function()
    local result = compile_with_fixture({
        model = "sales",
        object = "SALES",
        metrics = {"revenue"},
        dimensions = {"status"},
    }, {promoted_primary = true})
    assert_equal(result.status, "OK")
    assert_contains(result.generated_sql, 'FROM "VS_ARCHIVE"."ORDERS" o')
    assert_contains(result.generated_sql, "o.archive_status")
    assert_contains(result.generated_sql, "SUM((o.archive_amount))")
    assert_contains(result.plan_json, '"representation_name":"archive"')
end)

test("F3 compiler unions hot and cold aggregate-state partitions", function()
    local result = compile_with_fixture({
        model = "sales",
        object = "SALES",
        metrics = {"revenue"},
        dimensions = {"status"},
        proof_mode = "STRICT_GRAIN",
    }, {f3_union = true})
    assert_equal(result.status, "OK")
    assert_contains(result.generated_sql, 'FROM "MART"."ORDERS_HOT" o')
    assert_contains(result.generated_sql, 'FROM "VS_LAKE"."ORDERS" o')
    assert_contains(result.generated_sql, "o.net_amount")
    assert_contains(result.generated_sql, "o.order_status")
    assert_contains(result.generated_sql,
        "o.order_ts < TIMESTAMP '2026-01-01 00:00:00'")
    assert_contains(result.generated_sql, "UNION ALL")
    assert_contains(result.plan_json, '"fusion_strategy":"UNION"')
    assert_contains(result.plan_json, '"fusion_plan_version":1')
    assert_contains(result.plan_json, '"representation_name":"cold"')
end)

test("F3 compiler diagnostics name failing model objects", function()
    local metric_failure = compile_with_fixture({
        model = "sales",
        object = "SALES",
        metrics = {"revenue"},
    }, {f3_union = true, unsupported_metric = true})
    assert_equal(metric_failure.error_code, "SEMANTIC_REQUEST_070")
    assert_contains(metric_failure.error_message, "Metric 'total_revenue'")
    assert_contains(metric_failure.error_message, "COUNT_DISTINCT")
    assert_contains(metric_failure.error_message, "entity 'orders' is partitioned")

    local binding_failure = compile_with_fixture({
        model = "sales",
        object = "SALES",
        metrics = {"revenue"},
        dimensions = {"status"},
    }, {f3_union = true, f3_missing_fact_binding = true})
    assert_equal(binding_failure.error_code, "SEMANTIC_REQUEST_080")
    assert_contains(binding_failure.error_message, "Attribute 'net_revenue'")
    assert_contains(binding_failure.error_message, "partition 'cold'")
    assert_contains(binding_failure.error_message, "ADD_ATTRIBUTE_BINDING")

    local dimension_message = api.typed_failure_message({
        reason_code = "FUSION_PARTITION_DIMENSION_UNSUPPORTED",
        dimension = "web_campaign_channel",
        entity_name = "campaign",
        usage = "SELECTED_DIMENSION",
    })
    assert_contains(dimension_message, "Dimension 'web_campaign_channel'")
    assert_contains(dimension_message, "partitioned entity 'campaign'")
    assert_contains(dimension_message, "joined dimensions are not supported")
end)

test("structured compiler renders unary null filters and having", function()
    local result = compile_with_fixture({
        model = "sales",
        object = "SALES",
        metrics = {"revenue"},
        dimensions = {"status"},
        filters = {{field = "status", op = "IS NULL"}},
        having = {{field = "total_revenue", op = "IS NOT NULL"}},
    })
    assert_equal(result.status, "OK")
    assert_contains(result.generated_sql, "WHERE o.status IS NULL")
    assert_contains(result.generated_sql, "HAVING SUM((o.amount)) IS NOT NULL")
end)

test("C3 compiler activates a versioned multi branch query", function()
    local request = {
        model = "sales",
        object = "SALES",
        metrics = {"activity_ratio"},
        dimensions = {"customer_region"},
        having = {{field = "activity_ratio", op = ">", value = 1}},
        order_by = {{field = "activity_ratio", direction = "DESC"}},
        limit = 10,
    }
    local result, state, mock = compile_with_fixture(request, {multi_fact = true})
    assert_equal(result.status, "OK")
    assert_equal(result.error_code, nil)
    assert_contains(result.generated_sql, "UNION ALL")
    assert_contains(result.generated_sql, 'COALESCE(ms."__esv_s_32", 0)')
    assert_contains(result.generated_sql,
        'f."__esv_m_30" AS "activity_ratio"')
    assert_contains(result.generated_sql, 'WHERE f."__esv_m_30" > 1')
    assert_contains(result.generated_sql, 'ORDER BY "activity_ratio" DESC')
    assert_contains(result.generated_sql, "LIMIT 10")
    local envelope = api.json_decode(result.plan_json)
    assert_equal(envelope.plan_version, 10)
    assert_equal(envelope.logical_plan.plan_kind, "MULTI_BRANCH")
    assert_equal(envelope.logical_plan.execution.status, "EXECUTABLE")
    assert_equal(envelope.logical_plan.physical_plan.physical_plan_version, 6)
    assert_equal(envelope.logical_plan.physical_plan.plan_kind,
        "MULTI_BRANCH_QUERY")
    assert_true(envelope.logical_plan.physical_plan.safeguards.sql_size_bytes > 0)
    assert_equal(envelope.logical_plan.physical_plan.branches[1].source.source_kind,
        "BASE")
    assert_equal(envelope.metric_details[1].name, "activity_ratio")
    assert_equal(#envelope.logical_plan.branches, 2)
    assert_equal(#envelope.logical_plan.relationship_proofs, 2)
    assert_equal(envelope.logical_plan.relationship_proofs[1].status, "PROVEN")
    assert_equal(state.cache_inserts, 1)

    local cached = with_query(mock, function()
        return compile_request_json(api.json_encode(request))
    end)
    assert_equal(cached.status, "OK")
    assert_equal(cached.cache_hit, true)
    assert_equal(cached.generated_sql, result.generated_sql)
    assert_equal(state.cache_inserts, 1)
    assert_equal(state.cache_touches, 1)

    local rejected = compile_with_fixture(request, {
        multi_fact = true,
        missing_multi_mapping = true,
    })
    assert_equal(rejected.error_code, "SEMANTIC_REQUEST_074")
    local rejected_plan = api.json_decode(rejected.plan_json).logical_plan
    assert_equal(rejected_plan.failure.reason_code, "RELATIONSHIP_MAPPING_MISSING")
    assert_equal(rejected_plan.failure.dimension_id, 10)
    assert_equal(rejected_plan.failure.blocking_edge.relationship_id, 60)
    assert_true(string.match(rejected_plan.failure.proof_id,
        "^proof:branch:") ~= nil)
    assert_true(string.match(rejected_plan.failure.rejection_id,
        ":rejection$") ~= nil)

    local physical_rejected = compile_with_fixture(request, {
        multi_fact = true,
        missing_multi_source = true,
    })
    assert_equal(physical_rejected.error_code, "SEMANTIC_REQUEST_075")
    assert_equal(physical_rejected.generated_sql, nil)
    local physical_failure = api.json_decode(
        physical_rejected.plan_json).logical_plan.failure
    assert_equal(physical_failure.reason_code, "PHYSICAL_BINDING_INCOMPLETE")
    assert_equal(physical_failure.binding_kind, "SOURCE")

    local sql_mock = compiler_query_fixture({multi_fact = true})
    local sql_result = with_query(sql_mock, function()
        return compile_sql([[
            SELECT customer_region, MEASURE(activity_ratio)
            FROM SEMANTIC_SALES.SALES
            GROUP BY ALL
            HAVING activity_ratio > 1
            ORDER BY activity_ratio DESC
            LIMIT 10
        ]])
    end)
    assert_equal(sql_result.status, "OK")
    assert_equal(sql_result.error_code, nil)
    assert_contains(sql_result.generated_sql, "UNION ALL")
    local sql_plan = api.json_decode(sql_result.plan_json).logical_plan
    assert_equal(api.json_encode(sql_plan), api.json_encode(envelope.logical_plan))
end)

test("structured compiler maps request and validation failures", function()
    local malformed_mock = compiler_query_fixture()
    local malformed = with_query(malformed_mock, function()
        return compile_request_json('{"model":]')
    end)
    assert_equal(malformed.error_code, "SEMANTIC_REQUEST_001")

    local cases = {
        {{model = "sales", object = "SALES", metrics = "revenue"},
            nil, "SEMANTIC_REQUEST_001"},
        {{model = "sales", object = "SALES", metrics = {"revenue"},
            output = {shape = "nested"}}, nil, "SEMANTIC_REQUEST_004"},
        {{model = "sales", object = "SALES", metrics = {"revenue"},
            proof_mode = "unproven"}, nil, "SEMANTIC_REQUEST_071"},
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
            proof_mode = "STRICT_GRAIN"},
            {unsupported_metric = true}, "SEMANTIC_REQUEST_070"},
        {{model = "sales", object = "SALES", metrics = {"revenue"},
            dimensions = {"status"}, proof_mode = "STRICT_GRAIN"},
            {strict_target = true}, "SEMANTIC_REQUEST_072"},
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

    local unknown_keys = compile_with_fixture(
        {model = "sales", object = "SALES", metrics = {"revenue"},
            zebra = true, output = {shape = "nested"}})
    assert_equal(unknown_keys.error_code, "SEMANTIC_REQUEST_004")
    assert_contains(unknown_keys.error_message,
        "Unknown top-level request key(s): output, zebra.")
    assert_contains(unknown_keys.error_message,
        "Allowed keys: client, dimensions, filters")

    local legacy_unsupported = compile_with_fixture(
        {model = "sales", object = "SALES", metrics = {"revenue"}},
        {unsupported_metric = true})
    assert_equal(legacy_unsupported.status, "OK")
    assert_contains(legacy_unsupported.generated_sql, "COUNT(DISTINCT")
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
    assert_true(type(state.query_logs[1].runtime_ms) == "number")

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

test("grain metadata migration assistant is dry run and conservative", function()
    local calls = 0
    local mock = function(sql, params)
        calls = calls + 1
        local normalized = tostring(sql):gsub("%s+", " ")
        if normalized:find("FROM SYS_SEMANTIC.MODELS", 1, true) then
            return {{1, 2, 3}}
        elseif normalized:find("FROM SYS_SEMANTIC.ENTITIES", 1, true) then
            return {
                {1, "orders", "o", "o.order_id"},
                {2, "customers", "c", "UPPER(c.customer_id)"},
            }
        elseif normalized:find("FROM SYS_SEMANTIC.UNIQUE_KEYS", 1, true) then
            return {{0}}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIPS", 1, true) then
            return {{10, "orders_customer", 1, 2,
                "c.customer_id = o.customer_id"}}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS", 1, true) then
            return {{0}}
        end
        error("unexpected migration query: " .. normalized)
    end
    local rows = with_query(mock, function()
        return suggest_grain_metadata("sales")
    end)
    assert_equal(#rows, 2)
    assert_equal(rows[1][1], "UNIQUE_KEY")
    assert_contains(rows[1][4], '"column_name":"order_id"')
    assert_equal(rows[2][1], "RELATIONSHIP_MAPPING")
    assert_contains(rows[2][4], '"from_column_name":"customer_id"')
    assert_true(calls > 0)

    local missing = with_query(function() return {} end, function()
        return suggest_grain_metadata("missing")
    end)
    assert_equal(missing[1][1], "ERROR")
end)
