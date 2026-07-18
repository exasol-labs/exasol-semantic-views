-- Thresholds begin at an honest baseline and are enforced independently so a
-- well-tested small module cannot conceal an untested compiler or validator.
-- Raise a threshold whenever coverage increases; do not lower one to merge.
return {
    lines = {
        ["lua/semantic_layer/compiler/request_json.lua"] = 19.5,
        ["lua/semantic_layer/admin/validator.lua"] = 19,
        ["lua/semantic_layer/compiler/materializations.lua"] = 91.5,
        ["lua/semantic_layer/admin/semantic_definition.lua"] = 12.5,
        ["lua/semantic_layer/agent/runtime.lua"] = 20.25,
    },
    branches = 100,
}
