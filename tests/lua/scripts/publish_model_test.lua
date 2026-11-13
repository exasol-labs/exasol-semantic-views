local H = SCRIPT_BODY
local run, test_script = H.for_script("publish_model")
local step = H.step
test_script("records a successful publish", function()
    local discovery = '"SEMANTIC_SALES"."SEMANTIC_DISCOVERY"'
    local fixture = {sql = {
        step("FROM SYS_SEMANTIC.MODELS", {{11, "sales", 12, "SEMANTIC_SALES", null}},
            {model_name = "sales"}),
        step("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", {}, {model_name = "sales"}),
        step("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE", nil, {version_id = 12}),
        step('CREATE SCHEMA IF NOT EXISTS "SEMANTIC_SALES"'),
        step('COMMENT ON SCHEMA "SEMANTIC_SALES"'),
        step("CREATE TABLE IF NOT EXISTS " .. discovery),
        step("COMMENT ON TABLE " .. discovery),
        step("DELETE FROM " .. discovery),
        step("VALUES ('MODEL_NAME'"),
        step("VALUES ('MODEL_DESCRIPTION'"),
        step("VALUES ('QUERY_ENTRYPOINT'"),
        step("VALUES ('MCP_GUIDANCE'"),
        step("VALUES ('FIELD_DISCOVERY_QUERY'"),
        step("VALUES ('COMPATIBILITY_QUERY'"),
        step("FROM SYS_SEMANTIC.SEMANTIC_OBJECTS", {{21, "orders", "Orders"}}),
        step("VALUES ('SEMANTIC_OBJECT'"),
        step("VALUES ('SEMANTIC_OBJECT_DESCRIPTION'"),
        step("VALUES ('SEMANTIC_SELECT_EXAMPLE'"),
        step("FROM SYS_SEMANTIC.OBJECT_COLUMNS", {
            {"revenue", "METRIC", "DECIMAL(18,2)", 1, "Revenue", 2, "UNION"},
        }, {object_id = 21, version_id = 12}),
        step('CREATE OR REPLACE VIEW "SEMANTIC_SALES"."orders"'),
        step("UPDATE SYS_SEMANTIC.MODELS", nil, {model_id = 11}),
        step("UPDATE SYS_SEMANTIC.MODEL_VERSIONS", nil, {version_id = 12}),
        step("SELECT VERSION_NUMBER", {{2}}, {version_id = 12}),
        step("NEXT_PUBLISH_NUMBER", {{3}}, {model_id = 11}),
        step("INSERT INTO SYS_SEMANTIC.MODEL_PUBLISH_HISTORY", nil,
            {model_id = 11, version_id = 12, version_number = 2, publish_number = 3}),
        step("FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS", {}),
    }}
    local result = run({MODEL_NAME = "sales"}, fixture)
    assert_equal(result.rows[1][3], "orders")
    assert_equal(result.rows[1][4], 1)
    assert_contains(result.columns, "PUBLISHED_SCHEMA VARCHAR")
    assert_contains(result.calls[20].sql, "SEMANTIC_ADMIN.SEMANTIC_GUARD() IS NOT NULL")
    assert_contains(result.calls[20].sql, "Fused across 2 temporal partitions")
    assert_equal(#result.calls, 26)
end)

test_script("refuses invalid validation", function()
    local fixture = {sql = {
        step("FROM SYS_SEMANTIC.MODELS", {{11, "sales", 12, "SEMANTIC_SALES", null}}),
        step("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", {
            {"ERROR", "MODEL", "sales", "SEMANTIC_MODEL_001", "invalid"},
        }),
    }, error = "SEMANTIC_SURFACE_013"}
    run({MODEL_NAME = "sales"}, fixture)
end)

test_script("requires model name", function()
    run({MODEL_NAME = null}, {error = "MODEL_NAME is required"})
end)

-- The steps of a publish of model sales (id 11, version 12) with one object,
-- orders, up to and including the read of its columns.
local function through_columns(column_rows, model_row)
    local discovery = '"SEMANTIC_SALES"."SEMANTIC_DISCOVERY"'
    return {
        step("FROM SYS_SEMANTIC.MODELS",
            {model_row or {11, "sales", 12, "SEMANTIC_SALES", "Sales"}}),
        step("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", {}),
        step("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE"),
        step('CREATE SCHEMA IF NOT EXISTS "SEMANTIC_SALES"'),
        step('COMMENT ON SCHEMA "SEMANTIC_SALES"'),
        step("CREATE TABLE IF NOT EXISTS " .. discovery),
        step("COMMENT ON TABLE " .. discovery),
        step("DELETE FROM " .. discovery),
        step("VALUES ('MODEL_NAME'"),
        step("VALUES ('MODEL_DESCRIPTION'"),
        step("VALUES ('QUERY_ENTRYPOINT'"),
        step("VALUES ('MCP_GUIDANCE'"),
        step("VALUES ('FIELD_DISCOVERY_QUERY'"),
        step("VALUES ('COMPATIBILITY_QUERY'"),
        step("FROM SYS_SEMANTIC.SEMANTIC_OBJECTS", {{21, "orders", "Orders"}}),
        step("VALUES ('SEMANTIC_OBJECT'"),
        step("VALUES ('SEMANTIC_OBJECT_DESCRIPTION'"),
        step("VALUES ('SEMANTIC_SELECT_EXAMPLE'"),
        step("FROM SYS_SEMANTIC.OBJECT_COLUMNS", column_rows),
    }
end

-- The rest of a successful publish, given the roles granted the model.
local function after_columns(steps, grants)
    for _, tail in ipairs({
        step('CREATE OR REPLACE VIEW "SEMANTIC_SALES"."orders"'),
        step("UPDATE SYS_SEMANTIC.MODELS"),
        step("UPDATE SYS_SEMANTIC.MODEL_VERSIONS"),
        step("SELECT VERSION_NUMBER", {{1}}),
        step("NEXT_PUBLISH_NUMBER", {{1}}),
        step("INSERT INTO SYS_SEMANTIC.MODEL_PUBLISH_HISTORY"),
        step("FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS", grants or {}),
    }) do
        steps[#steps + 1] = tail
    end
    return steps
end

local function view_sql(result)
    for _, call in ipairs(result.calls) do
        if call.sql:find("CREATE OR REPLACE VIEW", 1, true) then return call.sql end
    end
    return ""
end

test_script("refuses an invalid model name", function()
    run({MODEL_NAME = "sales; drop"}, {error = "SEMANTIC_SURFACE_003: invalid MODEL_NAME"})
end)

test_script("refuses a model it cannot find", function()
    run({MODEL_NAME = "sales"}, {sql = {step("FROM SYS_SEMANTIC.MODELS", {})},
        error = "SEMANTIC_SURFACE_010: model not found: sales"})
end)

test_script("refuses a model with no active version", function()
    run({MODEL_NAME = "sales"}, {sql = {
        step("FROM SYS_SEMANTIC.MODELS", {{11, "sales", null, "SEMANTIC_SALES", null}}),
    }, error = "SEMANTIC_SURFACE_011: model has no active version: sales"})
end)

test_script("refuses a model with no published schema", function()
    run({MODEL_NAME = "sales"}, {sql = {
        step("FROM SYS_SEMANTIC.MODELS", {{11, "sales", 12, null, null}}),
    }, error = "SEMANTIC_SURFACE_012: model has no published schema: sales"})
end)

test_script("refuses a semantic object with no visible columns", function()
    run({MODEL_NAME = "sales"}, {sql = through_columns({}),
        error = "SEMANTIC_SURFACE_014: semantic object has no visible columns: orders"})
end)

test_script("refuses a column without a data type", function()
    run({MODEL_NAME = "sales"}, {sql = through_columns({
        {"revenue", "METRIC", " ", 1, null, 1, "NONE"},
    }), error = "SEMANTIC_SURFACE_004: missing data type for column revenue"})
end)

test_script("refuses a data type carrying SQL", function()
    run({MODEL_NAME = "sales"}, {sql = through_columns({
        {"revenue", "METRIC", "INT) AS x FROM DUAL; --", 1, null, 1, "NONE"},
    }), error = "SEMANTIC_SURFACE_005: column revenue declares data type"})
end)

test_script("refuses a data type that is not a plain Exasol type", function()
    run({MODEL_NAME = "sales"}, {sql = through_columns({
        {"revenue", "METRIC", "DECIMAL(18,2) | x", 1, null, 1, "NONE"},
    }), error = "SEMANTIC_SURFACE_005: column revenue declares data type"})
end)

test_script("names a fusion strategy in the column comment", function()
    local result = run({MODEL_NAME = "sales"}, {sql = after_columns(through_columns({
        {"customer_name", "DIMENSION", "VARCHAR(100)", 1, "Customer", 3, "PRIORITY"},
    }))})
    assert_contains(view_sql(result), "Customer Fused across 3 sources (PRIORITY).")
end)

test_script("says a column reads one of several representations", function()
    local result = run({MODEL_NAME = "sales"}, {sql = after_columns(through_columns({
        {"customer_name", "DIMENSION", "VARCHAR(100)", 1, null, 2, "NONE"},
    }))})
    assert_contains(view_sql(result),
        "COMMENT IS 'Read from one of 2 representations of its entity.'")
end)

test_script("cuts a long comment without splitting a character", function()
    -- A four- and a three-byte character, ASCII to 1996 bytes, then a two-,
    -- three- and four-byte character, 2005 bytes in all: the 2000-byte cut
    -- keeps 1997 bytes of content and must not split the two-byte character
    -- that straddles it, so it stops at 1996.
    local description = "𝄞€" .. string.rep("a", 1989) .. "é€𝄞"
    local result = run({MODEL_NAME = "sales"}, {sql = after_columns(through_columns({
        {"revenue", "METRIC", "DECIMAL(18,2)", 1, description, 1, "NONE"},
    }))})
    local comment = view_sql(result):match("\"REVENUE\" COMMENT IS '(.-)'")
    assert_equal(#comment, 1999)
    assert_equal(comment:sub(1, 7), "𝄞€")
    assert_equal(comment:sub(-4), "a...")
end)

test_script("grants the published schema to every role granted the model", function()
    local steps = after_columns(through_columns({
        {"revenue", "METRIC", "DECIMAL(18,2)", 1, "Revenue", 1, "NONE"},
    }), {{"ANALYST"}, {"GONE"}, {""}})
    steps[#steps + 1] = step('GRANT SELECT ON SCHEMA "SEMANTIC_SALES" TO "ANALYST"')
    -- A role dropped from under the catalog does not fail the publish.
    steps[#steps + 1] = {contains = 'TO "GONE"', error = "role GONE not found"}
    local result = run({MODEL_NAME = "sales"}, {sql = steps})
    assert_equal(result.rows[1][5], "PUBLISHED")
end)
