local adoption = ESV_VIEW_ADOPTION

local function read_text(path)
    local file = assert(io.open(path, "r"))
    local value = file:read("*a")
    file:close()
    return value
end

local function refused(fn, code, says)
    local ok, err = pcall(fn)
    assert_true(not ok, "expected a refusal containing " .. tostring(says))
    assert_contains(tostring(err), code)
    if says ~= nil then assert_contains(tostring(err), says) end
end

-- The ORDERS table the fixtures read: DBT_ADOPT_FIXTURES.ORDERS.
local function orders_scope(alias, view_alias)
    local scope = {
        alias = alias or "o", schema = "DBT_ADOPT_FIXTURES", object = "ORDERS",
        qualifiers = {ORDERS = true}, existing_descriptions = {},
        columns = {
            ORDER_ID = {name = "ORDER_ID", type = "DECIMAL(18,0)"},
            SHIP_MODE = {name = "SHIP_MODE", type = "VARCHAR(2000000) UTF8",
                         comment = "Mode of transport"},
            ORDER_STATUS = {name = "ORDER_STATUS", type = "VARCHAR(2000000) UTF8"},
            FREIGHT_AMOUNT = {name = "FREIGHT_AMOUNT", type = "DECIMAL(18,2)"},
            FORMAT = {name = "FORMAT", type = "VARCHAR(10)"},
        },
    }
    if view_alias ~= nil then scope.qualifiers[view_alias] = true end
    return scope
end

local CLAUSE_WORDS = {ON = true, AS = true, FILTER = true, RETURNS = true, FORMAT = true,
    UNIT = true, DISPLAY = true, COMMENT = true}

