-- Milestone 3 compiler fixture manifest.
--
-- Executable coverage lives in tools/verify_milestone3.py because the compiler
-- depends on Exasol query(), CREATE SCRIPT import(), and catalog tables.

return {
    valid_requests = {
        revenue_by_region = {
            metrics = {"total_revenue"},
            dimensions = {"customer_region"},
            expected_status = "OK",
        },
        synonym_resolution = {
            metrics = {"revenue"},
            dimensions = {"region"},
            expected_status = "OK",
        },
        gross_margin_pct = {
            metrics = {"gross_margin_pct"},
            dimensions = {"customer_region"},
            expected_status = "OK",
        },
        completed_revenue = {
            metrics = {"completed_revenue"},
            dimensions = {"product_category"},
            expected_status = "OK",
        },
    },
    negative_fixtures = {
        unknown_field = "SEMANTIC_REQUEST_020",
        limit_too_large = "SEMANTIC_REQUEST_051",
        malformed_json = "SEMANTIC_REQUEST_001",
    },
}
