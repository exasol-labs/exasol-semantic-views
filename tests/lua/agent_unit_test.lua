local api = ESV_AGENT_TEST_API

test("agent JSON encoding distinguishes arrays and objects", function()
    local encoded = api.json_encode({status = "OK", fields = {"a", "b"}})
    assert_contains(encoded, '"fields":["a","b"]')
    assert_contains(encoded, '"status":"OK"')
end)

test("agent materialization extraction handles selected and absent plans", function()
    local selected = api.extract_selected_materialization(
        '{"selected_materialization":{"materialization_name":"sales_by_region"}}')
    assert_equal(selected, "sales_by_region")
    assert_branch("agent.materialization", selected ~= null, true)
    local absent = api.extract_selected_materialization('{}')
    assert_branch("agent.materialization", absent ~= null, false)
end)

test("agent extracts request arrays and escapes LIKE patterns", function()
    assert_equal(api.extract_json_array_text('{"metrics":["a","b"]}', "metrics"), '["a","b"]')
    local pattern = api.like_pattern("50%_off")
    assert_contains(pattern, "\\%")
    assert_contains(pattern, "\\_")
end)

test("agent rows convert to named objects", function()
    local objects = api.rows_to_objects({{1, "sales"}, {2, "orders"}}, {"id", "name"})
    assert_equal(objects[2].id, 2)
    assert_equal(objects[2].name, "orders")
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

test("agent input normalization rejects invalid contract values", function()
    assert_equal(api.normalize_name(" sales_model ", "MODEL_NAME"), "sales_model")
    assert_error(function() api.normalize_name(nil, "MODEL_NAME") end, "SEMANTIC_AGENT_001")
    assert_error(function() api.normalize_name("bad-name", "MODEL_NAME") end, "SEMANTIC_AGENT_002")
    assert_equal(api.normalize_choice(" metric ", "SCOPE_TYPE", {METRIC = true}), "METRIC")
    assert_error(function()
        api.normalize_choice("unknown", "SCOPE_TYPE", {MODEL = true, METRIC = true})
    end, "Valid values: METRIC, MODEL")
    assert_true(api.bool_value("yes", false))
    assert_true(not api.bool_value("no", true))
    assert_true(api.bool_value(nil, true))
end)

test("agent instruction creation is idempotent and resolves metric scope", function()
    local inserted = nil
    local target_insert = nil
    local duplicate = true
    local function mock(sql, params)
        if contains(sql, "FROM SYS_SEMANTIC.MODELS") then
            return {{MODEL_ID = 1, MODEL_NAME = "sales", VERSION_ID = 2,
                PUBLISHED_SCHEMA = "SEMANTIC_SALES"}}
        elseif contains(sql, "SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS") then
            return {{30}}
        elseif contains(sql, "SELECT INSTRUCTION_ID FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS") then
            if duplicate then return {{INSTRUCTION_ID = 9}} end
            return {}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.AGENT_INSTRUCTIONS") then
            inserted = params
            return {}
        elseif contains(sql, "SELECT MAX(INSTRUCTION_ID)") then
            return {{10}}
        end
        error("unexpected SQL: " .. tostring(sql))
    end

    with_query(mock, function()
        local existing = add_agent_instruction("sales", "metric", "total_revenue",
            "definition", "Recognized revenue", nil, nil)
        assert_equal(existing[1][1], 9)
        assert_branch("agent.instruction.duplicate", existing[1][1] == 9, true)

        duplicate = false
        local created = add_agent_instruction("sales", "METRIC", "total_revenue",
            "DEFINITION", "Recognized revenue", "ANALYST", "25")
        assert_equal(created[1][1], 10)
        assert_equal(inserted.scope_id, 30)
        assert_equal(inserted.priority, 25)
        assert_equal(inserted.applies_to_role, "ANALYST")
        assert_branch("agent.instruction.duplicate", created[1][1] == 9, false)
    end)
end)

test("agent instruction validation rejects missing and invalid scopes", function()
    assert_error(function()
        add_agent_instruction("sales", "METRIC", "revenue", "GENERAL", nil, nil, nil)
    end, "INSTRUCTION_TEXT is required")

    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.MODELS") then
            return {{1, "sales", 2, "SEMANTIC_SALES"}}
        elseif contains(sql, "SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS") then
            return {}
        end
        return {}
    end, function()
        assert_error(function()
            add_agent_instruction("sales", "METRIC", "missing", "GENERAL", "text", nil, nil)
        end, "SEMANTIC_AGENT_012")
    end)
end)