test("adoption takes the query out of what Exasol stores for a dbt view", function()
    each({
        {file = "dbt_shipping.sql", starts = "select\n", ends = "o.order_status"},
        {file = "dbt_bare.sql", starts = "select ship_mode", ends = "group by 1"},
        {file = "dbt_quoted.sql", starts = 'SELECT "SHIP_MODE"', ends = 'GROUP BY "SHIP_MODE"'},
    }, function(case)
        local query = adoption.extract_query(read_text("tests/fixtures/adopt_view/" .. case.file))
        assert_equal(query:sub(1, #case.starts), case.starts, case.file)
        assert_equal(query:sub(-#case.ends), case.ends, case.file)
    end)
end)

test("adoption reads hand-written view DDL too", function()
    each({
        {"CREATE VIEW s.v AS SELECT a FROM s.t", "SELECT a FROM s.t"},
        {"create or replace force view v as ((select a from s.t))", "select a from s.t"},
        {"CREATE VIEW s.v (a COMMENT IS 'x') AS SELECT a FROM s.t COMMENT IS 'v'",
         "SELECT a FROM s.t"},
        -- A parenthesised start is not a wrapper unless it closes at the end.
        {"CREATE VIEW v AS (SELECT 1) UNION ALL (SELECT 2)", "(SELECT 1) UNION ALL (SELECT 2)"},
    }, function(case)
        assert_equal(adoption.extract_query(case[1]), case[2])
    end)
    refused(function() adoption.extract_query("SELECT 1") end, "SEMANTIC_ADMIN_229",
        "not a CREATE VIEW")
    refused(function() adoption.extract_query("CREATE TABLE t AS SELECT 1") end,
        "SEMANTIC_ADMIN_229", "not a CREATE VIEW")
end)

test("adoption parses the one shape it adopts", function()
    local parsed = adoption.parse_select("select o.a, sum(o.b) as total"
        .. " from DBT_x.orders o group by o.a")
    assert_equal(#parsed.items, 2)
    assert_equal(parsed.items[2], "sum(o.b) as total")
    assert_equal(parsed.relation.schema, "DBT_X")
    assert_equal(parsed.relation.object, "ORDERS")
    assert_equal(parsed.alias.name, "O")
    assert_equal(parsed.group_by[1], "o.a")

    parsed = adoption.parse_select('SELECT x, COUNT(*) FROM "Mart"."Orders" AS "Ord"'
        .. " GROUP BY 1")
    assert_equal(parsed.relation.schema, "Mart")
    assert_equal(parsed.relation.object, "Orders")
    assert_true(parsed.alias.quoted)
    assert_equal(parsed.group_by[1], "1")

    parsed = adoption.parse_select("SELECT SUM(x) FROM s.t")
    assert_equal(parsed.alias, nil)
    assert_equal(#parsed.group_by, 0)
    -- A FROM inside a function call is not the query's.
    parsed = adoption.parse_select("SELECT EXTRACT(YEAR FROM d) y, SUM(x) FROM s.t GROUP BY 1")
    assert_equal(#parsed.items, 2)
end)

test("adoption refuses every other shape, naming it", function()
    each({
        {"SELECT a, SUM(b) FROM s.t WHERE a > 1 GROUP BY a", "a WHERE clause"},
        {"SELECT a, SUM(b) FROM s.t GROUP BY a HAVING SUM(b) > 1", "a HAVING clause"},
        {"SELECT a, SUM(b) FROM s.t x JOIN s.u y ON x.k = y.k GROUP BY a", "a join"},
        {"SELECT a, SUM(b) FROM s.t x LEFT JOIN s.u y ON x.k = y.k GROUP BY a", "a join"},
        {"SELECT a, SUM(b) FROM s.t x, s.u y GROUP BY a", "a join (a second table"},
        {"SELECT a FROM s.t UNION SELECT a FROM s.u", "a set operation (UNION)"},
        {"SELECT DISTINCT a FROM s.t", "SELECT DISTINCT"},
        {"SELECT a, SUM(b) FROM (SELECT * FROM s.t) GROUP BY a", "a subquery in FROM"},
        {"WITH c AS (SELECT 1) SELECT * FROM c", "a WITH clause"},
        {"SELECT a, SUM(b) FROM t GROUP BY a", "without its schema"},
        {"SELECT a, SUM(b) FROM s.t GROUP BY a ORDER BY a", "an ORDER BY"},
        {"SELECT a, SUM(b) FROM s.t GROUP BY ROLLUP (a)", "GROUP BY ROLLUP"},
        {"SELECT a, SUM(b) FROM s.t LIMIT 5", "a LIMIT"},
        {"SELECT a FROM s.t x y", "'y' after its FROM table"},
        {"VALUES (1)", "not a SELECT"},
        {"SELECT 1", "no FROM clause"},
    }, function(case)
        refused(function() adoption.parse_select(case[1]) end, "SEMANTIC_ADMIN_229", case[2])
    end)
end)

test("adoption drops a select item's alias and keeps its expression", function()
    each({
        {"sum(o.b) as total", "sum(o.b)"},
        {"sum(o.b) total", "sum(o.b)"},
        {'"SHIP_MODE" AS "Ship Mode"', '"SHIP_MODE"'},
        {"o.ship_mode", "o.ship_mode"},
        {"ship_mode", "ship_mode"},
        {"CASE WHEN a = 1 THEN 'x' ELSE 'y' END", "CASE WHEN a = 1 THEN 'x' ELSE 'y' END"},
        {"CASE WHEN a = 1 THEN 'x' END kind", "CASE WHEN a = 1 THEN 'x' END"},
        {"CAST(a AS INT)", "CAST(a AS INT)"},
        {"d + INTERVAL '1' DAY", "d + INTERVAL '1' DAY"},
        {"COUNT(*) n_orders", "COUNT(*)"},
    }, function(case)
        assert_equal(adoption.item_expression(case[1]), case[2])
    end)
end)

test("adoption finds the aggregate calls of an item", function()
    local calls = adoption.aggregate_calls("SUM(o.a) / NULLIF(COUNT(DISTINCT o.b), 0)")
    assert_equal(#calls, 2)
    assert_equal(calls[1].name, "SUM")
    assert_equal(calls[1].argument, "o.a")
    assert_true(calls[2].distinct)
    assert_equal(calls[2].argument, "o.b")
    calls = adoption.aggregate_calls("count(*)")
    assert_true(calls[1].star)
    assert_equal(calls[1].written, "count")
    assert_equal(#adoption.aggregate_calls("UPPER(o.a)"), 0)
    -- Multiplication is not SELECT *.
    assert_equal(#adoption.aggregate_calls("SUM(o.a * 2)"), 1)

    each({
        {"*", "SELECT *"},
        {"o.*", "SELECT *"},
        {"SUM(a) OVER (PARTITION BY b)", "a window function"},
        {"MEDIAN(a)", "the aggregate MEDIAN"},
        {"SUM(MAX(a))", "a nested aggregate"},
        {"COUNT(DISTINCT a, b)", "more than one argument"},
    }, function(case)
        refused(function() adoption.aggregate_calls(case[1]) end, "SEMANTIC_ADMIN_229", case[2])
    end)
end)

test("adoption qualifies every source column with the entity alias", function()
    local scope = orders_scope("ord", "O")
    each({
        {"ship_mode", "ord.ship_mode"},
        {"o.ship_mode", "ord.ship_mode"},
        {"orders.ship_mode", "ord.ship_mode"},
        {"DBT_adopt_fixtures.orders.ship_mode", "ord.ship_mode"},
        {'"SHIP_MODE"', 'ord."SHIP_MODE"'},
        {"UPPER(ship_mode) || '-' || order_status", "UPPER(ord.ship_mode) || '-' || ord.order_status"},
        -- Not columns: a literal, a quoted name of another case, a function,
        -- a type after AS, an unknown qualifier.
        {"'ship_mode'", "'ship_mode'"},
        {'"ship_mode"', '"ship_mode"'},
        {"CAST(freight_amount AS FORMAT)", "CAST(ord.freight_amount AS FORMAT)"},
        {"x.ship_mode", "x.ship_mode"},
        {"unknown_column + 1", "unknown_column + 1"},
    }, function(case)
        assert_equal((adoption.qualify(case[1], scope)), case[2])
    end)
end)

local function shipping_view(columns)
    return {object_name = "SHIPPING", columns = columns}
end

test("adoption translates the documented dbt view", function()
    local select = adoption.parse_select(adoption.extract_query(
        read_text("tests/fixtures/adopt_view/dbt_shipping.sql")))
    local view = shipping_view({
        {name = "SHIP_MODE", type = "VARCHAR(2000000) UTF8", comment = "How the order shipped"},
        {name = "ORDER_STATUS", type = "VARCHAR(2000000) UTF8", comment = ""},
        {name = "FREIGHT", type = "DECIMAL(29,2)", comment = "Total freight, in EUR"},
        {name = "ORDER_COUNT", type = "DECIMAL(18,0)", comment = "Distinct orders"},
    })
    local scope = orders_scope("o", "O")
    scope.existing_descriptions = {ORDER_STATUS = "Where the order is"}
    local plan = adoption.translate(view, select, scope, CLAUSE_WORDS)
    assert_equal(#plan.dimensions, 2)
    assert_equal(plan.dimensions[1].description, "How the order shipped")
    -- No comment of its own: the shared dimension's description is kept.
    assert_equal(plan.dimensions[2].description, "Where the order is")
    assert_equal(plan.facts[1].name, "shipping__freight_1")
    assert_equal(plan.facts[1].data_type, "DECIMAL(18,2)")
    assert_equal(plan.metrics[2].expression, "count(DISTINCT shipping__order_count_1)")

    local ddl = adoption.render_alter("logistics", "SHIPPING", "orders", plan)
    assert_equal(ddl, table.concat({
        "ALTER SEMANTIC VIEW logistics.SHIPPING",
        "REPLACE DIMENSIONS (",
        "  DIMENSION ship_mode ON ENTITY orders AS o.ship_mode RETURNS VARCHAR(2000000) UTF8"
            .. " COMMENT 'How the order shipped',",
        "  DIMENSION order_status ON ENTITY orders AS o.order_status RETURNS"
            .. " VARCHAR(2000000) UTF8 COMMENT 'Where the order is'",
        ")",
        "REPLACE FACTS (",
        "  FACT shipping__freight_1 ON ENTITY orders AS o.freight_amount RETURNS DECIMAL(18,2)"
            .. " PRIVATE,",
        "  FACT shipping__order_count_1 ON ENTITY orders AS o.order_id RETURNS DECIMAL(18,0)"
            .. " PRIVATE",
        ")",
        "REPLACE METRICS (",
        "  METRIC freight AS sum(shipping__freight_1) ON ENTITY orders RETURNS DECIMAL(29,2)"
            .. " COMMENT 'Total freight, in EUR',",
        "  METRIC order_count AS count(DISTINCT shipping__order_count_1) ON ENTITY orders"
            .. " RETURNS DECIMAL(18,0) COMMENT 'Distinct orders'",
        ")",
    }, "\n"))
end)

test("adoption translates an unaliased view and the metric forms", function()
    local select = adoption.parse_select("SELECT ship_mode, COUNT(*) AS n,"
        .. " SUM(freight_amount) / NULLIF(COUNT(order_id), 0) AS per_order,"
        .. " AVG(freight_amount * 2) AS doubled, format"
        .. " FROM s.orders GROUP BY ship_mode, 5")
    local view = shipping_view({
        {name = "SHIP_MODE", type = "VARCHAR(20)"},
        {name = "N", type = "DECIMAL(18,0)"},
        {name = "PER_ORDER", type = "DOUBLE"},
        {name = "DOUBLED", type = "DOUBLE"},
        {name = "FORMAT", type = "VARCHAR(10)"},
    })
    local plan = adoption.translate(view, select, orders_scope("orders"), CLAUSE_WORDS)
    -- With no comment of its own, a plain column takes the source column's.
    assert_equal(plan.dimensions[1].description, "Mode of transport")
    -- A column named like a DDL clause is kept out of the clause scan.
    assert_equal(plan.dimensions[2].expression, "(orders.format)")
    assert_equal(plan.facts[1].expression, "1")
    assert_equal(plan.metrics[1].expression, "COUNT(shipping__n_1)")
    assert_equal(plan.metrics[2].expression,
        "SUM(shipping__per_order_1) / NULLIF(COUNT(shipping__per_order_2), 0)")
    -- An expression argument's fact takes the metric's type.
    assert_equal(plan.facts[4].expression, "orders.freight_amount * 2")
    assert_equal(plan.facts[4].data_type, "DOUBLE")
end)

test("adoption refuses a view whose columns it cannot translate", function()
    local scope = orders_scope("o")
    local function translate(sql, columns)
        return function()
            adoption.translate(shipping_view(columns), adoption.parse_select(sql), scope,
                CLAUSE_WORDS)
        end
    end
    local two = {{name = "A", type = "INT"}, {name = "B", type = "INT"}}
    each({
        {"SELECT ship_mode FROM s.orders", {{name = "A", type = "INT"}}, "SEMANTIC_ADMIN_229",
         "no aggregate column"},
        {"SELECT SUM(order_id) FROM s.orders", two, "SEMANTIC_ADMIN_229",
         "1 select items for 2 columns"},
        {"SELECT ship_mode, SUM(order_id) + order_id FROM s.orders GROUP BY 1", two,
         "SEMANTIC_ADMIN_229", "the column ORDER_ID outside an aggregate"},
        {"SELECT ship_mode, SUM(order_id) FROM s.orders GROUP BY ship_mode, order_status", two,
         "SEMANTIC_ADMIN_229", "GROUP BY order_status"},
        {"SELECT ship_mode, SUM(order_id) FROM s.orders GROUP BY 2", two,
         "SEMANTIC_ADMIN_229", "GROUP BY 2"},
        {"SELECT ship_mode, SUM(order_id) FROM s.orders GROUP BY ship_mode",
         {{name = "Ship Mode", type = "INT"}, {name = "B", type = "INT"}},
         "SEMANTIC_ADMIN_232", '"Ship Mode" cannot be a semantic name'},
    }, function(case)
        refused(translate(case[1], case[2]), case[3], case[4])
    end)
    -- GROUP BY may name a column by position, alias or expression.
    for _, group_by in ipairs({"1", "a", "ship_mode", "o.ship_mode"}) do
        adoption.translate(shipping_view({{name = "A", type = "INT"}, {name = "B", type = "INT"}}),
            adoption.parse_select("SELECT ship_mode AS a, SUM(order_id) FROM s.orders o"
                .. " GROUP BY " .. group_by), orders_scope("o", "O"), CLAUSE_WORDS)
    end
end)

-- The catalog as ADOPT_VIEW reads it, for the documented dbt view. `state`
-- says whether the model exists and what APPLY_SEMANTIC_DEFINITION answers;
-- every statement is recorded.
local function adoption_catalog(state)
    local executed = {}
    local object_added = state.object_exists
    local function respond(sql, params)
        local text = tostring(sql)
        local function has(fragment) return text:find(fragment, 1, true) ~= nil end
        if has("EXECUTE SCRIPT") or has("DELETE FROM") or has("INSERT INTO") then
            executed[#executed + 1] = text
        end
        if has("UNION ALL") then return {{"DBT_ADOPT_FIXTURES", "ORDERS"}} end
        if has("VIEW_TEXT") then
            return {{"DBT_ADOPT_FIXTURES", "SHIPPING",
                     read_text("tests/fixtures/adopt_view/dbt_shipping.sql"),
                     "Freight by ship mode and status. It's documented."}}
        end
        if has("FROM SYS.EXA_ALL_COLUMNS") and params.object_name == "SHIPPING" then
            return {{"SHIP_MODE", "VARCHAR(2000000) UTF8", "How the order shipped"},
                    {"ORDER_STATUS", "VARCHAR(2000000) UTF8", ""},
                    {"FREIGHT", "DECIMAL(29,2)", "Total freight, in EUR"},
                    {"ORDER_COUNT", "DECIMAL(18,0)", "Distinct orders"}}
        end
        if has("FROM SYS.EXA_ALL_COLUMNS") and params.object_name == "ORDERS" then
            return {{"ORDER_ID", "DECIMAL(18,0)", null}, {"SHIP_MODE", "VARCHAR(2000000) UTF8", null},
                    {"ORDER_STATUS", "VARCHAR(2000000) UTF8", null},
                    {"FREIGHT_AMOUNT", "DECIMAL(18,2)", null}}
        end
        if has("FROM SYS.EXA_ALL_COLUMNS") then return {{"MODEL_ID"}} end
        if has("FROM SYS_SEMANTIC.MODELS") then
            if state.model_exists or has("SEMANTIC_ADMIN.CREATE_MODEL") then
                return {{1, 2, state.status or "DRAFT"}}
            end
            return {}
        end
        if has("SEMANTIC_ADMIN.CREATE_MODEL") then state.model_exists = true end
        if has("SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION") then
            if state.refuse and tostring(params.ddl):find("REPLACE DIMENSIONS", 1, true) then
                return {{"ERROR", "SEMANTIC_DDL_096", "SEMANTIC_DDL_096: dimension ship_mode is also listed"}}
            end
            return {{"OK", null, "applied"}}
        end
        if has("SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT") then object_added = true end
        if has("FROM SYS_SEMANTIC.SEMANTIC_OBJECTS so") then
            return object_added and {{10, "DBT_ADOPT_FIXTURES", "ORDERS"}} or {}
        end
        if has("EXA_SQL_KEYWORDS") or has("UPPER(SOURCE_ALIAS)") then return {{0}} end
        if has("EXA_ALL_OBJECTS") then return {{"One row per order"}} end
        if has("SELECT mt.METRIC_NAME") then return {{"retired_metric"}} end
        if has("SELECT FACT_NAME") then
            return {{"shipping__freight_1"}, {"shipping__retired_metric_1"}}
        end
        return {}
    end
    return respond, executed
end

local function statements_with(executed, fragment)
    local found = {}
    for _, sql in ipairs(executed) do
        if sql:find(fragment, 1, true) then found[#found + 1] = sql end
    end
    return found
end

test("adoption creates the model, entity and view, and publishes", function()
    local respond, executed = adoption_catalog({})
    local rows
    with_query(respond, function() rows = adopt_view("logistics", "dbt_adopt_fixtures", "shipping") end)
    assert_equal(rows[1][1], "logistics")
    assert_equal(rows[1][2], "SHIPPING")
    assert_equal(rows[1][3], 2)
    assert_equal(rows[1][4], 2)
    assert_equal(rows[1][5], "OK")
    local ddl = rows[1][6]
    assert_contains(ddl, "CREATE_MODEL('logistics', 'SEMANTIC_LOGISTICS', NULL, NULL);")
    assert_contains(ddl, "ADD_ENTITY('logistics', 'orders', 'DBT_ADOPT_FIXTURES', 'ORDERS', 'o',"
        .. " NULL, NULL, 'One row per order');")
    assert_contains(ddl, "ADD_SEMANTIC_OBJECT('logistics', 'SHIPPING', 'orders',"
        .. " 'Freight by ship mode and status. It''s documented.');")
    assert_contains(ddl, "DIMENSION ship_mode ON ENTITY orders AS o.ship_mode")
    -- Stale members go: the metric before the replace, the facts after it.
    local applied = statements_with(executed, "APPLY_SEMANTIC_DEFINITION")
    assert_equal(#applied, 3)
    assert_equal(#statements_with(executed, "SEMANTIC_ADMIN.PUBLISH_MODEL"), 1)
end)

test("adoption on a published model leaves the refresh to the definition apply", function()
    local respond, executed = adoption_catalog({model_exists = true, object_exists = true,
                                                status = "PUBLISHED"})
    with_query(respond, function() adopt_view("logistics", "DBT_ADOPT_FIXTURES", "SHIPPING") end)
    assert_equal(#statements_with(executed, "CREATE_MODEL"), 0)
    assert_equal(#statements_with(executed, "ADD_SEMANTIC_OBJECT"), 0)
    assert_equal(#statements_with(executed, "SEMANTIC_ADMIN.PUBLISH_MODEL"), 0)
end)

test("a refused adoption into a new model drops the model it created", function()
    local respond, executed = adoption_catalog({refuse = true})
    local ok, err = pcall(with_query, respond, function()
        adopt_view("logistics", "DBT_ADOPT_FIXTURES", "SHIPPING")
    end)
    assert_true(not ok)
    assert_contains(tostring(err), "SEMANTIC_DDL_096: dimension ship_mode is also listed")
    assert_true(not tostring(err):find("SEMANTIC_DDL_096: SEMANTIC_DDL_096", 1, true))
    assert_equal(#statements_with(executed, "DROP_MODEL_IF_EXISTS"), 1)
end)

test("a refused adoption into an existing model restores its catalog", function()
    local respond, executed = adoption_catalog({model_exists = true, refuse = true,
                                                status = "PUBLISHED"})
    local ok, err = pcall(with_query, respond, function()
        adopt_view("logistics", "DBT_ADOPT_FIXTURES", "SHIPPING")
    end)
    assert_true(not ok)
    assert_contains(tostring(err), "SEMANTIC_DDL_096")
    assert_equal(#statements_with(executed, "DROP_MODEL_IF_EXISTS"), 0)
    assert_contains(statements_with(executed, "DELETE FROM SYS_SEMANTIC.")[1] or "",
        "DELETE FROM SYS_SEMANTIC.")
    assert_equal(#statements_with(executed, "VALIDATE_MODEL"), 1)
    assert_equal(#statements_with(executed, "SEMANTIC_ADMIN.PUBLISH_MODEL"), 1)
end)

test("adoption refuses a missing argument and a missing view", function()
    refused(function() adopt_view("logistics", null, "SHIPPING") end, "SEMANTIC_ADMIN_001",
        "VIEW_SCHEMA is required")
    refused(function()
        with_query(function() return {} end, function()
            adopt_view("logistics", "MART", "nope")
        end)
    end, "SEMANTIC_ADMIN_228", "view MART.nope does not exist")
end)
