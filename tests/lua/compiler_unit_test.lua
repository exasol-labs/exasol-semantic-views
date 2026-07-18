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
