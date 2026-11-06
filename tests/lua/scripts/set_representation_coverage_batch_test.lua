local H = SCRIPT_BODY
local run, test_script = H.for_script("set_representation_coverage_batch")

test_script("requires MODEL_NAME", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: MODEL_NAME is required", {}))
end)

local function parameters(payload)
    return {MODEL_NAME = "sales", ENTITY_NAME = "orders", COVERAGE_JSON = payload}
end

local representation = {MODEL_ID = 1, ACTIVE_VERSION_ID = 2, STATUS = "DRAFT",
    REPRESENTATION_ID = 3, REPRESENTATION_NAME = "primary"}

local function saved(payload, predicate, valid_from, valid_to)
    local steps = {
        H.step("FROM SYS_SEMANTIC.MODELS m", {representation}),
        H.step("UPDATE SYS_SEMANTIC.ENTITY_REPRESENTATIONS", {},
            {representation_id = 3, coverage_predicate = predicate,
                valid_from = valid_from, valid_to = valid_to}),
        H.step("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE"),
        H.step("UPDATE SYS_SEMANTIC.VALIDATION_RUNS"),
        H.step("SELECT VALID_FROM, VALID_TO", {{VALID_FROM = null, VALID_TO = null}}),
    }
    local result = run(parameters(payload), H.supported(steps))
    H.same(result.rows, {{3, "sales", "orders", "primary",
        predicate == null and "NONE" or "UNION", predicate, null, null}}, "result")
end

for _, case in ipairs({
        {"explicit null fields", '[{"representation_name":"primary",'
            .. '"coverage_predicate":null,"valid_from":null,"valid_to":null,'
            .. '"extra":{"nested":[true,false,null]}}]', null, null, null},
        {"escaped predicate and date bound", '[{"representation_name":"primary",'
            .. '"coverage_predicate":" x\\n = 1 ","valid_from":"2026-01-01",'
            .. '"valid_to":null,"extra":"\\u0041"}]', "x\n = 1", "2026-01-01", null},
        {"absent optional fields", '[{"representation_name":"primary"}]', null, null, null},
        {"nested scalars and every string escape", '[{"representation_name":"primary",'
            .. '"extra":{"text":"\\\"\\\\\\/\\b\\f\\n\\r\\t",'
            .. '"values":[-1.25e+2,0,true,false,null,[],{}]}}]', null, null, null},
    }) do
    test_script("stores " .. case[1] .. " as expected SQL values", function()
        saved(case[2], case[3], case[4], case[5])
    end)
end

for _, case in ipairs({
        {"empty input", "", "empty JSON payload"},
        {"whitespace only", " ", "unexpected JSON token"},
        {"unfinished object", "{", "expected string"},
        {"missing object colon", '{"a" 1}', "expected object colon"},
        {"missing object comma", '{"a":1 "b":2}', "expected object comma"},
        {"missing array comma", "[1 2]", "array comma"},
        {"invalid escape", '["\\q"]', "invalid escape"},
        {"unterminated string", '["abc', "unterminated string"},
        {"invalid number", "[-]", "invalid number"},
        {"trailing text", "[] x", "trailing JSON"},
        {"top-level null", "null", "array is empty"},
        {"trailing object comma", '[{"a":1,}]', "expected string"},
        {"nested missing object comma", '[{"a":1 "b":2}]', "object comma"},
        {"nested missing object colon", '[{"a" 1}]', "object colon"},
        {"top-level true", "true", "top-level value is not an array"},
        {"top-level false", "false", "top-level value is not an array"},
        {"top-level string", '"text"', "top-level value is not an array"},
        {"top-level number", "42", "top-level value is not an array"},
        {"empty array", "[]", "array is empty"},
        {"empty object", "{}", "array is empty"},
    }) do
    test_script("refuses " .. case[1] .. " before SQL", function()
        local result = run(parameters(case[2]),
            H.refusal("SEMANTIC_ADMIN_060: COVERAGE_JSON must be a non-empty JSON array",
                {}))
        assert_contains(result.error, case[3])
    end)
end

for _, case in ipairs({
        {"null declaration", '[null]', "representation_name is required"},
        {"boolean declaration", '[true]', "coverage declaration 1 must be an object"},
        {"missing representation name", '[{}]', "representation_name is required"},
        {"null representation name", '[{"representation_name":null}]',
            "representation_name is required"},
        {"unknown representation", '[{"representation_name":"other"}]',
            "active representation not found"},
        {"predicate without bounds", '[{"representation_name":"primary",'
            .. '"coverage_predicate":"x"}]', "UNION partition requires VALID_FROM or VALID_TO"},
        {"bounds without predicate", '[{"representation_name":"primary",'
            .. '"valid_from":"2026"}]', "coverage bounds require COVERAGE_PREDICATE"},
    }) do
    test_script("rejects " .. case[1] .. " before updates", function()
        local fixture = H.supported({H.step("FROM SYS_SEMANTIC.MODELS m", {representation})})
        fixture.error = case[3]
        run(parameters(case[2]), fixture)
    end)
end