test("verified query registration requires a successful compile", function()
    local compile_ok = true
    local inserted = nil
    local function mock(sql, params)
        if contains(sql, "FROM SYS_SEMANTIC.MODELS") then
            return {{1, "sales", 2, "SEMANTIC_SALES"}}
        elseif contains(sql, "FROM SYS_SEMANTIC.SEMANTIC_OBJECTS") then
            return {{40, "SALES"}}
        elseif contains(sql, "COMPILE_REQUEST_JSON") then
            if compile_ok then
                return {{STATUS = "OK", GENERATED_SQL = "SELECT 1"}}
            end
            return {{STATUS = "ERROR", ERROR_CODE = "SEMANTIC_REQUEST_020",
                ERROR_MESSAGE = "unknown metric"}}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.VERIFIED_QUERIES") then
            inserted = params
            return {}
        elseif contains(sql, "SELECT MAX(VERIFIED_QUERY_ID)") then
            return {{22}}
        end
        error("unexpected SQL: " .. tostring(sql))
    end

    with_query(mock, function()
        local result = add_verified_query("sales", "SALES", "top_regions",
            "Top regions", '{"metrics":["total_revenue"]}', "table", "yes")
        assert_equal(result[1][1], 22)
        assert_equal(result[1][6], "SELECT 1")
        assert_true(inserted.is_onboarding_example)
        assert_branch("agent.verified.compile", result[1][5] == "ACTIVE", true)

        compile_ok = false
        local ok = pcall(add_verified_query, "sales", "SALES", "bad",
            "Bad query", '{"metrics":["missing"]}', nil, false)
        assert_branch("agent.verified.compile", ok, false)
    end)
end)

