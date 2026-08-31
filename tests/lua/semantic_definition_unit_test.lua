local api = ESV_SEMANTIC_DEFINITION_TEST_API

local function with_query(mock, fn)
    local original_query = query
    query = mock
    local ok, result = xpcall(fn, debug.traceback)
    query = original_query
    if not ok then error(result, 0) end
    return result
end

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

test("semantic definition recognizes inline aggregate ratios", function()
    local numerator, denominator = api.inline_ratio_parts(
        "SUM(line_revenue) / NULLIF(SUM(line_units), 0)")
    assert_equal(numerator, "SUM(line_revenue)")
    assert_equal(denominator, "NULLIF(SUM(line_units), 0)")

    local invalid_numerator = api.inline_ratio_parts("line_revenue / SUM(line_units)")
    local invalid_denominator = api.inline_ratio_parts("SUM(line_revenue) / 10")
    assert_equal(invalid_numerator, nil)
    assert_equal(invalid_denominator, nil)
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

test("semantic definition parses single fact replacement", function()
    -- Facts are the primitive metrics compose from, so adding one must not
    -- require restating every fact in the object.
    local definition = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        ADD OR REPLACE FACT gross_line_amount
          ON ENTITY order_line
          AS ol.quantity * ol.net_unit_price
          RETURNS DECIMAL(18,2)
          ADDITIVE
          DISPLAY 'Gross Line Amount' COMMENT 'Line amount before discounts'
          PUBLIC CERTIFIED
    ]])
    assert_equal(#definition.facts, 1)
    assert_equal(#definition.metrics, 0)
    assert_equal(definition.facts[1].name, "gross_line_amount")
    assert_equal(definition.facts[1].entity, "order_line")
    assert_equal(definition.facts[1].expression, "ol.quantity * ol.net_unit_price")
    assert_equal(definition.facts[1].additive_policy, "ADDITIVE")
    assert_equal(definition.facts[1].description, "Line amount before discounts")
    assert_true(definition.facts[1].is_certified)
    assert_true(not definition.facts[1].is_private)
    -- replace_facts stays false: the object's other facts survive.
    assert_branch("definition.replace.facts", definition.replace_facts, false)
    assert_equal(api.definition_operation_count(definition), 1)
end)

test("semantic definition accepts a fact-only replacement block", function()
    -- SEMANTIC_DDL_012 used to list REPLACE FACTS as an accepted form and then
    -- reject it unless a metric change came with it.
    local definition = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        REPLACE FACTS (
          FACT net_revenue
            ON ENTITY order_line AS ol.quantity * ol.net_unit_price
            RETURNS DECIMAL(18,2) ADDITIVE PUBLIC
        )
    ]])
    assert_equal(#definition.facts, 1)
    assert_equal(#definition.metrics, 0)
    assert_branch("definition.replace.facts", definition.replace_facts, true)
end)

test("semantic definition parses dimensions in both forms", function()
    -- A dimension is a fact's shape with FORMAT instead of an additive policy,
    -- so it reuses the fact clauses and adds no keyword of its own.
    local single = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        ADD OR REPLACE DIMENSION freight_band
          ON ENTITY "order"
          AS CASE WHEN o.freight_amount > 20 THEN 'HIGH' ELSE 'LOW' END
          RETURNS VARCHAR(10)
          DISPLAY 'Freight Band' COMMENT 'Bucketed freight'
          FORMAT 'text'
          CERTIFIED
    ]])
    assert_equal(#single.dimensions, 1)
    assert_equal(#single.facts, 0)
    assert_equal(#single.metrics, 0)
    assert_equal(single.dimensions[1].kind, "DIMENSION")
    assert_equal(single.dimensions[1].name, "freight_band")
    assert_equal(single.dimensions[1].entity, "order")
    assert_equal(single.dimensions[1].data_type, "VARCHAR(10)")
    assert_equal(single.dimensions[1].display_name, "Freight Band")
    assert_equal(single.dimensions[1].description, "Bucketed freight")
    assert_equal(single.dimensions[1].format_hint, "text")
    assert_true(single.dimensions[1].is_certified)
    assert_true(not single.dimensions[1].is_hidden)
    -- The CASE expression contains no clause keyword at depth 0, so it survives.
    assert_equal(single.dimensions[1].expression,
        "CASE WHEN o.freight_amount > 20 THEN 'HIGH' ELSE 'LOW' END")
    -- Upserting one leaves the object's others alone.
    assert_branch("definition.replace.dimensions", single.replace_dimensions, false)
    assert_equal(api.definition_operation_count(single), 1)

    local block = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        REPLACE DIMENSIONS (
          DIMENSION ship_mode ON ENTITY "order" AS o.ship_mode RETURNS VARCHAR(20),
          DIMENSION order_status ON ENTITY "order" AS o.order_status RETURNS VARCHAR(20) PRIVATE
        )
    ]])
    assert_equal(#block.dimensions, 2)
    assert_branch("definition.replace.dimensions", block.replace_dimensions, true)
    assert_equal(block.dimensions[1].name, "ship_mode")
    assert_equal(block.dimensions[2].name, "order_status")
    -- PRIVATE maps to the catalog's IS_HIDDEN, which is what DIMENSIONS spells it.
    assert_true(not block.dimensions[1].is_hidden)
    assert_true(block.dimensions[2].is_hidden)
    assert_equal(api.definition_operation_count(block), 2)
end)

