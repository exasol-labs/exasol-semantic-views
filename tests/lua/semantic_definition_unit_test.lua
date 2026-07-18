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