test("agent search extracts meaningful terms and preserves ranked rows", function()
    assert_equal(api.search_term("show the metrics for total_revenue values"), "total_revenue")
    assert_equal(api.search_term("show metrics"), "show metrics")
    local seen = nil
    local rows = with_query(function(_, params)
        seen = params
        return {
            {"FIELD", "sales", "SALES", "METRIC", "total_revenue", "Total Revenue",
                "Revenue", "total_revenue", 100, true},
            {"SYNONYM", "sales", "SALES", "METRIC", "total_revenue", "Total Revenue",
                "Revenue", "sales", 95, true},
        }
    end, function()
        return search_semantic_objects("find total_revenue metrics", "sales")
    end)
    assert_equal(#rows, 2)
    assert_equal(rows[1][5], "total_revenue")
    assert_equal(seen.query_text, "total_revenue")
    assert_equal(seen.model_name, "sales")
end)

local function discovery_query(sql)
    if contains(sql, "FROM SEMANTIC_AGENT.MODELS_FOR_AGENT") then
        return {{MODEL_NAME = "sales"}}
    elseif contains(sql, "FROM SEMANTIC_AGENT.OBJECTS_FOR_AGENT") then
        if contains(sql, "ROOT_ENTITY_NAME") then
            return {{"sales", "SALES", "SEMANTIC_SALES", "SALES", "order_line",
                "Sales object", "READY", 50, "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR",
                "STRUCTURED_REQUEST,SEMANTIC_SQL"}}
        end
        return {{"sales", "SALES", "SEMANTIC_SALES", "SALES",
            "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR", "READY"}}
    elseif contains(sql, "FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT") and contains(sql, "ORDER BY ORDINAL_POSITION") then
        return {{"sales", "SALES", "METRIC", "total_revenue", "TOTAL_REVENUE",
            "DECIMAL(18,2)", "Total Revenue", "Recognized revenue", "currency",
            "USD", "INTERNAL", true, nil, nil}}
    elseif contains(sql, "FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT") then
        return {{"METRIC", "total_revenue", "Total Revenue", "Recognized revenue",
            "DECIMAL(18,2)", nil}}
    elseif contains(sql, "FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT") then
        return {{"DEFINITION", "Use recognized revenue"}}
    elseif contains(sql, "FROM SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT") then
        return {{"top_regions", "Top regions by revenue", '{"metrics":["total_revenue"]}'}}
    end
    error("unexpected discovery SQL: " .. tostring(sql))
end

test("agent object description returns object and field metadata", function()
    local rows = with_query(discovery_query, function()
        return describe_semantic_object("sales", "SALES")
    end)
    assert_equal(#rows, 2)
    assert_equal(rows[1][3], "OBJECT")
    assert_contains(rows[1][9], '"agent_readiness":"READY"')
    assert_equal(rows[2][3], "FIELD")
    assert_contains(rows[2][9], '"format_hint":"currency"')
end)

test("agent glossary supports structured and semantic SQL modes", function()
    with_query(discovery_query, function()
        local structured = get_business_glossary("sales", "SALES", nil)
        assert_equal(structured[1][3], "STRUCTURED_REQUEST")
        assert_contains(structured[1][4], "Use COMPILE_REQUEST_JSON")
        assert_contains(structured[1][4], "Instructions:")
        assert_contains(structured[1][4], "Verified examples:")
        assert_contains(structured[1][4], 'Request JSON: {"metrics":["total_revenue"]}')
        assert_contains(structured[1][5], '"request_json":"{\\"metrics\\":[\\"total_revenue\\"]}"')
        assert_branch("agent.glossary.semantic_sql", structured[1][3] == "SEMANTIC_SQL", false)

        local semantic = get_business_glossary("sales", "SALES", "semantic_sql")
        assert_contains(semantic[1][4], "SEMANTIC_SALES.SALES")
        assert_contains(semantic[1][4], "SEMANTIC_PREPROCESSOR")
        assert_branch("agent.glossary.semantic_sql", semantic[1][3] == "SEMANTIC_SQL", true)

        assert_error(function()
            get_business_glossary("sales", "SALES", "unsafe")
        end, "Valid values: STRUCTURED_REQUEST, SEMANTIC_SQL")
    end)
end)

local function handle_row(handle_type, handle_id)
    return {
        HANDLE_TYPE = handle_type,
        HANDLE_ID = handle_id,
        MODEL_ID = 1,
        MODEL_NAME = "sales",
        VERSION_ID = 2,
        STATUS = "OK",
        REQUEST_TEXT = '{"metrics":["total_revenue"]}',
        GENERATED_SQL = "SELECT 1",
        PLAN_JSON = '{"dimensions":["region"],"metrics":["total_revenue"],'
            .. '"selected_materialization":{"materialization_name":"sales_by_region"}}',
    }
end

test("agent explain normalizes handles and derives missing plan fields", function()
    local explained = with_query(function(sql, params)
        if contains(sql, "FROM SYS_SEMANTIC.AGENT_REQUEST_LOG") then
            return {handle_row("AGENT_REQUEST", params.handle_id)}
        end
        error("unexpected handle SQL")
    end, function()
        return explain_compiled_sql("agent", "77")
    end)
    assert_equal(explained[1][1], "AGENT_REQUEST")
    assert_equal(explained[1][2], 77)
    assert_equal(explained[1][11], '["region"]')
    assert_equal(explained[1][12], '["total_revenue"]')
    assert_equal(explained[1][13], "sales_by_region")
end)

test("agent feedback links the correct handle and optional suggestion", function()
    local feedback_params = nil
    local suggestion_params = nil
    local function mock(sql, params)
        if contains(sql, "FROM SYS_SEMANTIC.QUERY_LOG") then
            local row = handle_row("QUERY_LOG", params.handle_id)
            row.REQUESTED_DIMENSIONS = '["region"]'
            row.REQUESTED_METRICS = '["total_revenue"]'
            row.MATERIALIZATION_USED = "sales_by_region"
            return {row}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.AGENT_FEEDBACK") then
            feedback_params = params
            return {}
        elseif contains(sql, "SELECT MAX(FEEDBACK_ID)") then
            return {{501}}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.AGENT_SUGGESTIONS") then
            suggestion_params = params
            return {}
        elseif contains(sql, "SELECT MAX(SUGGESTION_ID)") then
            return {{601}}
        end
        error("unexpected feedback SQL: " .. tostring(sql))
    end
    with_query(mock, function()
        local result = record_agent_feedback("sql", 88, "needs_change", "Wrong grain",
            '{"dimension":"region"}')
        assert_equal(result[1][1], 501)
        assert_equal(result[1][2], 601)
        assert_equal(result[1][3], "QUERY_LOG")
        assert_equal(feedback_params.query_log_id, 88)
        assert_equal(suggestion_params.feedback_id, 501)
        assert_branch("agent.feedback.suggestion", result[1][2] ~= null, true)

        local without = record_agent_feedback("query_log", 89, "helpful", nil, nil)
        assert_branch("agent.feedback.suggestion", without[1][2] ~= null, false)
    end)
end)

test("F7 evolution proposals are typed versioned and idempotent", function()
    local inserted = nil
    local duplicate = false
    local function mock(sql, params)
        if contains(sql, "FROM SYS_SEMANTIC.MODELS") then
            return {{MODEL_ID = 1, MODEL_NAME = "sales", VERSION_ID = 2,
                PUBLISHED_SCHEMA = "SEMANTIC_SALES"}}
        elseif contains(sql, "SELECT ENTITY_ID FROM SYS_SEMANTIC.ENTITIES") then
            return {{20}}
        elseif contains(sql, "FROM SYS_SEMANTIC.AGENT_SUGGESTIONS")
            and contains(sql, "REVIEW_STATUS = 'PENDING'") then
            return duplicate and {{SUGGESTION_ID = 701}} or {}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.AGENT_SUGGESTIONS") then
            inserted = params
            return {}
        elseif contains(sql, "SELECT MAX(SUGGESTION_ID)") then
            return {{701}}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.AGENT_SUGGESTION_TARGETS") then
            target_insert = params
            return {}
        end
        error("unexpected evolution proposal SQL: " .. tostring(sql))
    end
    with_query(mock, function()
        local created = propose_model_evolution("sales", "new_identity", "entity",
            "customer", '{"identity":"global_customer_id"}',
            "Queries join customer records across sources")
        assert_equal(created[1][1], 701)
        assert_equal(created[1][4], "NEW_IDENTITY")
        assert_equal(created[1][5], "ENTITY")
        assert_equal(created[1][7], "PENDING")
        assert_true(created[1][8] == false)
        assert_equal(inserted.object_id, 20)
        assert_equal(inserted.version_id, 2)
        assert_equal(target_insert.object_name, "customer")

        duplicate = true
        local existing = propose_model_evolution("sales", "NEW_IDENTITY", "ENTITY",
            "customer", '{"identity":"global_customer_id"}', "Same evidence")
        assert_equal(existing[1][1], 701)
        assert_true(existing[1][8] == true)

        duplicate = false
        local concept = propose_model_evolution("sales", "NEW_CONCEPT", "METRIC",
            "retention_rate", '{"metric":"retention_rate"}',
            "Repeated historical retention queries")
        assert_equal(concept[1][5], "METRIC")
        assert_equal(concept[1][6], "retention_rate")
        assert_equal(inserted.object_id, null)
        assert_equal(target_insert.object_name, "retention_rate")
    end)
end)

test("F7 evolution proposal contracts fail closed", function()
    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.MODELS") then
            return {{1, "sales", 2, "SEMANTIC_SALES"}}
        end
        return {}
    end, function()
        assert_error(function()
            propose_model_evolution("sales", "AUTHORITY_CHANGE", "METRIC",
                "revenue", '{}', "Wrong target")
        end, "must target an existing ENTITY")
        assert_error(function()
            propose_model_evolution("sales", "NEW_CONCEPT", "METRIC",
                "revenue", '[1]', "Malformed payload")
        end, "must be a JSON object")
        assert_error(function()
            propose_model_evolution("sales", "UNKNOWN", "ENTITY",
                "customer", '{}', "Unknown kind")
        end, "invalid SUGGESTION_KIND")
        assert_error(function()
            propose_model_evolution("sales", "DRIFT_REPAIR", "ENTITY",
                "missing_entity", '{}', "Source drift")
        end, "evolution target not found")
    end)
end)

test("F7 human review certifies without catalog activation", function()
    local review_insert = nil
    local suggestion_update = nil
    local function mock(sql, params)
        if contains(sql, "FROM SYS_SEMANTIC.AGENT_SUGGESTIONS s") then
            return {{MODEL_ID = 1, VERSION_ID = 2, SUGGESTION_KIND = "DRIFT_REPAIR",
                OBJECT_TYPE = "ENTITY", OBJECT_ID = 20, REVIEW_STATUS = "PENDING",
                MODEL_NAME = "sales", ACTIVE_VERSION_ID = 2}}
        elseif contains(sql, "INSERT INTO SYS_SEMANTIC.AGENT_SUGGESTION_REVIEWS") then
            review_insert = params
            return {}
        elseif contains(sql, "UPDATE SYS_SEMANTIC.AGENT_SUGGESTIONS") then
            suggestion_update = params
            return {}
        elseif contains(sql, "SELECT CURRENT_USER") then
            return {{"HUMAN_REVIEWER"}}
        end
        error("unexpected evolution review SQL: " .. tostring(sql))
    end
    with_query(mock, function()
        local certified = review_model_evolution(701, "certified",
            "Evidence and smoke tests reviewed")
        assert_equal(certified[1][5], "CERTIFIED")
        assert_equal(certified[1][6], "HUMAN_REVIEWER")
        assert_equal(certified[1][7], "NO_CATALOG_MUTATION")
        assert_equal(review_insert.decision, "CERTIFIED")
        assert_equal(suggestion_update.decision, "CERTIFIED")

        local rejected = review_model_evolution(702, "REJECTED",
            "Evidence is insufficient")
        assert_equal(rejected[1][5], "REJECTED")
        assert_equal(rejected[1][7], "NOT_APPLICABLE")
    end)
end)

test("F7 review rejects stale certification and repeated decisions", function()
    with_query(function() return {} end, function()
        assert_error(function()
            review_model_evolution(404, "REJECTED", "Not found")
        end, "evolution suggestion not found")
    end)
    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.AGENT_SUGGESTIONS s") then
            return {{1, 2, "NEW_CONCEPT", "METRIC", null, "PENDING",
                "sales", 3}}
        end
        return {}
    end, function()
        assert_error(function()
            review_model_evolution(701, "CERTIFIED", "Looks good")
        end, "cannot certify a stale evolution suggestion")
    end)
    with_query(function(sql)
        if contains(sql, "FROM SYS_SEMANTIC.AGENT_SUGGESTIONS s") then
            return {{1, 2, "NEW_CONCEPT", "METRIC", null, "REJECTED",
                "sales", 2}}
        end
        return {}
    end, function()
        assert_error(function()
            review_model_evolution(701, "REJECTED", "Again")
        end, "already REJECTED")
    end)
end)

test("agent handles reject invalid identifiers and missing rows", function()
    assert_error(function() explain_compiled_sql("agent", "not-a-number") end,
        "HANDLE_ID must be numeric")
    with_query(function() return {} end, function()
        assert_error(function() explain_compiled_sql("query_log", 404) end,
            "SEMANTIC_AGENT_030")
    end)
end)