test("semantic definition carries dimensions and metrics in one statement", function()
    -- The block forms compose, which is the point of a set-level replace: one
    -- statement, one validation pass, one rollback unit.
    local definition = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        REPLACE DIMENSIONS (
          DIMENSION ship_mode ON ENTITY "order" AS o.ship_mode RETURNS VARCHAR(20)
        )
        REPLACE METRICS (
          METRIC total_revenue AS SUM(net_revenue) ON ENTITY order_line
            RETURNS DECIMAL(18,2) ADDITIVE PUBLIC
        )
    ]])
    assert_equal(#definition.dimensions, 1)
    assert_equal(#definition.metrics, 1)
    assert_branch("definition.replace.dimensions", definition.replace_dimensions, true)
    assert_equal(api.definition_operation_count(definition), 2)
end)

test("dimension upsert writes the catalog columns DIMENSIONS actually has", function()
    -- FORMAT_HINT rather than ADDITIVE_POLICY, IS_HIDDEN rather than IS_PRIVATE,
    -- and a *visible* object column because a dimension is something to group by.
    local insert_params, binding_params, column_params = nil, nil, nil
    with_query(function(sql, params)
        local text = tostring(sql)
        if text:find("SELECT ENTITY_ID", 1, true) then
            return {{20}}
        elseif text:find("INSERT INTO SYS_SEMANTIC.DIMENSIONS", 1, true) then
            insert_params = params
            return {}
        elseif text:find("SELECT DIMENSION_ID", 1, true) then
            return insert_params ~= nil and {{55}} or {}
        elseif text:find("SELECT REPRESENTATION_ID", 1, true) then
            return {{7}}
        elseif text:find("SELECT ATTRIBUTE_BINDING_ID", 1, true) then
            return {}
        elseif text:find("INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS", 1, true) then
            binding_params = binding_params or params
            return {}
        elseif text:find("SELECT COUNT(*)", 1, true)
                and text:find("SYS_SEMANTIC.OBJECT_COLUMNS", 1, true) then
            return {{0}}
        elseif text:find("COALESCE(MAX(ORDINAL_POSITION), 0)", 1, true) then
            return {{3}}
        elseif text:find("INSERT INTO SYS_SEMANTIC.OBJECT_COLUMNS", 1, true) then
            column_params = params
            return {}
        end
        return {}
    end, function()
        api.upsert_dimension({model_id = 1, version_id = 2}, 10, {
            kind = "DIMENSION", name = "freight_band", entity = "order",
            expression = "o.freight_amount", data_type = "VARCHAR(10)",
            display_name = "Freight Band", description = "Bucketed freight",
            format_hint = "text", is_hidden = false, is_certified = true,
        })
    end)
    assert_true(insert_params ~= nil)
    assert_equal(insert_params.dimension_name, "freight_band")
    assert_equal(insert_params.format_hint, "text")
    assert_equal(insert_params.is_hidden, false)
    assert_equal(insert_params.is_certified, true)
    -- A default binding on the primary representation, as facts get.
    assert_true(binding_params ~= nil)
    assert_equal(binding_params.representation_id, 7)
    assert_equal(binding_params.dimension_id, 55)
    -- Visible, unlike a fact.
    assert_true(column_params ~= nil)
    assert_equal(column_params.kind, "DIMENSION")
    assert_equal(column_params.is_visible, true)
    assert_equal(column_params.column_name, "freight_band")
end)

-- Answer the catalog-column lookup the shared rollback makes for every table it
-- captures, so a test drives the derivation rather than a hard-coded list.
local function catalog_columns(columns_by_table, handler)
    return function(sql, params)
        local text = tostring(sql)
        if text:find("FROM SYS.EXA_ALL_COLUMNS", 1, true) then
            local rows = {}
            for _, column in ipairs(columns_by_table[params.table_name]
                    or {"MODEL_ID", "VERSION_ID"}) do
                rows[#rows + 1] = {COLUMN_NAME = column}
            end
            return rows
        end
        return handler(text, params)
    end
end

test("apply rollback carries dimensions, or a dry run leaks one", function()
    -- The dry run and the failed-apply path both work by applying, validating,
    -- and restoring a snapshot. Until dimensions were authorable through the DDL
    -- the snapshot did not need to cover SYS_SEMANTIC.DIMENSIONS -- an apply
    -- never touched it. The moment it did, a dry run inserted a dimension the
    -- restore could not remove: the row survived, catalogued and visible, from a
    -- statement that reported committing nothing.
    local DIMENSION_COLUMNS = {"DIMENSION_ID", "MODEL_ID", "VERSION_ID",
        "DIMENSION_NAME", "FORMAT_HINT", "IS_HIDDEN", "STATUS"}
    local snapshot_tables, restore_inserts, cleared = {}, {}, {}
    with_query(catalog_columns({DIMENSIONS = DIMENSION_COLUMNS},
        function(text, params)
            local selected = text:match("FROM SYS_SEMANTIC%.([A-Z_]+)")
            if text:find("^SELECT") then
                if selected ~= nil then snapshot_tables[selected] = true end
                if selected == "DIMENSIONS" then
                    return {{55, 1, 2, "freight_band", "text", false, "ACTIVE"}}
                end
                return {}
            end
            local inserted = text:match("INSERT INTO SYS_SEMANTIC%.([A-Z_]+)")
            if inserted ~= nil then restore_inserts[inserted] = params end
            local deleted = text:match("DELETE FROM SYS_SEMANTIC%.([A-Z_]+)")
            if deleted ~= nil then cleared[deleted] = true end
            return {}
        end), function()
        local snapshot = api.snapshot_model_state({model_id = 1, version_id = 2})
        local dimensions = nil
        for _, entry in ipairs(snapshot) do
            if entry.name == "DIMENSIONS" then dimensions = entry end
        end
        assert_true(dimensions ~= nil, "DIMENSIONS was not captured")
        assert_equal(#dimensions.rows, 1)
        assert_equal(#dimensions.columns, #DIMENSION_COLUMNS)
        api.restore_model_state({model_id = 1, version_id = 2}, snapshot)
    end)
    -- Captured, cleared and put back -- all three, or the rollback is partial.
    assert_true(snapshot_tables.DIMENSIONS == true)
    assert_true(cleared.DIMENSIONS == true)
    assert_true(restore_inserts.DIMENSIONS ~= nil)
    assert_equal(restore_inserts.DIMENSIONS.c1, 55)
    assert_equal(restore_inserts.DIMENSIONS.c4, "freight_band")
    assert_equal(restore_inserts.DIMENSIONS.c5, "text")
    -- A boolean FALSE, which the old `row[name] or ...` read as absent and
    -- restored as NULL.
    assert_equal(restore_inserts.DIMENSIONS.c6, false)
    assert_equal(restore_inserts.DIMENSIONS.c7, "ACTIVE")
    -- Facts were already covered; the point is that both are now.
    assert_true(cleared.FACTS == true)
end)

test("semantic definition parses metric drop and rename", function()
    local dropped = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES DROP METRIC obsolete_revenue
    ]])
    assert_equal(dropped.operation, "DROP_METRIC")
    assert_equal(dropped.metric_name, "obsolete_revenue")
    assert_equal(api.definition_operation_count(dropped), 1)

    local renamed = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        RENAME METRIC total_revenue TO gross_merchandise_value
    ]])
    assert_equal(renamed.operation, "RENAME_METRIC")
    assert_equal(renamed.metric_name, "total_revenue")
    assert_equal(renamed.new_metric_name, "gross_merchandise_value")
    assert_equal(api.definition_operation_count(renamed), 1)
