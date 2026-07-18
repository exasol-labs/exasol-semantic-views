local api = ESV_SEMANTIC_DEFINITION_TEST_API

test("semantic definition splits top-level members without splitting expressions", function()
    local parts = api.split_top_level_text("SUM(a, b), RATIO(x, NULLIF(y, 0)), z")
    assert_equal(#parts, 3)
    assert_contains(parts[2], "NULLIF")
end)

test("semantic definition parses aggregate structure", function()
    local fn, expression = api.aggregate_parts("SUM(net_revenue)")
    assert_equal(fn, "SUM")
    assert_equal(expression, "net_revenue")
    local absent = api.aggregate_parts("gross_margin / revenue")
    assert_branch("definition.aggregate", fn ~= nil, true)
    assert_branch("definition.aggregate", absent ~= nil, false)
end)

test("Databricks helpers parse table references filters and measures", function()
    local schema, object = api.dbx_table_ref("catalog.sales.orders")
    assert_equal(schema, "SALES")
    assert_equal(object, "ORDERS")
    local measure = api.dbx_unwrap_measures("MEASURE(revenue) / MEASURE(units)")
    assert_equal(measure, "revenue / units")
    local aggregate, inner = api.dbx_aggregate("SUM(orders.amount)")
    assert_equal(aggregate, "SUM")
    assert_equal(inner, "orders.amount")
end)

test("semantic definition JSON round-trip supports escaped strings", function()
    local encoded = api.json_encode({name = "a\nb", values = {1, 2}})
    local decoded = api.json_decode(encoded)
    assert_equal(decoded.name, "a\nb")
    assert_equal(decoded.values[2], 2)
end)

test("semantic definition parses facts and all executable metric shapes", function()
    local definition = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        REPLACE FACTS (
          FACT net_revenue ON ENTITY order_line AS ol.amount
            RETURNS DECIMAL(18,2) ADDITIVE DISPLAY 'Net Revenue'
            COMMENT 'Revenue' PUBLIC CERTIFIED,
          FACT inventory ON ENTITY product AS p.stock
            RETURNS DECIMAL(18,0) NON ADDITIVE BY snapshot_day PRIVATE
        )
        REPLACE METRICS (
          METRIC total_revenue AS SUM(net_revenue) ON ENTITY order_line
            RETURNS DECIMAL(18,2) FORMAT 'currency'
            SYNONYMS ('revenue', 'sales') ADDITIVE PUBLIC CERTIFIED,
          METRIC completed_revenue AS SUM(net_revenue)
            FILTER (WHERE status = 'COMPLETE') ON ENTITY order_line
            RETURNS DECIMAL(18,2) ADDITIVE PUBLIC,
          METRIC margin AS total_revenue - total_cost ON ENTITY order_line
            RETURNS DECIMAL(18,2) DERIVED PUBLIC,
          METRIC margin_pct AS margin / NULLIF(total_revenue, 0) ON ENTITY order_line
            RETURNS DECIMAL(18,6) RATIO PUBLIC,
          METRIC buyers AS COUNT(customer_id) ON ENTITY order_line
            RETURNS DECIMAL(18,0) DISTINCT DISTINCT_KEY customer_id PUBLIC,
          METRIC closing_stock AS MAX(inventory) ON ENTITY product
            RETURNS DECIMAL(18,0) SEMI_ADDITIVE NON ADDITIVE BY snapshot_day PUBLIC,
          METRIC running_revenue AS SUM(net_revenue) ON ENTITY order_line
            RETURNS DECIMAL(18,2) WINDOW '{"order_by":"order_day"}' PUBLIC
        )
    ]])
    assert_equal(definition.model_name, "sales")
    assert_equal(definition.object_name, "SALES")
    assert_true(definition.replace_facts)
    assert_true(definition.replace_metrics)
    assert_equal(#definition.facts, 2)
    assert_equal(definition.facts[1].display_name, "Net Revenue")
    assert_equal(definition.facts[2].additive_policy, "NON_ADDITIVE")
    assert_true(definition.facts[2].is_private)
    assert_equal(#definition.metrics, 7)
    assert_equal(definition.metrics[1].aggregation_function, "SUM")
    assert_equal(definition.metrics[1].synonyms[2], "sales")
    assert_equal(definition.metrics[2].metric_kind, "FILTERED")
    assert_equal(definition.metrics[2].semantic_filter_expr, "status = 'COMPLETE'")
    assert_equal(definition.metrics[3].metric_kind, "DERIVED")
    assert_equal(definition.metrics[4].metric_kind, "RATIO")
    assert_equal(definition.metrics[5].metric_kind, "DISTINCT")
    assert_equal(definition.metrics[5].distinct_key_expr, "customer_id")
    assert_equal(definition.metrics[6].metric_kind, "SEMI_ADDITIVE")
    assert_equal(definition.metrics[6].non_additive_dimension, "snapshot_day")
    assert_equal(definition.metrics[7].metric_kind, "WINDOW")
    assert_contains(definition.metrics[7].window_spec_json, "order_day")
    assert_branch("definition.replace.metrics", definition.replace_metrics, true)
end)

test("semantic definition parses single metric replacement", function()
    local definition = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        ADD OR REPLACE METRIC total_revenue
          AS SUM(net_revenue) ON ENTITY order_line RETURNS DECIMAL(18,2)
          DISPLAY 'Total Revenue' COMMENT 'Recognized revenue' ADDITIVE PUBLIC CERTIFIED
    ]])
    assert_equal(#definition.metrics, 1)
    assert_equal(definition.metrics[1].name, "total_revenue")
    assert_equal(definition.metrics[1].description, "Recognized revenue")
    assert_true(definition.metrics[1].is_certified)
    assert_branch("definition.replace.metrics", definition.replace_metrics, false)
end)

