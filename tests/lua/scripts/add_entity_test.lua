local H = SCRIPT_BODY
local step = H.step
local supported = H.supported
local args = {MODEL_NAME = "sales", ENTITY_NAME = "orders", SOURCE_SCHEMA = "MART",
    SOURCE_OBJECT = "ORDERS", SOURCE_ALIAS = "o"}

test("script body: add_entity writes primary representation", function()
    local fixture = supported({
        step("FROM SYS.EXA_SQL_KEYWORDS", {{0}}, {source_alias = "o"}),
        step("FROM SYS_SEMANTIC.MODELS", {{MODEL_ID = 11, VERSION_ID = 12}}, {model_name = "sales"}),
        step("FROM SYS_SEMANTIC.ENTITIES", {{0}}),
        step("FROM SYS_SEMANTIC.ENTITIES", {{0}}),
        step("INSERT INTO SYS_SEMANTIC.ENTITIES"),
        step("SELECT ENTITY_ID", {{31}}),
        step("FROM SYS.EXA_ALL_VIRTUAL_SCHEMAS", {{1}}, {source_schema = "MART"}),
        step("INSERT INTO SYS_SEMANTIC.ENTITY_REPRESENTATIONS"),
    })
    local result = H.run("add_entity", args, fixture)
    assert_equal(result.calls[8].bindings.source_kind, "VIRTUAL_SCHEMA")
end)

test("script body: add_entity rejects reserved alias", function()
    local refused = supported({step("FROM SYS.EXA_SQL_KEYWORDS", {{1}}, {source_alias = "o"})})
    refused.error = "SEMANTIC_ADMIN_044"
    H.run("add_entity", args, refused)
end)
