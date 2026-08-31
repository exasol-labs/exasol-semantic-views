local json = ESV_JSON

test("shared json encodes deterministically and round-trips", function()
    -- Sorted keys are the round-trip contract: EXPORT_FUSION_DECLARATION and
    -- EXPORT_SEMANTIC_DEFINITION both compare an exported document to a
    -- re-exported one, so two encodings of the same table must be one string.
    assert_equal(json.encode({b = 1, a = 2}), '{"a":2,"b":1}')
    assert_equal(json.encode({"x", "y"}), '["x","y"]')
    assert_equal(json.encode({}), "[]")
    assert_equal(json.encode(true), "true")
    assert_equal(json.encode(false), "false")
    assert_equal(json.encode(nil), "null")
    assert_equal(json.encode(null), "null")
    assert_equal(json.encode(json.NULL), "null")
    assert_equal(json.encode('a"b\\c'), '"a\\"b\\\\c"')
    assert_equal(json.encode("a\nb\tc\rd"), '"a\\nb\\tc\\rd"')

    -- Anything the codec has no JSON spelling for is stringified rather than
    -- dropped. Exasol hands scripts userdata for values that are not SQL NULL,
    -- and a plan or log payload silently missing a field is worse than one
    -- carrying an unhelpful string.
    assert_equal(json.encode(json.is_array), '"' .. json.escape(tostring(json.is_array)) .. '"')

    local document = {name = "sales", tags = {"a", "b"},
        nested = {flag = true, count = 3}}
    local decoded = json.decode(json.encode(document))
    assert_equal(decoded.name, "sales")
    assert_equal(decoded.tags[2], "b")
    assert_equal(decoded.nested.count, 3)
    assert_equal(json.encode(decoded), json.encode(document))
end)

test("shared json decodes every scalar and structural form", function()
    assert_equal(json.decode('"text"'), "text")
    assert_equal(json.decode("42"), 42)
    assert_equal(json.decode("-1.5e2"), -150)
    assert_equal(json.decode("true"), true)
    assert_equal(json.decode("false"), false)
    -- Insignificant whitespace anywhere a value or separator may appear.
    assert_equal(json.encode(json.decode(' \n\t{ "a" : [ 1 , 2 ] } ')), '{"a":[1,2]}')
    assert_equal(#json.decode("[]"), 0)
    assert_equal(json.decode('{"a":[1,{"b":null}]}').a[2].b, json.NULL)
    assert_equal(json.decode('"a\\/b\\b\\f\\n\\r\\t\\"c"'), 'a/b\b\f\n\r\t"c')
    -- Long-standing and deliberate: a \u escape decodes to a placeholder rather
    -- than being expanded, so a decode/encode round trip stays stable.
    assert_equal(json.decode('"\\u0041"'), "?")

    assert_error(function() return json.decode("") end, "empty JSON payload")
    assert_error(function() return json.decode(null) end, "empty JSON payload")
    assert_error(function() return json.decode(json.NULL) end, "empty JSON payload")
    assert_error(function() return json.decode("{") end, "expected string")
    assert_error(function() return json.decode('{"a":1}x') end, "trailing JSON")
    assert_error(function() return json.decode('{"a" 1}') end, "object colon")
    assert_error(function() return json.decode('{"a":1 "b":2}') end, "object comma")
    assert_error(function() return json.decode("[1 2]") end, "array comma")
    assert_error(function() return json.decode('"\\q"') end, "invalid escape")
    assert_error(function() return json.decode('"abc') end, "unterminated string")
    assert_error(function() return json.decode("nope") end, "unexpected JSON token")
    assert_error(function() return json.decode("-") end, "invalid number")
end)

test("shared json null is a sentinel every holder can recognise", function()
    -- The reason this module exists. JSON_NULL used to be a private `{}` in each
    -- of four files, so a null decoded by one was an anonymous empty table to
    -- the others: compiler/query_spec.lua read it as an empty array and
    -- admin/fusion_declaration.lua read it as a present declaration whose
    -- tostring was an address. Identity is the whole contract.
    assert_true(json.decode("null") == json.NULL)
    assert_true(json.decode('{"k":null}').k == json.NULL)
    assert_true(json.decode("[null]")[1] == json.NULL)

    -- An empty object and a null are both empty tables. Only identity separates
    -- them, which is why is_array tests identity rather than contents.
    assert_branch("json.is_array", json.is_array(json.NULL), false)
    assert_branch("json.is_array", json.is_array({1, 2}), true)
    assert_equal(json.is_array(json.decode("{}")), true)
    assert_equal(json.is_array(json.decode('{"a":1}')), false)
    assert_equal(json.is_array("text"), false)
    assert_equal(json.is_array({[2] = "gap"}), false)
    assert_equal(json.is_array({[1.5] = "fraction"}), false)
    assert_equal(json.is_array({[0] = "zero"}), false)

    -- No metatable: a caller that reached for tostring instead of identity would
    -- otherwise see something that looked deliberate.
    assert_equal(getmetatable(json.NULL), nil)
end)

test("shared json strict validation refuses what the decoder tolerates", function()
    -- decode and is_valid are one parser with one flag, and this is the list of
    -- inputs they answer differently about. Every entry is a case the decoder
    -- accepts because it re-reads payloads this runtime wrote, and the validator
    -- refuses because a model author typed it.
    assert_branch("json.is_valid", json.is_valid('{"a":1}'), true)
    assert_branch("json.is_valid", json.is_valid("01"), false)

    assert_equal(json.decode("01"), 1)            -- leading zero
    assert_equal(json.decode("1."), 1.0)          -- fraction with no digits
    assert_equal(json.encode(json.decode("[00]")), "[0]")
    for _, lenient in ipairs({"01", "1.", "[00]"}) do
        assert_equal(json.is_valid(lenient), false, lenient)
    end

    -- A bad unicode escape and a raw control character are structurally fine and
    -- semantically wrong; only the strict mode says so.
    assert_equal(json.decode('"\\uZZZZ"'), "?")
    assert_equal(json.is_valid('"\\uZZZZ"'), false)
    assert_equal(json.is_valid('"\\u0041"'), true)
    assert_equal(json.is_valid('"a\nb"'), false)

    -- Where they agree: is_valid never raises, and malformed is malformed.
    for _, malformed in ipairs({"", "{", "nope", '{"a":1}x', '{"a" 1}', "[1,]",
            '"abc', '"\\q"', "-"}) do
        assert_equal(json.is_valid(malformed), false, malformed)
    end
    for _, well_formed in ipairs({"null", "true", "-1.5e+2", '["a",{"b":null}]',
            '{"a":{"b":[1,2,3]}}', "0", "-0.5"}) do
        assert_equal(json.is_valid(well_formed), true, well_formed)
    end
    assert_equal(json.is_valid(null), false)
    assert_equal(json.is_valid(nil), false)
end)
