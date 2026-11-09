local H = SCRIPT_BODY
local run, test_script = H.for_script("add_custom_extension")

test_script("requires MODEL_NAME", function()
    run({}, H.refusal("SEMANTIC_ADMIN_001: MODEL_NAME is required", {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
end)

local function parameters(payload)
    return {MODEL_NAME = "sales", SCOPE_TYPE = "MODEL", VENDOR_NAME = "vendor",
        DATA_JSON = payload}
end

local function stored(payload, update)
    local steps = {
        H.step("FROM SYS_SEMANTIC.MODELS", {{MODEL_ID = 1, VERSION_ID = 2}}),
        H.step("SELECT CUSTOM_EXTENSION_ID", update and {{9}} or {}),
    }
    if update then
        steps[#steps + 1] = H.step("UPDATE SYS_SEMANTIC.CUSTOM_EXTENSIONS", {},
            {custom_extension_id = 9, data_json = payload})
    else
        steps[#steps + 1] = H.step("INSERT INTO SYS_SEMANTIC.CUSTOM_EXTENSIONS", {},
            {model_id = 1, version_id = 2, scope_type = "MODEL", scope_id = 1,
                vendor_name = "vendor", extension_name = "default", source_format = "OSI",
                data_json = payload})
        steps[#steps + 1] = H.step("SELECT MAX(CUSTOM_EXTENSION_ID)", {{[1] = 9}})
    end
    local result = run(parameters(payload), H.supported(steps))
    H.same(result.rows, {{9, "sales", "MODEL", null, "vendor", "default", "OSI", update}}, "result")
end

for _, case in ipairs({
        {"empty object", "{}"},
        {"empty array", "[]"},
        {"JSON null", "null"},
        {"true", "true"},
        {"false", "false"},
        {"signed fraction and exponent", "-1.25e+2"},
        {"string", '"plain"'},
        {"nested object and array", '{"a":[null,true,false,{"b":"x"}]}'},
        {"every string escape", '"\\\"\\\\\\/\\b\\f\\n\\r\\t\\u0041"'},
        {"insignificant whitespace", ' { "a" : [ 1 , 2 ] } '},
    }) do
    test_script("stores " .. case[1] .. " without rewriting", function()
        stored(case[2], false)
    end)
end

test_script("updates an existing extension with the original JSON text", function()
    stored('{"nested":[1,null]}', true)
end)

for _, case in ipairs({
        {"empty input", "", "DATA_JSON is required"},
        {"whitespace only", " ", "unexpected JSON token"},
        {"unfinished object", "{", "expected string"},
        {"missing object colon", '{"a" 1}', "expected object colon"},
        {"missing object comma", '{"a":1 "b":2}', "expected object comma"},
        {"missing array comma", "[1 2]", "expected array comma"},
        {"invalid escape", '"\\q"', "invalid escape"},
        {"unterminated string", '"abc', "unterminated string"},
        {"invalid number", "-", "invalid number"},
        {"trailing text", "false x", "unexpected trailing JSON"},
        {"trailing array comma", "[1,]", "unexpected JSON token"},
        {"leading-zero number", "01", "byte ", true},
        {"fraction without digits", "1.", "byte ", true},
        {"invalid unicode digits", '"\\uZZZZ"', "byte ", true},
        {"raw newline", '"raw\nline"', "byte ", true},
    }) do
    local name = case[4] and "refuses nonstandard " .. case[1] .. " with SEMANTIC_ADMIN_040"
        or "refuses " .. case[1] .. " before SQL"
    test_script(name, function()
        local code = case[2] == "" and "SEMANTIC_ADMIN_001: DATA_JSON is required"
            or "SEMANTIC_ADMIN_040: DATA_JSON must be valid JSON"
        local result = run(parameters(case[2]),
            H.refusal(code, {"SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME"}))
        assert_contains(result.error, case[3])
    end)
end
