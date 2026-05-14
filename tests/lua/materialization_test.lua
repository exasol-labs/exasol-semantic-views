-- Milestone 6 materialization fixture manifest.
--
-- Executable coverage lives in tools/verify_milestone6.py because materialized
-- planning depends on Exasol catalog tables and the installed compiler runtime.

return {
    eligible = {
        revenue_by_region = {
            metrics = {"total_revenue"},
            dimensions = {"customer_region"},
            expected_materialization = "sales_revenue_by_region",
        },
    },
    fallback = {
        missing_dimension = {
            metrics = {"total_revenue"},
            dimensions = {"product_category"},
            expected_materialization = nil,
        },
        non_additive = {
            metrics = {"gross_margin_pct"},
            dimensions = {"customer_region"},
            expected_materialization = nil,
        },
        filtered_dimension_missing = {
            metrics = {"total_revenue"},
            dimensions = {"customer_region"},
            filters = {{field = "order_status", op = "=", value = "COMPLETE"}},
            expected_materialization = nil,
        },
    },
}