end)

test("metric rename rewrites identifiers without touching literals or partial names", function()
    local rewritten = api.rewrite_identifier(
        [[total_revenue / NULLIF(total_revenue_tax, 0) + "total_revenue" /* total_revenue */]],
        "total_revenue",
        "gross_merchandise_value")
    assert_contains(rewritten, "gross_merchandise_value / NULLIF(total_revenue_tax, 0)")
    assert_contains(rewritten, '"gross_merchandise_value"')
    assert_contains(rewritten, "/* total_revenue */")
end)

test("metric drop removes membership and deactivates the final membership", function()
    local deleted = false
    local deactivated = false
    with_query(function(sql)
        if tostring(sql):find("SELECT mt.METRIC_ID", 1, true) then
            return {{30}}
        elseif tostring(sql):find("DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS", 1, true) then
            deleted = true
            return {}
        elseif tostring(sql):find("SELECT COUNT(*)", 1, true) then
            return {{0}}
        elseif tostring(sql):find("SET STATUS = 'INACTIVE'", 1, true) then
            deactivated = true
            return {}
        end
        error("unexpected drop query: " .. tostring(sql))
    end, function()
        api.drop_metric({model_id = 1, version_id = 2}, 10, "obsolete_metric")
    end)
    assert_true(deleted)
    assert_true(deactivated)
end)