test("semantic definition rejects incomplete authoring statements", function()
    local cases = {
        {"", "SEMANTIC_DDL_001"},
        {"SELECT 1", "SEMANTIC_DDL_010"},
        {"ALTER SEMANTIC VIEW sales REPLACE METRICS ()", "SEMANTIC_DDL_011"},
        {"ALTER SEMANTIC VIEW sales.SALES", "SEMANTIC_DDL_012"},
        {"ALTER SEMANTIC VIEW sales.SALES REPLACE FACTS FACT x", "SEMANTIC_DDL_023"},
        {"ALTER SEMANTIC VIEW sales.SALES REPLACE FACTS (FACT x", "SEMANTIC_DDL_024"},
        {"ALTER SEMANTIC VIEW sales.SALES REPLACE METRICS METRIC x", "SEMANTIC_DDL_033"},
        {"ALTER SEMANTIC VIEW sales.SALES REPLACE METRICS (METRIC x", "SEMANTIC_DDL_034"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE METRIC x ON ENTITY e RETURNS INT", "SEMANTIC_DDL_031"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE METRIC x AS SUM(f) ON ENTITY e", "SEMANTIC_DDL_032"},
    }
    for _, case in ipairs(cases) do
        assert_error(function() api.parse_definition(case[1]) end, case[2])
    end
end)

local function read_text(path)
    local file = assert(io.open(path, "r"))
    local value = file:read("*a")
    file:close()
    return value
end

