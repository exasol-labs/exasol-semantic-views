-- Thresholds begin at an honest baseline and are enforced independently so a
-- well-tested small module cannot conceal an untested compiler or validator.
-- Raise a threshold whenever coverage increases; do not lower one to merge.
--
-- Values are floored to the nearest 0.1 pp below the actual observed
-- percentage so display-rounded floats (e.g. `hit/active × 100` == 70.8986
-- displaying as `70.90`) don't trip the gate on unchanged code. Ratcheted
-- 2026-08-22 after adding cache-key sensitivity + deterministic
-- fixed-length property tests, again after moving path-rejection
-- diagnostics out of the validator into the shared grain graph, and again
-- 2026-08-24 after reporting safe-path alternatives instead of selecting
-- silently between them, again after accepting quoted identifiers and naming
-- which state blocked a metric drop, and again after the fusion-study fixes
-- (plannability gate, request options, unknown-field clarification), and again
-- 2026-08-25 after closing F13/F17/F18 -- the verified-query request scope in
-- the agent runtime, and the metric-grain proof against the object root in the
-- validator -- and again the same day for BUG-G01, which added the
-- partitioned-join-hop refusal to the matrix, the logical planner, and the
-- physical renderer's backstop, and again for BUG-G03, which routed the F5
-- identity mapping columns through the shared resolver and covered the
-- previously untested mapped-base rendering.
--
-- shared/identity_join.lua joined the gate when it was extracted 2026-08-25:
-- one join that had been written out five times, and had already carried one bug
-- in all five. It is fully covered, so the floor is 100.
--
-- shared/source_columns.lua joined the gate with that change. It was loaded and
-- measured but ungated, which is a poor place for a blind spot: both runtimes
-- embed it, and it is the single point where a declared column name becomes the
-- physical one.
return {
    lines = {
        ["lua/semantic_layer/shared/grain_graph.lua"] = 95.6,
        ["lua/semantic_layer/shared/source_columns.lua"] = 92.5,
        ["lua/semantic_layer/shared/identity_join.lua"] = 100,
        ["lua/semantic_layer/compiler/query_spec.lua"] = 96.7,
        ["lua/semantic_layer/compiler/catalog_snapshot.lua"] = 100,
        ["lua/semantic_layer/compiler/metric_plan.lua"] = 94.0,
        ["lua/semantic_layer/compiler/physical_plan.lua"] = 86.3,
        ["lua/semantic_layer/compiler/grain_sql.lua"] = 98.5,
        ["lua/semantic_layer/compiler/request_json.lua"] = 87.1,
        ["lua/semantic_layer/admin/validator.lua"] = 93.5,
        ["lua/semantic_layer/compiler/materializations.lua"] = 92.0,
        ["lua/semantic_layer/admin/semantic_definition.lua"] = 71.7,
        ["lua/semantic_layer/agent/runtime.lua"] = 93.4,
    },
    branches = 100,
}