test("semantic DDL accepts a quoted identifier wherever it accepts a name", function()
    -- The demo model ships an entity named `order`, a reserved word. Quoted
    -- metric, fact, model, and object names already parsed, because the
    -- tokenizer decodes a quoted token; ON ENTITY read raw source text and
    -- refused the same form, so one statement disagreed with itself.
    local fact = api.parse_definition([[
        ALTER SEMANTIC VIEW "sales"."ORDER_HEADER"
        ADD OR REPLACE FACT "freight" ON ENTITY "order"
          AS o.freight_amount RETURNS DECIMAL(18,2) ADDITIVE PUBLIC
    ]])
    assert_equal(fact.model_name, "sales")
    assert_equal(fact.object_name, "ORDER_HEADER")
    assert_equal(fact.facts[1].name, "freight")
    assert_equal(fact.facts[1].entity, "order")

    local metric = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.ORDER_HEADER
        ADD OR REPLACE METRIC total_freight AS SUM(freight) ON ENTITY "order"
          RETURNS DECIMAL(18,2) ADDITIVE PUBLIC
    ]])
    assert_equal(metric.metrics[1].base_entity, "order")

    -- Unquoted names are unchanged, and a quoted name still has to be a valid
    -- identifier: quoting is not an escape hatch for arbitrary text.
    local plain = api.parse_definition([[
        ALTER SEMANTIC VIEW sales.SALES
        ADD OR REPLACE FACT quantity ON ENTITY order_line
          AS ol.quantity RETURNS DECIMAL(18,0) ADDITIVE PUBLIC
    ]])
    assert_equal(plain.facts[1].entity, "order_line")
    assert_error(function()
        api.parse_definition([[
            ALTER SEMANTIC VIEW sales.SALES
            ADD OR REPLACE FACT quantity ON ENTITY "order line"
              AS ol.quantity RETURNS DECIMAL(18,0) ADDITIVE PUBLIC
        ]])
    end, "SEMANTIC_DDL_002")
    -- The refusal quotes the name as written, not a half-decoded form.
    assert_error(function()
        api.parse_definition([[
            ALTER SEMANTIC VIEW sales.SALES
            ADD OR REPLACE FACT quantity ON ENTITY "order line"
              AS ol.quantity RETURNS DECIMAL(18,0) ADDITIVE PUBLIC
        ]])
    end, '"order line"')
end)

test("metric drop names which of the three states blocked it", function()
    -- "not found" reads as a contradiction while METRIC_OVERVIEW still lists
    -- the metric as an INACTIVE row. Each state gets its own sentence.
    local function drop_with(active_count, total_count, memberships)
        return with_query(function(sql)
            local text = tostring(sql)
            if text:find("SELECT mt.METRIC_ID", 1, true) then
                return {}
            elseif text:find("FROM SYS_SEMANTIC.SEMANTIC_OBJECTS", 1, true)
                and text:find("WHERE OBJECT_ID", 1, true) then
                return {{"SALES"}}
            elseif text:find("STATUS = 'ACTIVE'", 1, true)
                and text:find("SELECT COUNT(*)", 1, true) then
                return {{active_count}}
            elseif text:find("SELECT COUNT(*)", 1, true) then
                return {{total_count}}
            elseif text:find("JOIN SYS_SEMANTIC.SEMANTIC_OBJECTS", 1, true) then
                return memberships
            end
            error("unexpected diagnostic query: " .. text)
        end, function()
            api.drop_metric({model_id = 1, version_id = 2}, 10, "probe_metric")
        end)
    end

    -- Dropped already: the row the reader can see is explained.
    assert_error(function() drop_with(0, 1, {}) end, "was already dropped")
    assert_error(function() drop_with(0, 1, {}) end, "STATUS = 'INACTIVE'")

    -- Active, but a column of a different semantic view: name that view.
    assert_error(function() drop_with(1, 1, {{"ORDER_HEADER"}}) end,
        "it is exposed by: ORDER_HEADER")

    -- Active and in no object at all: the remedy is to add it first.
    assert_error(function() drop_with(1, 1, {}) end, "is not a column of")

    -- Genuinely absent: the original wording, now naming the view.
    assert_error(function() drop_with(0, 0, {}) end,
        "metric not found in semantic view SALES")
end)

