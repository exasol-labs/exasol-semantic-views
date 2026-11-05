local H = SCRIPT_BODY
local step = H.step
test("script body: validate_model reports issues and syncs clean frozen views", function()
    local fixture = {
        imports = {["SEMANTIC_ADMIN.VALIDATOR_RUNTIME"] = {
            validate_model = function(model, metric_types)
                assert_equal(model, "sales")
                assert_equal(type(metric_types), "function")
                return {{severity = "WARNING", object_type = "MODEL", rule_code = "W1", message = "warn"}}
            end,
        }},
        sql = {step("EXECUTE SCRIPT SEMANTIC_ADMIN.SYNC_FROZEN_VIEWS", {
            {"S", "V", "RETIRED", "changed"},
        }, {model_name = "sales"})},
    }
    local result = H.run("validate_model", {MODEL_NAME = "sales"}, fixture)
    assert_equal(result.rows[2][4], "SEMANTIC_MODEL_078")
    assert_contains(result.columns, "RULE_CODE VARCHAR")
end)

test("script body: validate_model skips frozen view sync on errors", function()
    H.run("validate_model", {MODEL_NAME = null}, {imports = {
        ["SEMANTIC_ADMIN.VALIDATOR_RUNTIME"] = {
            validate_model = function() return {{severity = "ERROR", object_type = "MODEL", rule_code = "E1"}} end,
        }},
    })
end)
