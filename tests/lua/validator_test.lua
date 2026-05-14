-- Milestone 2 validator fixture manifest.
--
-- The executable integration coverage lives in tools/verify_milestone2.py
-- because the validator depends on Exasol's CREATE SCRIPT runtime, query(),
-- null sentinel, and catalog tables. Keep this manifest aligned with that
-- verifier so future Lua test harnesses can reuse the same expectations.

return {
    valid_model = {
        model_name = "sales",
        expected_error_count = 0,
        expected_matrix_rows = 20,
        expected_valid_matrix_rows = 20,
    },
    negative_fixtures = {
        missing_source_object = "SEMANTIC_MODEL_001",
        invalid_metric_dependency = "SEMANTIC_MODEL_011",
        cyclic_metric_dependency = "SEMANTIC_MODEL_012",
        many_to_many_without_fanout = "SEMANTIC_MODEL_010",
        ambiguous_certified_synonym = "SEMANTIC_MODEL_021",
        verified_query_missing_metric = "SEMANTIC_MODEL_023",
    },
}