test("metric rename preserves identity metadata and rewrites dependents", function()
    local updates = {}
    local synonym_inserted = false
    with_query(function(sql, params)
        local text = tostring(sql)
        if text:find("SELECT mt.METRIC_ID", 1, true) then
            return {{30}}
        elseif text:find("FROM SYS_SEMANTIC.METRICS", 1, true)
                and text:find("METRIC_ID <>", 1, true) then
            return {{0}}
        elseif text:find("FROM SYS_SEMANTIC.OBJECT_COLUMNS candidate", 1, true) then
            return {{0}}
        elseif text:find("SELECT METRIC_ID, EXPRESSION, MEASURE_EXPR", 1, true) then
            return {
                {30, "SUM(net_revenue)", "net_revenue"},
                {31, "total_revenue / NULLIF(order_count, 0)", "total_revenue"},
            }
        elseif text:find("UPDATE SYS_SEMANTIC.METRICS", 1, true)
                or text:find("UPDATE SYS_SEMANTIC.OBJECT_COLUMNS", 1, true)
                or text:find("UPDATE SYS_SEMANTIC.METRIC_INPUTS", 1, true) then
            updates[#updates + 1] = params
            return {}
        elseif text:find("DELETE FROM SYS_SEMANTIC.SYNONYMS", 1, true) then
            return {}
        elseif text:find("SELECT COUNT(*)", 1, true)
                and text:find("FROM SYS_SEMANTIC.SYNONYMS", 1, true) then
            return {{0}}
        elseif text:find("INSERT INTO SYS_SEMANTIC.SYNONYMS", 1, true) then
            synonym_inserted = params.old_name == "total_revenue"
            return {}
        end
        error("unexpected rename query: " .. text)
    end, function()
        api.rename_metric(
            {model_id = 1, version_id = 2}, 10,
            "total_revenue", "gross_merchandise_value")
    end)
    assert_equal(updates[1].metric_id, 31)
    assert_contains(updates[1].expression, "gross_merchandise_value")
    assert_contains(updates[1].measure_expr, "gross_merchandise_value")
    assert_true(synonym_inserted)
end)

test("replacement synonyms are claimed before metric upserts", function()
    local deleted = {}
    with_query(function(sql, params)
        assert_contains(sql, "DELETE FROM SYS_SEMANTIC.SYNONYMS")
        deleted[#deleted + 1] = params.synonym
        return {}
    end, function()
        api.prepare_replacement_synonyms(
            {model_id = 1, version_id = 2},
            {
                {synonyms = {"revenue", "sales"}},
                {synonyms = {"Revenue", "turnover"}},
            })
    end)
    assert_equal(#deleted, 3)
    assert_equal(deleted[1], "REVENUE")
    assert_equal(deleted[2], "SALES")
    assert_equal(deleted[3], "TURNOVER")
end)

test("validation failure message identifies rule and object", function()
    local message = api.validation_error_message({{
        SEVERITY = "ERROR",
        OBJECT_TYPE = "SYNONYM",
        OBJECT_NAME = "REVENUE",
        RULE_CODE = "SEMANTIC_MODEL_021",
        MESSAGE = "Certified synonym is ambiguous across multiple semantic objects.",
    }})
    assert_contains(message, "SEMANTIC_MODEL_021")
    assert_contains(message, "[SYNONYM REVENUE]")
    assert_contains(message, "Certified synonym is ambiguous")
end)

test("metric dry-run binds a null definition source", function()
    local metric_update = nil
    with_query(function(sql, params)
        local text = tostring(sql)
        if text:find("SELECT ENTITY_ID", 1, true) then
            return {{20}}
        elseif text:find("SELECT METRIC_ID", 1, true)
                and text:find("UPPER(METRIC_NAME)", 1, true) then
            return {{30}}
        elseif text:find("UPDATE SYS_SEMANTIC.METRICS", 1, true) then
            metric_update = params
            return {}
        elseif text:find("SELECT COUNT(*)", 1, true)
                and text:find("SYS_SEMANTIC.OBJECT_COLUMNS", 1, true) then
            return {{1}}
        elseif text:find("SELECT FACT_ID", 1, true) then
            return {{40}}
        elseif text:find("SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS", 1, true) then
            return {}
        end
        return {}
    end, function()
        api.upsert_metric(
            {model_id = 1, version_id = 2},
            10,
            {
                name = "total_revenue",
                expression = "SUM(net_revenue)",
                metric_type = "SIMPLE",
                metric_kind = "SIMPLE",
                aggregation_function = "SUM",
                measure_expr = "net_revenue",
                base_entity = "order_line",
                data_type = "DECIMAL(18,2)",
                is_private = false,
                is_certified = true,
                synonyms = {},
            },
            nil)
    end)
    assert_true(metric_update ~= nil)
    assert_equal(metric_update.definition_source_id, null)
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
        {"ALTER SEMANTIC VIEW sales.SALES DROP METRIC", "SEMANTIC_DDL_035"},
        {"ALTER SEMANTIC VIEW sales.SALES DROP METRIC x y", "SEMANTIC_DDL_035"},
        {"ALTER SEMANTIC VIEW sales.SALES RENAME METRIC x y", "SEMANTIC_DDL_036"},
        {"ALTER SEMANTIC VIEW sales.SALES RENAME METRIC x TO X", "SEMANTIC_DDL_083"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE METRIC x ON ENTITY e RETURNS INT", "SEMANTIC_DDL_031"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE METRIC x AS SUM(f) ON ENTITY e", "SEMANTIC_DDL_032"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE FACT x ON ENTITY e RETURNS INT", "SEMANTIC_DDL_021"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE FACT x ON ENTITY e AS f", "SEMANTIC_DDL_022"},
        -- The single-fact form takes the rest of the statement, so it cannot
        -- share one with another change.
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE FACT x ON ENTITY e AS f RETURNS INT"
            .. " ADD OR REPLACE METRIC m AS SUM(x) ON ENTITY e RETURNS INT", "SEMANTIC_DDL_037"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE FACT x ON ENTITY e AS f RETURNS INT"
            .. " REPLACE METRICS (METRIC m AS SUM(x) ON ENTITY e RETURNS INT)", "SEMANTIC_DDL_037"},
        -- Dimensions mirror facts, including the refusals.
        {"ALTER SEMANTIC VIEW sales.SALES REPLACE DIMENSIONS (FACT x ON ENTITY e AS f RETURNS INT)",
            "SEMANTIC_DDL_025"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION d ON ENTITY e RETURNS INT",
            "SEMANTIC_DDL_026"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION d ON ENTITY e AS f",
            "SEMANTIC_DDL_027"},
        {"ALTER SEMANTIC VIEW sales.SALES REPLACE DIMENSIONS DIMENSION d", "SEMANTIC_DDL_028"},
        {"ALTER SEMANTIC VIEW sales.SALES REPLACE DIMENSIONS (DIMENSION d", "SEMANTIC_DDL_029"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION d ON ENTITY e AS f RETURNS INT"
            .. " REPLACE METRICS (METRIC m AS SUM(x) ON ENTITY e RETURNS INT)", "SEMANTIC_DDL_038"},
        {"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE FACT x ON ENTITY e AS f RETURNS INT"
            .. " ADD OR REPLACE DIMENSION d ON ENTITY e AS g RETURNS INT", "SEMANTIC_DDL_037"},
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
    local function dry_run_with(validation_issues)
        local validation_calls = 0
        return with_query(function(sql)
            local text = tostring(sql)
            if text:find("FROM SYS.EXA_ALL_COLUMNS", 1, true) then
                -- The rollback snapshot derives its column lists from the
                -- catalog, so a dry run reaches this before it applies anything.
                return {{COLUMN_NAME = "MODEL_ID"}, {COLUMN_NAME = "VERSION_ID"}}
            elseif text:find("SELECT MODEL_ID, ACTIVE_VERSION_ID", 1, true) then
                return {{1, 2}}
            elseif text:find("SELECT OBJECT_ID", 1, true)
                    and text:find("SEMANTIC_OBJECTS", 1, true) then
                return {{10}}
            elseif text:find("SELECT mt.METRIC_ID", 1, true) then
                return {{30}}
            elseif text:find("SELECT COUNT(*)", 1, true) then
                return {{0}}
            elseif text:find("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", 1, true) then
                validation_calls = validation_calls + 1
                if validation_calls == 1 then return validation_issues end
                return {}
            elseif text:find("SELECT MAX(VALIDATION_RUN_ID)", 1, true) then
                return {{77}}
            elseif text:find("INSERT INTO SYS_SEMANTIC.SEMANTIC_DEFINITION_SOURCES", 1, true) then
                error("dry-run must not insert a definition source")
            elseif text:find("SELECT ", 1, true) then
                return {}
            end
            return {}
        end, function()
            return apply_semantic_definition(
                "ALTER SEMANTIC VIEW sales.SALES DROP METRIC total_revenue", true)
        end)
    end

    local dry = dry_run_with({})
    assert_equal(dry[1][1], "DRY_RUN")
    assert_equal(dry[1][5], 1)
    assert_equal(dry[1][6], 77)
    assert_contains(dry[1][3], "parsed and validated")
    assert_contains(dry[1][3], "no catalog changes")

    local invalid = dry_run_with({{
        SEVERITY = "ERROR",
        OBJECT_TYPE = "METRIC",
        OBJECT_NAME = "gross_margin",
        RULE_CODE = "SEMANTIC_MODEL_011",
        MESSAGE = "Metric expression references unknown fact or metric: total_revenue.",
    }})
    assert_equal(invalid[1][1], "ERROR")
    assert_equal(invalid[1][2], "SEMANTIC_DDL_090")
    assert_contains(invalid[1][3], "SEMANTIC_MODEL_011 [METRIC gross_margin]")
    assert_contains(invalid[1][3], "No catalog changes were committed")

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

test("normalized OSI import dispatches structured relationship mappings", function()
    local call = nil
    local applied = with_query(function(sql, params)
        call = {sql = sql, params = params}
        if tostring(sql):find("ADD_RELATIONSHIP_KEY_MAPPING", 1, true) then
            return {}
        end
        error("unexpected relationship mapping query: " .. tostring(sql))
    end, function()
        return apply_normalized_osi_import(api.json_encode({
            operations = {{
                operation = "add_relationship_key_mapping",
                target = "SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING",
                source_path = "$.relationships[0].from_columns[0]",
                arguments = {
                    model_name = "sales",
                    relationship_name = "orders_customer",
                    from_column_name = "customer_id",
                    to_column_name = "customer_id",
                    ordinal_position = 1,
                },
            }},
        }), false, false)
    end)
    assert_equal(applied[1][1], "OK")
    assert_contains(call.sql, "ADD_RELATIONSHIP_KEY_MAPPING")
    assert_equal(call.params.ordinal_position, 1)
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
                RELATIONSHIP_CARDINALITY = "MANY_TO_ONE", JOIN_TYPE = "LEFT",
                RELATIONSHIP_ID = 70}}
        elseif normalized:find("FROM SYS_SEMANTIC.RELATIONSHIP_KEY_MAPPINGS", 1, true) then
            return {{ORDINAL_POSITION = 1, FROM_COLUMN_NAME = "customer_id",
                TO_COLUMN_NAME = "customer_id"}}
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
    assert_contains(rows[2][3], "ADD_RELATIONSHIP_KEY_MAPPING")
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
    assert_contains(definition.generated_sql, "APPLY_SEMANTIC_DEFINITION_OR_FAIL")
    local dropped = preprocess_sql("ALTER SEMANTIC VIEW sales.SALES DROP METRIC old_revenue")
    assert_equal(dropped.status, "OK")
    assert_contains(dropped.generated_sql, "APPLY_SEMANTIC_DEFINITION_OR_FAIL")
    local renamed = preprocess_sql(
        "ALTER SEMANTIC VIEW sales.SALES RENAME METRIC revenue TO net_revenue")
    assert_equal(renamed.status, "OK")
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

-- The DDL apply path used to roll back by hand: 335 lines that wrote every
-- column out four times per table, with nothing checking that the four agreed.
-- It now uses shared/catalog_rollback.lua, which admin/fusion_declaration.lua
-- already used, so the column lists come from the catalog. These two tests are
-- what makes that claim checkable: what the catalog reports is what gets
-- captured, cleared and put back, byte for byte.
test("DDL rollback captures, clears and restores every table it declares", function()
    local COLUMNS = {"A_ID", "MODEL_ID", "VERSION_ID", "A_FLAG", "A_TEXT"}
    local asked, selected, deleted, inserted = {}, {}, {}, {}
    with_query(catalog_columns(setmetatable({}, {__index = function()
        return COLUMNS
    end}), function(text, params)
        local from = text:match("FROM SYS_SEMANTIC%.([A-Z_]+)")
        if text:find("^SELECT") then
            selected[#selected + 1] = from
            -- One row whose values are recognisable per column, including a
            -- boolean false: `row[name] or ...` read that as absent and
            -- restored it as NULL.
            return {{101, 1, 2, false, from .. ":text"}}
        end
        local target = text:match("DELETE FROM SYS_SEMANTIC%.([A-Z_]+)")
        if target ~= nil then deleted[#deleted + 1] = target return {} end
        target = text:match("INSERT INTO SYS_SEMANTIC%.([A-Z_]+)")
        if target ~= nil then inserted[#inserted + 1] = {name = target,
            sql = text, params = params} end
        return {}
    end), function()
        local model = {model_id = 1, version_id = 2}
        local snapshot = api.snapshot_model_state(model)
        api.restore_model_state(model, snapshot)
        for _, entry in ipairs(snapshot) do asked[#asked + 1] = entry.name end
    end)

    -- Whatever the table list declares is captured, and each entry carries the
    -- catalog's columns rather than a list written here.
    assert_true(#asked >= 10, "fewer tables captured than declared: " .. #asked)
    assert_equal(selected[1], asked[1])
    assert_equal(#selected, #asked)

    -- Deleted in reverse and inserted forward, from one declaration order, so a
    -- child never outlives its parent and a parent is never inserted after one.
    assert_equal(deleted[1], asked[#asked])
    assert_equal(deleted[#deleted], asked[1])
    assert_equal(#deleted, #asked)

    -- Every captured row is written back with every column and the values it
    -- was read with.
    assert_equal(#inserted, #asked)
    for index, write in ipairs(inserted) do
        assert_equal(write.name, asked[index])
        for _, column in ipairs(COLUMNS) do
            assert_contains(write.sql, column, write.name)
        end
        assert_equal(write.params.c1, 101, write.name)
        assert_equal(write.params.c4, false, write.name .. " lost a FALSE")
        assert_equal(write.params.c5, write.name .. ":text", write.name)
    end

    -- The two tables the hand-written version cleared and never restored.
    local captured = {}
    for _, name in ipairs(asked) do captured[name] = true end
    assert_true(captured.METRIC_DEPENDENCIES == true)
    assert_true(captured.METRIC_DIMENSION_MATRIX == true)
end)

test("DDL rollback refuses a table whose columns it cannot read", function()
    -- Deriving from an empty answer would capture nothing, restore nothing, and
    -- report success -- the failure mode the derivation exists to avoid.
    assert_error(function()
        with_query(function(sql)
            if tostring(sql):find("FROM SYS.EXA_ALL_COLUMNS", 1, true) then
                return {}
            end
            return {}
        end, function()
            api.snapshot_model_state({model_id = 1, version_id = 2})
        end)
    end, "SEMANTIC_DDL_091")
end)

test("normalized OSI import dispatches every target with its own arguments", function()
    -- batch_call is the third place an admin script's parameter list is written
    -- down -- after the script itself and SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS,
    -- which is derived from it. A mistyped binding here is invisible: Exasol
    -- checks arity, not names, so a `:desciption` placeholder bound from a
    -- `description` key would simply arrive as NULL and the row would be
    -- imported with a field missing.
    --
    -- This drives all thirteen and requires every placeholder in the rendered
    -- statement to be bound, and every binding to reach a placeholder.
    local targets = {
        "CREATE_MODEL", "ADD_ENTITY", "ADD_SEMANTIC_OBJECT", "ADD_RELATIONSHIP",
        "ADD_RELATIONSHIP_KEY_MAPPING", "ADD_DIMENSION", "ADD_FACT", "ADD_METRIC",
        "ADD_CUSTOM_EXTENSION", "ADD_UNIQUE_KEY", "ADD_UNIQUE_KEY_COLUMN",
        "ADD_SYNONYM", "ADD_AGENT_INSTRUCTION",
    }
    for _, name in ipairs(targets) do
        local statement, bound = nil, nil
        with_query(function(sql, params)
            statement, bound = tostring(sql), params or {}
            return {}
        end, function()
            -- Every argument set to its own name, so a binding that reaches the
            -- wrong placeholder is visible in the value rather than only absent.
            local args = setmetatable({}, {__index = function(_, key)
                return "value:" .. tostring(key)
            end})
            api.batch_call("SEMANTIC_ADMIN." .. name, args)
        end)
        assert_true(statement ~= nil, name .. " dispatched nothing")
        assert_contains(statement, "EXECUTE SCRIPT SEMANTIC_ADMIN." .. name .. "(")

        local placeholders = {}
        for placeholder in string.gmatch(statement, ":([%w_]+)") do
            placeholders[#placeholders + 1] = placeholder
        end
        assert_true(#placeholders > 0, name .. " renders no placeholders")
        for _, placeholder in ipairs(placeholders) do
            assert_equal(bound[placeholder], "value:" .. placeholder,
                name .. " binds " .. placeholder .. " from the wrong key")
        end
        local placeholder_set = {}
        for _, placeholder in ipairs(placeholders) do
            placeholder_set[placeholder] = true
        end
        for key, _ in pairs(bound) do
            assert_true(placeholder_set[key] == true,
                name .. " binds " .. key .. ", which the statement never names")
        end
    end
end)

test("normalized OSI import refuses a target it cannot dispatch", function()
    -- An unknown target has to be named rather than silently skipped: the import
    -- plan is built host-side, so a plan referring to a script this runtime does
    -- not know is a version mismatch between the two halves.
    assert_error(function()
        api.batch_call("SEMANTIC_ADMIN.ADD_SOMETHING_NEW", {})
    end, "SEMANTIC_OSI_010")

    -- An absent argument set is NULL for every parameter, not a crash: this is
    -- the SQL-NULL-is-userdata trap's neighbourhood, and `batch_arg` is the
    -- guard.
    local bound = nil
    with_query(function(sql, params) bound = params return {} end, function()
        api.batch_call("SEMANTIC_ADMIN.CREATE_MODEL", nil)
    end)
    assert_equal(bound.model_name, null)
    assert_equal(bound.owner_role, null)
end)

test("metric metadata surfaces a filter, an owner and a private metric", function()
    -- The governed fields the agent contract exposes, on a metric that actually
    -- has them. The fixture above leaves SEMANTIC_FILTER_EXPR, FILTER_EXPR and
    -- OWNER_ROLE nil, so describe / explain / export were only ever exercised on
    -- the branch where each is absent -- and a filtered metric is the shape the
    -- FILTER (WHERE ...) clause exists for.
    local filtered = {}
    for key, value in pairs(metric_row) do filtered[key] = value end
    filtered.METRIC_NAME = "completed_revenue"
    filtered.METRIC_KIND = "FILTERED"
    filtered.SEMANTIC_FILTER_EXPR = "order_status = 'COMPLETE'"
    filtered.FILTER_EXPR = "o.order_status = 'COMPLETE'"
    filtered.OWNER_ROLE = "REVENUE_OPS"
    filtered.IS_PRIVATE = true
    filtered.SYNONYMS = nil

    local result = with_query(function(sql)
        local normalized = tostring(sql):gsub("%s+", " ")
        if normalized:find("JOIN SYS_SEMANTIC.METRICS", 1, true) then
            return {filtered}
        elseif normalized:find("FROM SEMANTIC_CATALOG.METRIC_LINEAGE", 1, true) then
            return {{"MEASURE", "FACT", "net_revenue"}}
        elseif normalized:find("FROM SEMANTIC_CATALOG.METRIC_COMPATIBLE_DIMENSIONS", 1, true) then
            return {{"customer_region"}}
        elseif normalized:find("SELECT STATUS FROM SYS_SEMANTIC.VALIDATION_RUNS", 1, true) then
            return {{"STALE"}}
        end
        error("unexpected metric metadata query: " .. normalized)
    end, function()
        return {
            described = describe_semantic_metric("sales", "SALES", "completed_revenue"),
            explained = explain_semantic_metric("sales", "SALES", "completed_revenue"),
            exported = export_semantic_definition("sales", "SALES", "completed_revenue"),
        }
    end)

    local described = {}
    for _, row in ipairs(result.described) do
        described[tostring(row[2])] = tostring(row[3])
    end
    assert_equal(described.semantic_filter, "order_status = 'COMPLETE'")
    assert_equal(described.sql_filter, "o.order_status = 'COMPLETE'")
    assert_equal(described.owner_role, "REVENUE_OPS")
    assert_equal(described.metric_kind, "FILTERED")
    -- A private metric is reported as private, which is the whole point of the
    -- field: an agent must not offer it.
    assert_equal(described.visibility, "PRIVATE")

    -- A stale validation run is reported as stale rather than as OK: the metric
    -- is describable and not currently trustworthy, and those are different
    -- answers for an agent deciding whether to use it.
    assert_equal(result.explained[#result.explained][3], "STALE")

    -- The exported DDL is re-runnable, so the filter has to survive the round
    -- trip into FILTER (WHERE ...) rather than being described and dropped.
    local ddl = result.exported[1][3]
    assert_contains(ddl, "ADD OR REPLACE METRIC completed_revenue")
    assert_contains(ddl, "FILTER (WHERE order_status = 'COMPLETE')")
end)
