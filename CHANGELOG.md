# Changelog

All notable changes to Exasol Semantic Views are documented here.

---

## [Unreleased]

### Added

#### Databricks Unity Catalog Metric View compatibility

- **Databricks UCMV import** — added
  `SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW`, which translates a supported
  Databricks metric-view YAML subset into native semantic catalog metadata and
  can optionally apply, validate, and publish the model. Unsupported constructs
  return `DBX_IMPORT_*` diagnostics.
- **Databricks SQL surface compatibility** — semantic SQL now accepts
  `MEASURE(metric)`, the `agg(metric)` synonym, and `GROUP BY ALL` against
  published semantic objects. The wrappers are supported in `SELECT`, `HAVING`,
  and `ORDER BY`; `MEASURE()` of a dimension returns `SEMANTIC_QUERY_006`.
- `tools/import_databricks.py`, `tools/verify_databricks_import.py`,
  `tools/verify_databricks_sql_compat.py`, and
  `sql/examples/sales_databricks_metric_view.yaml` cover host-side file import,
  end-to-end import verification, SQL-surface verification, and a runnable demo
  fixture.

#### Semantic SQL: optional GROUP BY

- **GROUP BY is now optional** — a semantic SQL query that selects dimensions without a `GROUP BY` clause (e.g. `SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES`) now compiles by inferring `GROUP BY` from the selected dimensions, instead of returning `SEMANTIC_QUERY_007`. The emitted SQL is identical to the explicit-`GROUP BY` form (`build_sql` already builds `GROUP BY` from the selected dimensions). When a `GROUP BY` *is* supplied it must still exactly cover the selected dimensions, otherwise `SEMANTIC_QUERY_008` is returned. `SELECT *` and metric-only queries are unaffected. Backward-compatible: previously valid queries still compile unchanged.
- `tools/verify_group_by_inference.py` — focused integration test covering inference, inferred-equals-explicit results, multi-dimension inference, rejection of a non-covering `GROUP BY`, and composition with WHERE/ORDER BY/LIMIT.

#### Semantic SQL: Phase 2 subset improvements

- **HAVING clause** — `HAVING total_revenue > 1000`, `HAVING total_revenue BETWEEN 100 AND 1600`, and multi-predicate `HAVING p1 AND p2` forms are now accepted in semantic SQL. The HAVING clause enforces metric-only predicates; dimension fields in HAVING return `SEMANTIC_QUERY_040`. BETWEEN in HAVING reuses the same `after_between` flag logic as WHERE.
- **`WHERE metric > N` auto-routing** — metric predicates written in the WHERE clause (e.g. `WHERE total_revenue > 0`) are silently routed to HAVING at parse time. Dimension predicates remain in WHERE. Mixed `WHERE dim_filter AND metric_filter` clauses are split correctly.
- **`having` key in `COMPILE_REQUEST_JSON`** — the structured request model now accepts an optional `having` array with the same filter-object shape as `filters`. Each entry must reference a metric field. `COMPILE_REQUEST_SCHEMA_FOR_AGENT` documents the new key.
- **Materialization bypass** — queries with any HAVING predicate skip materialization selection and always use the full physical SQL path (required because materialized column names cannot be referenced in HAVING expressions).
- `tools/verify_semantic_sql_phase2.py` — 93-assertion integration test script covering HAVING, auto-routing, `COMPILE_REQUEST_JSON having`, materialization bypass, preprocessor path, and Phase 1+2 regressions.

#### Semantic SQL: Phase 1 subset improvements

- **ORDER BY ordinals** — `ORDER BY 1 DESC`, `ORDER BY 2, 1 ASC`, and mixed ordinal/name forms are now accepted in semantic SQL. Resolves ordinals against the SELECT list exactly as GROUP BY already did. Out-of-range ordinals return `SEMANTIC_QUERY_060`.
- **BETWEEN in WHERE** — `WHERE order_month BETWEEN '2026-01-01' AND '2026-03-31'` now compiles correctly. The AND-splitting loop in `parse_where_filters` uses an `after_between` flag to distinguish the BETWEEN value separator from a conjunction boundary. Works in any position within a multi-predicate WHERE clause including between other AND-joined predicates. New error codes: `SEMANTIC_QUERY_034` (missing AND separator), `SEMANTIC_QUERY_035` (non-literal values).
- `tools/verify_semantic_sql_phase1.py` — 67-assertion integration test script covering both new features and full regressions.

### Changed

- Databricks UCMV nested join path resolution now registers both absolute and
  relative snowflake paths and binds expressions to the deepest matching join
  entity, so fields such as `customer.nation.n_name` resolve to the nested
  `nation` entity instead of the parent join.
- `lua/semantic_layer/compiler/request_json.lua` — `parse_semantic_sql` no longer requires a `GROUP BY` clause when dimensions are selected; the `GROUP BY` coverage validation now runs only when a `GROUP BY` is supplied (`SEMANTIC_QUERY_007` removed). `tools/verify_milestone4.py` updated to assert the inferred-GROUP BY query now succeeds.
- `lua/semantic_layer/compiler/request_json.lua` — `find_top_level_clauses`, `clause_end`, `build_sql`, `compile_request_table`, and `parse_semantic_sql` updated for Phase 2; `parse_having_filters` added (~95 lines total). `parse_where_filters` and `parse_order_by` updated for Phase 1. Source file is the canonical implementation; `sql/install/003_create_semantic_admin_scripts.sql` is generated by `python3 tools/package_lua_scripts.py`.
- `sql/install/006_create_semantic_agent_views.sql` — `COMPILE_REQUEST_SCHEMA_FOR_AGENT` view updated with `HAVING_KEYS` documentation row.

### Removed

- `skills/exasol-semantic-views-agent/` — replaced by the two focused skills above.

---

## Notes on versioning

This project does not yet have a formal release cadence. Items above are tracked against the development baseline established by the user-study simulations run on 2026-05-13. Phase 1 and Phase 2 are complete. The next planned milestone is Phase 3 (subqueries/CTE rewriting and CAST in SELECT — deferred pending demand).
