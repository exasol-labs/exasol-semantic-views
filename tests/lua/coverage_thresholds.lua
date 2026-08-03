-- Thresholds begin at an honest baseline and are enforced independently so a
-- well-tested small module cannot conceal an untested compiler or validator.
-- Raise a threshold whenever coverage increases; do not lower one to merge.
return {
    lines = {
        ["lua/semantic_layer/shared/grain_graph.lua"] = 80,
        ["lua/semantic_layer/compiler/query_spec.lua"] = 85,
        ["lua/semantic_layer/compiler/catalog_snapshot.lua"] = 85,
        ["lua/semantic_layer/compiler/metric_plan.lua"] = 80,
        ["lua/semantic_layer/compiler/physical_plan.lua"] = 80,
        ["lua/semantic_layer/compiler/grain_sql.lua"] = 90,
        ["lua/semantic_layer/compiler/request_json.lua"] = 79.5,
        ["lua/semantic_layer/admin/validator.lua"] = 92,
        ["lua/semantic_layer/compiler/materializations.lua"] = 91.5,
        ["lua/semantic_layer/admin/semantic_definition.lua"] = 62.5,
        ["lua/semantic_layer/agent/runtime.lua"] = 92.5,
    },
    branches = 100,
}