test("Databricks fixture translates into deterministic native DDL", function()
    local doc = api.parse_databricks_yaml(
        read_text("tests/fixtures/databricks/orders_metric_view.yaml"))
    assert_equal(doc.source, "samples.tpch.orders")
    assert_equal(doc.joins[1].joins[1].name, "nation")
    assert_contains(doc.fields[2].expr, "CASE WHEN")
    assert_equal(doc.measures[2].synonyms[2], "sales")

    local diagnostics = {}
    local plan = api.dbx_translate(doc, "dbx_orders", "semantic_dbx", diagnostics)
    assert_equal(plan.model_name, "dbx_orders")
    assert_equal(plan.object_name, "DBX_ORDERS")
    assert_equal(#plan.entities, 3)
    assert_equal(#plan.relationships, 2)
    assert_equal(#plan.dimensions, 3)
    assert_equal(#plan.facts, 3)
    assert_equal(#plan.metrics, 4)
    assert_equal(plan.metrics[3].filter_pred, "o.o_orderstatus = 'O'")
    assert_equal(plan.metrics[4].kind, "RATIO")
    assert_contains(plan.metrics[4].expression, "NULLIF")
    assert_true(#diagnostics >= 1)

    local ddl = api.dbx_render_ddl(plan)
    assert_contains(ddl, "CREATE_MODEL('dbx_orders', 'SEMANTIC_DBX'")
    assert_contains(ddl, "ADD_RELATIONSHIP")
    assert_contains(ddl, "ALTER SEMANTIC VIEW dbx_orders.DBX_ORDERS")
    assert_contains(ddl, "FILTER (WHERE o.o_orderstatus = ''O'')")
    assert_contains(ddl, "RATIO")
    assert_branch("definition.dbx.metrics", #plan.metrics > 0, true)
end)

test("Databricks translation reports unsupported inputs without silent mutation", function()
    local diagnostics = {}
    local plan = api.dbx_translate({
        source = "sales.orders",
        joins = {
            {name = "bad_query", source = "SELECT * FROM x", on = "source.id = bad_query.id"},
            {name = "using_join", source = "sales.customer", using = "customer_id"},
            {name = "missing_condition", source = "sales.region"},
            {source = "sales.unknown", on = "source.id = unknown.id"},
        },
        fields = {{name = "missing_expr"}},
        measures = {
            {name = "windowed", expr = "SUM(amount)", window = "ORDER BY day"},
            {name = "not_aggregate", expr = "amount + tax"},
            {name = "filtered_ratio", expr = "MEASURE(a) / MEASURE(b) FILTER (WHERE status = 'A')"},
            {name = "incomplete"},
        },
        filter = "status = 'A'",
        materialization = {schedule = "daily"},
    }, "warnings", "semantic_warnings", diagnostics)
    assert_equal(#plan.relationships, 0)
    assert_equal(#plan.dimensions, 0)
    assert_equal(#plan.metrics, 1)
    assert_equal(plan.metrics[1].kind, "RATIO")
    assert_true(#diagnostics >= 9)

    local empty_diags = {}
    local empty = api.dbx_translate({source = "sales.orders", measures = {}},
        "empty_model", "semantic_empty", empty_diags)
    assert_equal(#empty.metrics, 0)
    assert_equal(api.dbx_render_ddl(empty):find("ALTER SEMANTIC VIEW", 1, true), nil)
    assert_branch("definition.dbx.metrics", #empty.metrics > 0, false)

    assert_error(function()
        api.dbx_translate({source = "SELECT * FROM sales.orders"}, "bad", "semantic_bad", {})
    end, "DBX_IMPORT_210")
    assert_error(function()
        api.dbx_translate({}, "bad", "semantic_bad", {})
    end, "DBX_IMPORT_010")
end)

test("Databricks expression rewriting qualifies columns and flags unknown paths", function()
    local diagnostics = {}
    local rewritten = api.dbx_rewrite_expr(
        "source.amount + customer.region + mystery.value + tax",
        {source = "o", customer = "c"}, "o", {['C.REGION'] = "customer_region"},
        diagnostics, "measure.test")
    assert_contains(rewritten, "o.amount")
    assert_contains(rewritten, "customer_region")
    assert_contains(rewritten, "mystery.value")
    assert_contains(rewritten, "o.tax")
    assert_equal(diagnostics[1].code, "DBX_IMPORT_310")
end)

test("normalized import model discovery deduplicates explicit operations", function()
    local names = api.model_names_from_plan({
        models = {{model_name = "sales"}, {model_name = "sales"}, {model_name = "finance"}},
        operations = {
            {operation = "create_model", arguments = {model_name = "marketing"}},
            {operation = "create_model", arguments = {model_name = "finance"}},
            {operation = "add_entity", arguments = {model_name = "ignored"}},
        },
    })
    assert_equal(#names, 3)
    assert_equal(names[1], "sales")
    assert_equal(names[2], "finance")
    assert_equal(names[3], "marketing")
end)

local function with_query(mock, fn)
    local original_query = query
    query = mock
    local ok, result = xpcall(fn, debug.traceback)
    query = original_query
    if not ok then error(result, 0) end
    return result
end

local metric_row = {
    MODEL_NAME = "sales", OBJECT_NAME = "SALES", METRIC_ID = 30,
    METRIC_NAME = "total_revenue", DISPLAY_NAME = "Total Revenue",
    METRIC_KIND = "SIMPLE", METRIC_TYPE = "ADDITIVE",
    BASE_ENTITY_NAME = "orders", FORMAT_HINT = "currency",
    IS_CERTIFIED = true, IS_PRIVATE = false, OWNER_ROLE = nil,
    DESCRIPTION = "Recognized revenue", SYNONYMS = "revenue,sales",
    EXPRESSION = "SUM(net_revenue)", SEMANTIC_FILTER_EXPR = nil,
    FILTER_EXPR = nil, DATA_TYPE = "DECIMAL(18,2)", DEFINITION_SOURCE_ID = 90,
}

test("semantic definition public dry-run and error results preserve catalog", function()
    local ddl = [[
        ALTER SEMANTIC VIEW sales.SALES
        ADD OR REPLACE METRIC total_revenue AS SUM(net_revenue)
          ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC
    ]]
    local dry = apply_semantic_definition(ddl, true)
    assert_equal(dry[1][1], "DRY_RUN")
    assert_equal(dry[1][5], 1)
    assert_contains(dry[1][4], '"total_revenue"')

    local malformed = apply_semantic_definition("ALTER SEMANTIC VIEW sales", false)
    assert_equal(malformed[1][1], "ERROR")
    assert_equal(malformed[1][2], "SEMANTIC_DDL_011")
end)

test("normalized OSI public API dispatches operations and reports failures", function()
    local calls = {}
    local applied = with_query(function(sql, params)
        calls[#calls + 1] = {sql = sql, params = params}
        if tostring(sql):find("CREATE_MODEL", 1, true) then return {{1}} end
        error("unexpected OSI query: " .. tostring(sql))
    end, function()
        return apply_normalized_osi_import(api.json_encode({
            operations = {{
                operation = "create_model",
                target = "SEMANTIC_ADMIN.CREATE_MODEL",
                source_path = "$.models[0]",
                arguments = {model_name = "osi_sales", published_schema = "SEMANTIC_OSI"},
            }},
        }), false, false)
    end)
    assert_equal(applied[1][1], "OK")
    assert_equal(applied[1][2], 0)
    assert_equal(applied[1][6], 1)
    assert_equal(applied[2][3], "validate_model")
    assert_equal(#calls, 1)

    local missing = apply_normalized_osi_import("{}", false, false)
    assert_equal(missing[1][1], "ERROR")
    assert_contains(missing[1][9], "SEMANTIC_OSI_001")
    local unsupported = apply_normalized_osi_import(api.json_encode({operations = {{
        operation = "unknown", target = "SEMANTIC_ADMIN.UNKNOWN", source_path = "$.x",
    }}}), false, false)
    assert_equal(unsupported[1][1], "ERROR")
    assert_equal(unsupported[1][2], 0)
    assert_contains(unsupported[1][9], "SEMANTIC_OSI_010")
end)

test("metric describe explain and export APIs expose governed metadata", function()
    local result = with_query(function(sql)
        local normalized = tostring(sql):gsub("%s+", " ")
        if normalized:find("FROM SEMANTIC_CATALOG.METRIC_OVERVIEW mo", 1, true)
            and normalized:find("JOIN SYS_SEMANTIC.METRICS", 1, true) then
            return {metric_row}
        elseif normalized:find("FROM SEMANTIC_CATALOG.METRIC_LINEAGE", 1, true) then
            return {{"MEASURE", "FACT", "net_revenue"},
                {"INPUT_METRIC", "METRIC", "base_revenue"}}
        elseif normalized:find("FROM SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS", 1, true) then
            return {{"customer_region"}, {"order_month"}}
        elseif normalized:find("SELECT STATUS FROM SYS_SEMANTIC.VALIDATION_RUNS", 1, true) then
            return {{"OK"}}
        end
        error("unexpected metric metadata query: " .. normalized)
    end, function()
        return {
            described = describe_semantic_metric("sales", "SALES", "total_revenue"),
            explained = explain_semantic_metric("sales", "SALES", "total_revenue"),
            exported = export_semantic_definition("sales", "SALES", "total_revenue"),
        }
    end)
    assert_equal(#result.described, 17)
    assert_equal(result.described[1][3], "sales")
    assert_equal(result.described[13][3], "PUBLIC")
    assert_equal(result.explained[4][2], "MEASURE:FACT")
    assert_equal(result.explained[#result.explained][3], "OK")
    assert_equal(result.exported[1][1], "METRIC")
    assert_contains(result.exported[1][3], "ADD OR REPLACE METRIC total_revenue")
    assert_contains(result.exported[1][3], "SYNONYMS ('revenue', 'sales')")
end)

test("semantic export supports object and full-model catalog shapes", function()
    local rows = with_query(function(sql)
        local normalized = tostring(sql):gsub("%s+", " ")
        if normalized:find("JOIN SYS_SEMANTIC.METRICS", 1, true) then
            return {metric_row}
        elseif normalized:find("FROM SYS_SEMANTIC.ENTITIES e", 1, true) then
            return {{ENTITY_NAME = "orders", SOURCE_SCHEMA = "MART",
                SOURCE_OBJECT = "ORDERS", SOURCE_ALIAS = "o",
                PRIMARY_KEY_EXPR = "order_id", GRAIN_DESCRIPTION = "one order",
                DESCRIPTION = "Orders"}}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIPS r", 1, true) then
            return {{RELATIONSHIP_NAME = "orders_customer", FROM_ENTITY_NAME = "orders",
                TO_ENTITY_NAME = "customers", JOIN_CONDITION = "o.customer_id = c.customer_id",
                RELATIONSHIP_CARDINALITY = "MANY_TO_ONE", JOIN_TYPE = "LEFT"}}
        elseif normalized:find("FROM SYS_SEMANTIC.FACTS f", 1, true) then
            return {{FACT_NAME = "net_revenue", ENTITY_NAME = "orders",
                EXPRESSION = "o.amount", DATA_TYPE = "DECIMAL(18,2)",
                ADDITIVE_POLICY = "ADDITIVE", DISPLAY_NAME = "Net Revenue",
                DESCRIPTION = "Revenue", IS_PRIVATE = false, IS_CERTIFIED = true}}
        elseif normalized:find("JOIN SYS_SEMANTIC.DIMENSIONS d", 1, true) then
            return {{OBJECT_NAME = "SALES", DIMENSION_NAME = "order_status",
                ENTITY_NAME = "orders", EXPRESSION = "o.status", DATA_TYPE = "VARCHAR(20)",
                DISPLAY_NAME = "Order Status", DESCRIPTION = "Status",
                FORMAT_HINT = nil, IS_CERTIFIED = true}}
        elseif normalized:find("SELECT OBJECT_NAME, METRIC_NAME", 1, true) then
            return {{OBJECT_NAME = "SALES", METRIC_NAME = "total_revenue"}}
        end
        error("unexpected export query: " .. normalized)
    end, function()
        return export_semantic_definition("sales", nil, nil)
    end)
    assert_equal(#rows, 5)
    assert_equal(rows[1][1], "ENTITY")
    assert_contains(rows[1][3], "ADD_ENTITY")
    assert_equal(rows[5][1], "METRIC")

    local dimensions = with_query(function(sql)
        if tostring(sql):find("JOIN SYS_SEMANTIC.DIMENSIONS", 1, true) then
            return {{DIMENSION_NAME = "order_status", ENTITY_NAME = "orders",
                EXPRESSION = "o.status", DATA_TYPE = "VARCHAR(20)",
                DISPLAY_NAME = "Order Status", DESCRIPTION = "Status",
                IS_CERTIFIED = true}}
        end
        if tostring(sql):find("SELECT METRIC_NAME", 1, true) then return {} end
        error("unexpected object export query")
    end, function()
        return export_semantic_definition("sales", "SALES", "DIMENSION")
    end)
    assert_equal(#dimensions, 1)
    assert_equal(dimensions[1][1], "DIMENSION")
end)

test("semantic preprocessor covers authoring discovery and explain commands", function()
    local commands = {
        {"SHOW SEMANTIC VIEWS", "OK", "SEMANTIC_CATALOG.SEMANTIC_OBJECTS"},
        {"SHOW SEMANTIC VIEW sales.SALES", "OK", "FIELDS_FOR_AGENT"},
        {"SHOW CERTIFIED SEMANTIC METRICS IN sales.SALES LIKE 'rev'", "OK", "IS_CERTIFIED = TRUE"},
        {"SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue", "OK", "IS_VALID = TRUE"},
        {"SHOW ALL SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue", "OK", "REASON_CODE"},
        {"DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue", "OK", "DESCRIBE_SEMANTIC_METRIC"},
        {"EXPLAIN SEMANTIC METRIC sales.SALES.total_revenue", "OK", "EXPLAIN_SEMANTIC_METRIC"},
        {"EXPORT SEMANTIC METRIC sales.SALES.total_revenue", "OK", "EXPORT_SEMANTIC_DEFINITION"},
        {"EXPORT SEMANTIC VIEW sales.SALES", "OK", "EXPORT_SEMANTIC_DEFINITION"},
        {"EXPORT SEMANTIC MODEL sales", "OK", "EXPORT_SEMANTIC_DEFINITION"},
        {"EXPLAIN SEMANTIC QUERY SELECT * FROM SEMANTIC_SALES.SALES", "OK", "COMPILE_SQL_DEBUG"},
    }
    for _, case in ipairs(commands) do
        local result = preprocess_sql(case[1])
        assert_equal(result.status, case[2])
        assert_contains(result.generated_sql, case[3])
    end
    local definition = preprocess_sql([[ALTER SEMANTIC VIEW sales.SALES
        ADD OR REPLACE METRIC revenue AS SUM(net_revenue)
        ON ENTITY orders RETURNS DECIMAL(18,2) ADDITIVE PUBLIC]])
    assert_equal(definition.status, "OK")
    assert_contains(definition.generated_sql, "APPLY_SEMANTIC_DEFINITION")
    local invalid = preprocess_sql("ALTER SEMANTIC VIEW sales")
    assert_equal(invalid.status, "ERROR")
    local unchanged = preprocess_sql("SELECT 1")
    assert_equal(unchanged.status, "UNCHANGED")

    local errors = {
        {"SHOW SEMANTIC VIEW sales", "SEMANTIC_DDL_067"},
        {"SHOW SEMANTIC METRICS", "SEMANTIC_DDL_060"},
        {"SHOW SEMANTIC DIMENSIONS FOR METRIC sales", "SEMANTIC_DDL_061"},
        {"DESCRIBE SEMANTIC METRIC sales", "SEMANTIC_DDL_062"},
        {"EXPLAIN SEMANTIC METRIC sales", "SEMANTIC_DDL_063"},
        {"EXPORT SEMANTIC METRIC sales", "SEMANTIC_DDL_064"},
        {"EXPORT SEMANTIC VIEW sales", "SEMANTIC_DDL_065"},
        {"EXPORT SEMANTIC MODEL", "SEMANTIC_DDL_066"},
    }
    for _, case in ipairs(errors) do
        local result = preprocess_sql(case[1])
        assert_equal(result.status, "ERROR")
        assert_equal(result.error_code, case[2])
    end
end)

test("Databricks public API returns dry-run plans and stable diagnostics", function()
    local yaml = read_text("tests/fixtures/databricks/orders_metric_view.yaml")
    local result = import_databricks_metric_view(yaml, "dbx_public", "semantic_dbx", false)
    assert_equal(result[1][1], "OK")
    assert_equal(result[1][4], "dbx_public")
    assert_contains(result[1][5], "CREATE_MODEL('dbx_public'")
    local missing = import_databricks_metric_view(yaml, nil, nil, false)
    assert_equal(missing[1][1], "ERROR")
    assert_equal(missing[1][2], "DBX_IMPORT_020")
end)
