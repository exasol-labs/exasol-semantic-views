-- Every physical relation this fixture's compiler can render. The live
-- trust-boundary check reads the same four declaration tables the planner does,
-- so the mock answers that query from one list rather than from nine scattered
-- representation fixtures: a new fixture source is added here, once, instead of
-- being silently rejected on the next cache read.
local FIXTURE_BOUNDARY = {
    {"MART", "ORDERS"}, {"MART", "ORDERS_HOT"}, {"MART", "TICKETS"},
    {"MART", "CUSTOMERS"}, {"MART", "SALES_AGG"},
    {"CRM", "CUSTOMERS"}, {"ARCHIVE", "ORDERS"}, {"MONGO", "CUSTOMERS"},
    {"VS_ARCHIVE", "ORDERS"}, {"VS_LAKE", "ORDERS"},
    {"IDENTITY_MAP", "ORDER_XREF"},
}

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
        boundary_reads = 0,
        cache_discards = 0,
    }

    local function mock(sql, params)
        local normalized = tostring(sql):gsub("%s+", " ")
        -- SEMANTIC_SOURCE is a privilege boundary, not a different shape: each
        -- view is `SELECT * FROM SYS_SEMANTIC.<same table>` plus an
        -- authorization filter the fixture has no principals to exercise. So
        -- the mock answers for the table either way, and the branches below stay
        -- written against one name.
        normalized = normalized:gsub("SEMANTIC_SOURCE%.", "SYS_SEMANTIC.")
        params = params or {}

        if normalized:find("SYS_SEMANTIC.MODEL_RELATIONS", 1, true) then
            -- The trust boundary reads one view that unions the three
            -- declaration tables, so it carries the authorization filter once
            -- instead of three times -- which is what keeps a cache hit free.
            state.boundary_reads = state.boundary_reads + 1
            if options.trust_boundary ~= nil then
                return options.trust_boundary
            end
            local relations = {}
            for index, pair in ipairs(FIXTURE_BOUNDARY) do
                relations[index] = {pair[1], pair[2]}
            end
            return relations
        elseif normalized:find("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE", 1, true) then
            state.cache_discards = state.cache_discards + 1
            state.cache[params.cache_key] = nil
            return {}
        elseif normalized:find("SELECT GENERATED_SQL, PLAN_JSON, VALIDATION_RUN_ID", 1, true) then
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
        elseif options.tableau_group and normalized:find("SELECT ALLOW_DERIVED_COMPOSITION", 1, true) then
            return {{false}}
        elseif options.tableau_group and normalized:find(
            "SELECT oc.COLUMN_NAME, oc.COLUMN_KIND, mt.AGGREGATION_FUNCTION", 1, true) then
            return {{"completed_revenue", "METRIC", "SUM"},
                {"customer_region", "DIMENSION", nil}}
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
                local representations = {
                    {101, 1, "primary", "RELATION", options.missing_multi_source and "" or "MART", "ORDERS", "o", "PRIMARY", 1},
                    {102, 2, "primary", "RELATION", "MART", "TICKETS", "t", "PRIMARY", 1},
                    {103, 3, "primary", "RELATION", "MART", "CUSTOMERS", "c", "PRIMARY", 1},
                }
                if options.f4_reconcile then
                    representations[#representations + 1] =
                        {106, 3, "crm", "RELATION", "CRM", "CUSTOMERS", "c",
                            "ALTERNATE", 20, nil, nil, nil, nil, "SUPPLEMENTAL"}
                    representations[3][14] = "AUTHORITATIVE"
                end
                if options.f4_fact_reconcile then
                    representations[#representations + 1] =
                        {104, 1, "archive", "RELATION", "ARCHIVE", "ORDERS", "o",
                            "ALTERNATE", 20, nil, nil, nil, nil, "SUPPLEMENTAL"}
                    representations[1][14] = "AUTHORITATIVE"
                end
                return representations
            end
            if options.f51_direct then
                return {
                    {101, 1, "primary", "RELATION", "MART", "ORDERS", "o", "PRIMARY", 1},
                    {103, 2, "primary", "RELATION", "MART", "CUSTOMERS", "c", "PRIMARY", 1},
                    {106, 2, "mongo", "VIRTUAL_SCHEMA", "MONGO", "CUSTOMERS", "c", "ALTERNATE", 20},
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
            if options.f4_reconcile then
                return {
                    {101, 1, "primary", "RELATION", "MART", "ORDERS", "o", "PRIMARY", 1,
                        nil, nil, nil, nil, "AUTHORITATIVE"},
                    {104, 1, "archive", "RELATION", "ARCHIVE", "ORDERS", "o", "ALTERNATE", 20,
                        nil, nil, nil, nil, "SUPPLEMENTAL"},
                }
            end
            return {
                {101, 1, "primary", "RELATION", "MART", "ORDERS", "o", "PRIMARY", 1},
                {104, 1, "archive", "VIRTUAL_SCHEMA", "VS_ARCHIVE", "ORDERS", "o", "ALTERNATE", 20},
            }
        elseif normalized:find("JOIN SYS_SEMANTIC.DIMENSIONS", 1, true) then
            if options.tableau_group then
                return {{10, "customer_region", 1, "o.region", "VARCHAR(20)",
                    "Customer Region"}}
            end
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
            if options.tableau_group then return {} end
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
            if options.tableau_group then
                return {{30, "completed_revenue", 1, "SUM(net_revenue)", nil,
                    "ADDITIVE", "DECIMAL(18,2)", "Completed Revenue", "SIMPLE",
                    "SUM", "o.amount", nil, nil, nil, nil, nil,
                    '{"metric_type":"SIMPLE"}'}}
            end
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
            if options.tableau_group then
                return {{30, "completed_revenue", 1, "SUM(net_revenue)", nil,
                    "ADDITIVE", "DECIMAL(18,2)", "Completed Revenue", "SIMPLE",
                    "SUM", "o.amount", nil, nil, nil, nil, nil,
                    '{"metric_type":"SIMPLE"}'}}
            end
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
            if options.multi_fact and options.f4_reconcile then
                return {
                    {301, 3, "DIMENSION", 10, 103, "c.region", "PREFER", 1, false},
                    {302, 3, "DIMENSION", 10, 106, "c.region_name", "PREFER", 1, false},
                }
            end
            if options.multi_fact and options.f4_fact_reconcile then
                return {
                    {301, 1, "FACT", 20, 101, "o.amount", "PREFER", 1, false},
                    {302, 1, "FACT", 20, 104, "o.archive_amount", "PREFER", 1, false},
                    {303, 2, "FACT", 21, 102, "t.ticket_id", "PREFER", 1, false},
                    {304, 3, "DIMENSION", 10, 103, "c.region", "PREFER", 1, false},
                }
            end
            if options.f51_direct then
                local bindings = {{305, 2, "DIMENSION", 10, 106,
                    'c."status"', "PREFER", 1, false}}
                if options.f51_unusable and not options.f51_no_candidate then
                    bindings[#bindings + 1] = {306, 2, "DIMENSION", 10, 103,
                        "c.status", "FALLBACK", 1, false}
                end
                return bindings
            end
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
            if options.f4_reconcile then
                return {
                    {301, 1, "DIMENSION", 10, 101, "o.status", "PREFER", 1, false},
                    {302, 1, "DIMENSION", 10, 104, "o.archive_status", "PREFER", 1, false},
                    {303, 1, "FACT", 20, 101, "o.amount", "PREFER", 1, false},
                    {304, 1, "FACT", 20, 104, "o.archive_amount", "PREFER", 1, false},
                }
            end
            return {}
        elseif normalized:find("FROM SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES", 1, true) then
            if options.multi_fact and options.f4_fact_reconcile then
                return {{1, "FACT", 20, "RECONCILE"}}
            end
            if options.f4_reconcile then
                return {{1, "DIMENSION", 10, "RECONCILE"}}
            end
            return options.f4_policies or {}
        elseif normalized:find("FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES", 1, true) then
            if options.f51_direct then
                return {{502, 2, "customer_identity", "GLOBAL", "DECIMAL(18,0)"}}
            end
            if options.f5_identity then
                return {{501, 1, "customer_identity", "GLOBAL", "DECIMAL(18,0)"}}
            end
            return options.f5_identities or {}
        elseif normalized:find("FROM SYS_SEMANTIC.IDENTITY_BINDINGS", 1, true) then
            if options.f51_direct then
                return {
                    {603, 2, 502, 103, "c.CUSTOMER_ID", "DIRECT",
                        null, null, null, null, null, null},
                    {604, 2, 502, 106,
                        'CAST(c."customer_id" AS DECIMAL(18,0))',
                        (options.f51_unusable or options.f51_no_candidate)
                            and "MAPPED" or "DIRECT",
                        (options.f51_unusable or options.f51_no_candidate) and 705 or null,
                        (options.f51_unusable or options.f51_no_candidate) and "IDENTITY_MAP" or null,
                        (options.f51_unusable or options.f51_no_candidate) and "CUSTOMER_XREF" or null,
                        (options.f51_unusable or options.f51_no_candidate) and "customer_id" or null,
                        (options.f51_unusable or options.f51_no_candidate) and "CUSTOMER_ID" or null,
                        (options.f51_unusable or options.f51_no_candidate) and "CERTIFIED" or null},
                }
            end
            if options.f5_identity then
                return {
                    -- The base representation's own identity is MAPPED too when
                    -- f5_mapped_base is set, which is the only way to reach
                    -- base_semantic_key_expression's mapped branch. Its mapping
                    -- columns are declared lower case on purpose: BUG-G03 was
                    -- these two names being quoted verbatim.
                    options.f5_mapped_base
                        and {601, 1, 501, 101, "o.order_id", "MAPPED",
                            700, "IDENTITY_MAP", "ORDER_XREF", "order_id",
                            "order_id", "CERTIFIED"}
                        or {601, 1, 501, 101, "o.order_id", "DIRECT",
                            null, null, null, null, null, null},
                    {602, 1, 501, 104, "o.legacy_order_id", "MAPPED",
                        701, "IDENTITY_MAP", "ORDER_XREF", "LEGACY_ORDER_ID",
                        "ORDER_ID", "CERTIFIED"},
                }
            end
            return options.f5_identity_bindings or {}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIPS", 1, true) then
            if options.multi_fact then
                return {
                    {60, "orders_customer", 1, 3,
                        "o.customer_id = c.customer_id", "MANY_TO_ONE", "LEFT", nil, 100},
                    {61, "tickets_customer", 2, 3,
                        "t.customer_id = c.customer_id", "MANY_TO_ONE", "LEFT", nil, 100},
                }
            end
            if options.strict_target or options.f51_direct then
                return {{60, "orders_customer", 1, 2,
                    "o.CUSTOMER_ID = c.CUSTOMER_ID", "MANY_TO_ONE", "LEFT", nil, 100}}
            end
            return {}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS", 1, true) then
            if options.multi_fact and not options.missing_multi_mapping then
                return {
                    {60, 1, "customer_id", nil, "customer_id", nil},
                    {61, 1, "customer_id", nil, "customer_id", nil},
                }
            end
            if options.f51_direct then
                return {{60, 1, "CUSTOMER_ID", nil, "CUSTOMER_ID", nil}}
            end
            return {}
        elseif normalized:find("FROM SYS_SEMANTIC.UNIQUE_KEYS", 1, true) then
            if options.multi_fact then
                if options.f4_fact_reconcile then
                    return {
                        {50, 3, "customer_pk", "PRIMARY", "NATIVE"},
                        {51, 1, "orders_pk", "PRIMARY", "NATIVE"},
                    }
                end
                return {{50, 3, "customer_pk", "PRIMARY", "NATIVE"}}
            end
            if options.f51_direct then
                return {{50, 2, "customer_pk", "PRIMARY", "NATIVE"}}
            end
            return {{50, 1, "orders_pk", "PRIMARY", "NATIVE"}}
        elseif normalized:find("FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS", 1, true) then
            if options.multi_fact then
                if options.f4_fact_reconcile then
                    return {
                        {50, 1, "customer_id", nil},
                        {51, 1, "order_id", nil},
                    }
                end
                return {{50, 1, "customer_id", nil}}
            end
            if options.f51_direct then return {{50, 1, "CUSTOMER_ID", nil}} end
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
            if options.stale_validation then
                if normalized:find("SELECT STATUS, ERROR_COUNT", 1, true) then
                    return {{"STALE", 0}}
                end
                return {}
            end
            if options.no_validation then return {} end
            return {{77, "OK", 0}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_DIMENSION_MATRIX", 1, true) then
            if options.missing_matrix then return {} end
            if options.invalid_matrix then
                return {{false, "ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED", nil}}
            end
            return {{true, "OK", "SELF"}}
        elseif normalized:find("FROM SYS_SEMANTIC.METRIC_INPUTS", 1, true) then
            return {{"MEASURE", "FACT", "net_revenue"}}
        elseif normalized:find("FROM SYS.EXA_ALL_TABLES", 1, true) then
            -- The orphan probe: does this schema carry the SEMANTIC_DISCOVERY
            -- table PUBLISH_MODEL always creates?
            return {{options.orphaned_schema and 1 or 0}}
        elseif normalized:find("FROM SYS.EXA_ALL_COLUMNS", 1, true) then
            if options.f51_direct and params.schema_name == "MONGO"
                and params.column_name == "CUSTOMER_ID" then return {{0}} end
            -- Two shapes reach this view: an existence count, and the shared
            -- resolver asking for the physical spelling of a declared column.
            -- Exasol stores an unquoted identifier upper-cased, so the resolver
            -- answer is upper case even when the model declared lower case.
            if normalized:find("SELECT COLUMN_NAME", 1, true) then
                return {{COLUMN_NAME = string.upper(tostring(params.column_name))}}
            end
            return {{1}}
        end
        error("unexpected compiler fixture query: " .. normalized)
    end
    return mock, state
end

return compiler_query_fixture
