-- Thresholds begin at an honest baseline and are enforced independently so a
-- well-tested small module cannot conceal an untested compiler or validator.
-- Raise a threshold whenever coverage increases; do not lower one to merge.
--
-- Values are floored to the nearest 0.1 pp below the actual observed
-- percentage so display-rounded floats (e.g. `hit/active × 100` == 70.8986
-- displaying as `70.90`) don't trip the gate on unchanged code. Ratcheted
-- 2026-08-22 after adding cache-key sensitivity + deterministic
-- fixed-length property tests, and again after moving path-rejection
-- diagnostics out of the validator into the shared grain graph.
return {
    lines = {
        ["lua/semantic_layer/shared/grain_graph.lua"] = 95.0,
        ["lua/semantic_layer/compiler/query_spec.lua"] = 96.5,
        ["lua/semantic_layer/compiler/catalog_snapshot.lua"] = 100,
        ["lua/semantic_layer/compiler/metric_plan.lua"] = 91.7,
        ["lua/semantic_layer/compiler/physical_plan.lua"] = 86.2,
        ["lua/semantic_layer/compiler/grain_sql.lua"] = 98.5,
        ["lua/semantic_layer/compiler/request_json.lua"] = 86.0,
        ["lua/semantic_layer/admin/validator.lua"] = 93.0,
        ["lua/semantic_layer/compiler/materializations.lua"] = 92.0,
        ["lua/semantic_layer/admin/semantic_definition.lua"] = 70.8,
        ["lua/semantic_layer/agent/runtime.lua"] = 92.8,
    },
    branches = 100,
}
