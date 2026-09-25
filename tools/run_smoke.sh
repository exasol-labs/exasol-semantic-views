#!/usr/bin/env sh
set -eu

if [ -z "${PYTHON_BIN:-}" ]; then
  if [ -x ../exasol-json-tables/.venv/bin/python ]; then
    PYTHON_BIN="../exasol-json-tables/.venv/bin/python"
  else
    PYTHON_BIN="python3"
  fi
fi
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

# Fast database-free runtime tests run first so parser/planner regressions fail
# before the slower clean install and live-DB integration suite.
sh tools/run_lua_tests.sh
"$PYTHON_BIN" tests/test_osi_tool.py
"$PYTHON_BIN" tests/test_sql_splitter.py

# Phase 1: install the extension and load the base sales model from scratch.
# --reset drops all managed schemas so this is always a clean run.
# --example loads sales_physical_model and sales_model_seed.
# This exercises tools/install.py end-to-end: Lua packaging, schema creation,
# all 7 install SQL files, and the 2 base example SQL files.
"$PYTHON_BIN" tools/install.py --example --reset

# Catalog sanity check: verify the seeded model is visible in SEMANTIC_CATALOG.
"$PYTHON_BIN" tools/run_sql_files.py sql/examples/sales_semantic_queries.sql

# Milestone verification (before materializations, so the compiler uses base SQL).
"$PYTHON_BIN" tools/verify_catalog_and_seed.py
"$PYTHON_BIN" tools/verify_model_validation.py
"$PYTHON_BIN" tools/verify_structured_request_compiler.py
"$PYTHON_BIN" tools/verify_sql_compiler_and_surfaces.py
"$PYTHON_BIN" tools/verify_agent_context_and_feedback.py
"$PYTHON_BIN" tools/verify_source_trust.py
"$PYTHON_BIN" tools/verify_sql_result_contract.py
"$PYTHON_BIN" tools/verify_cache_integrity.py
"$PYTHON_BIN" tools/verify_effective_principal.py
"$PYTHON_BIN" tools/verify_semantic_sql_phase1.py
"$PYTHON_BIN" tools/verify_reference_expansion.py
"$PYTHON_BIN" tools/verify_sql_lane_parity.py
"$PYTHON_BIN" tools/verify_no_raw_parse_errors.py
"$PYTHON_BIN" tools/verify_sql_lane_logging.py
"$PYTHON_BIN" tools/verify_frozen_views.py
"$PYTHON_BIN" tools/verify_policy_columns.py
"$PYTHON_BIN" tools/verify_field_policy_writer.py
"$PYTHON_BIN" tools/verify_remove_semantic_object.py
"$PYTHON_BIN" tools/verify_published_repair_path.py
"$PYTHON_BIN" tools/verify_bi_privileges.py
"$PYTHON_BIN" tools/verify_representation_promotion.py
"$PYTHON_BIN" tools/verify_governance_surfacing.py
"$PYTHON_BIN" tools/verify_query_capabilities_contract.py
"$PYTHON_BIN" tools/verify_documented_examples.py
"$PYTHON_BIN" tools/verify_database_wide_activation.py
"$PYTHON_BIN" tools/verify_governed_mode_refuses.py
"$PYTHON_BIN" tools/verify_catalog_scoping.py
"$PYTHON_BIN" tools/verify_group_by_inference.py
"$PYTHON_BIN" tools/run_sql_files.py tests/sql/validation_smoke.sql tests/sql/compile_request_smoke.sql

# Fan-out guardrails on the shipped demo model: order-grain freight groups
# correctly along safe edges, and the same metric is refused at authoring time
# in the line-grain SALES object (SEMANTIC_MODEL_030). Doubles as the runnable
# demonstration of the property the model is built around.
"$PYTHON_BIN" tools/verify_fanout_guardrails.py

# Many-to-many refusal (found while extending the demo model): a MANY_TO_MANY
# relationship with any non-empty FANOUT_POLICY used to compile to a flat join
# with no de-duplication, double counting a measure whose row matched several
# partners. Builds a disposable fanning model and asserts both refusal lanes.
"$PYTHON_BIN" tools/verify_many_to_many_refusal.py

# Catalog introspection: 40+ views with unguessable column names, and three
# compile entrypoints whose ninth column is not the same. Asserts
# CATALOG_COLUMNS against EXA_ALL_COLUMNS and the published compile-result
# contract against each script's live result set, which is the drift that
# already shipped a wrong column layout once.
"$PYTHON_BIN" tools/verify_catalog_introspection.py

# The two numbers the README quotes for data fusion: a re-loaded boundary day
# double-counted by a hand-rolled union, and revenue stranded in a NULL bucket
# that reconciliation recovers. Computed and asserted so the README cannot drift.
"$PYTHON_BIN" tools/verify_fusion_value.py

# Metric plannability gate: COUNT(*) and AVG-on-a-partition used to validate,
# publish, and be reported ready, then fail only when queried -- poisoning
# SELECT * for the whole object. Asserts the definition-time refusals, that the
# supported row-count forms and single-branch AVG still work, and that
# partitioning an entity under a non-mergeable metric is caught.
"$PYTHON_BIN" tools/verify_metric_plannability.py

# Fusion governance: SET_ATTRIBUTE_FUSION_POLICY and SET_REPRESENTATION_AUTHORITY
# were not prospectively validated, so one call could take a published model
# offline for every consumer. Asserts refuse-and-restore on published models,
# that satisfiable fact reconciliation is still accepted and exact, and that an
# incomplete alternate representation now names its own recovery.
"$PYTHON_BIN" tools/verify_fusion_governance.py

# Path ambiguity: a tie between safe paths is refused, but an alternative of a
# different length used to lose silently — shortest wins, warnings: []. Asserts
# the authoring warning, the plan warning, the strict-mode refusal, and that the
# fixture's two paths still disagree about the answer.
"$PYTHON_BIN" tools/verify_path_ambiguity.py

# SET_RELATIONSHIP: relationships were add-only, so correcting a cardinality or
# fanout policy meant remove-mappings/remove/add/re-add. Asserts in-place edit,
# surviving key mappings, the closed policy set, and published rollback.
"$PYTHON_BIN" tools/verify_set_relationship.py

# Grain-aware D1 baseline: build an isolated three-fact model, compare both
# compiler input lanes with independently aggregated reference SQL, exercise
# sparse/orphan/filter/grand-total behavior, and report one/two/three-branch
# planner measurements before D2 materialization substitution.
"$PYTHON_BIN" tools/verify_grain_phase_c3.py

# Phase 2: register pre-built aggregates and verify materialization selection.
"$PYTHON_BIN" tools/run_sql_files.py sql/examples/sales_materializations.sql

"$PYTHON_BIN" tools/verify_materialization_selection.py
"$PYTHON_BIN" tools/verify_sql_native_metrics.py
"$PYTHON_BIN" tools/verify_semantic_sql_phase2.py
"$PYTHON_BIN" tools/run_sql_files.py tests/sql/materialization_smoke.sql
"$PYTHON_BIN" tools/verify_security_principals.py

# Concurrent-compile regression (BUG-001): every COMPILE_REQUEST_JSON used to
# re-run the full validator, causing GlobalTransactionRollback collisions for
# concurrent callers. Asserts every compile in a 6×8 grid returns STATUS=OK.
"$PYTHON_BIN" tools/verify_concurrent_compile.py

# Cold/warm compiler latency, broadest visible request, and dimension
# cardinality/execution probes. Thresholds are configurable for dedicated
# large-model CI fixtures; see docs/runtime-testing.md.
export PERF_MIN_MODEL_FIELDS="${PERF_MIN_MODEL_FIELDS:-9}"
export PERF_MIN_CARDINALITY="${PERF_MIN_CARDINALITY:-3}"
"$PYTHON_BIN" tools/verify_runtime_performance.py

# Server-side compile cache (BUG-D-002): identical repeat requests should hit
# the cache, be flagged CACHE_HIT in AGENT_REQUEST_LOG, and be invalidated by
# PUBLISH_MODEL and SET_MATERIALIZATION_STATUS.
"$PYTHON_BIN" tools/verify_compile_cache.py

# Dimension-only discovery (BUG-D-003): metrics-less requests should compile to
# a deduplicated GROUP BY so dashboards can populate facet filters without
# faking an unused metric.
"$PYTHON_BIN" tools/verify_dimension_discovery.py

# OSI export (Milestone 2): validate live catalog export, lossless extensions,
# simple key mapping, and offline OSI schema validation.
"$PYTHON_BIN" tools/verify_osi_export.py

# OSI import apply (Milestone 4): apply a live lossless export into a draft
# model, validate it, compile against it, and verify collision preflight.
"$PYTHON_BIN" tools/verify_osi_import.py

# OSI normalized batch import (Milestone 5): apply the normalized plan through
# one database helper and verify returned rows plus lossless metadata patches.
"$PYTHON_BIN" tools/verify_osi_batch_import.py

# OSI lossless round-trip (Milestone 6): export/import/export through batch
# apply, compare normalized OSI and catalog snapshots, and verify rollback.
"$PYTHON_BIN" tools/verify_osi_roundtrip.py

# Databricks UCMV SQL-surface compatibility: MEASURE()/agg() wrappers,
# GROUP BY ALL, and MEASURE() in HAVING/ORDER BY against a published object.
"$PYTHON_BIN" tools/verify_databricks_sql_compat.py

# Databricks UCMV import: translate a metric-view YAML over the demo MART
# tables into native semantic DDL, apply it, and query the imported model.
"$PYTHON_BIN" tools/verify_databricks_import.py

# Extended coverage: verify scripts previously invoked only manually. All exit
# with 0 against the accumulated post-smoke state; adding them here surfaces
# drift that used to sit unnoticed between releases.
"$PYTHON_BIN" tools/verify_grain_phase_b.py
"$PYTHON_BIN" tools/verify_json_table_relationship_mapping.py

# Fusion feature suite (F3/F4/F5/F5.1/F7).
"$PYTHON_BIN" tools/verify_fusion_f3.py
"$PYTHON_BIN" tools/verify_fusion_f4.py
"$PYTHON_BIN" tools/verify_fusion_f5.py
"$PYTHON_BIN" tools/verify_fusion_declaration.py
"$PYTHON_BIN" tools/verify_fusion_f51.py
"$PYTHON_BIN" tools/verify_fusion_f7.py

# Open findings from the fusion evaluations, each closed and pinned here.
# F18 is the structural one: the earlier suites only ever placed a metric's
# facts *on* the object root, which is the position that works. The other three
# positions had no test, and one of them returned a silently inflated number.
"$PYTHON_BIN" tools/verify_verified_query_scope.py
"$PYTHON_BIN" tools/verify_metric_grain_positions.py
"$PYTHON_BIN" tools/verify_partitioned_join_hop.py
"$PYTHON_BIN" tools/verify_named_admin_api.py
"$PYTHON_BIN" tools/verify_identity_binding_diagnostic.py

# Feedback-driven behavior tests.
"$PYTHON_BIN" tools/verify_replace_attribute_binding.py
"$PYTHON_BIN" tools/verify_agent_session_instructions.py
"$PYTHON_BIN" tools/verify_query_timeout_precondition.py

# Historical bug regressions: each script isolates a specific past failure and
# reasserts the fixed behavior. Running them here is cheap insurance.
"$PYTHON_BIN" tools/verify_published_authoring_isolation.py

# BUG-23: a dimension expression carrying a bare reserved word validated,
# published and compiled to STATUS = OK, then failed at execution. Asserts
# SEMANTIC_MODEL_072 refuses it at ADD_DIMENSION, in the semantic DDL, and in
# VALIDATE_MODEL for a catalog that already holds one.
"$PYTHON_BIN" tools/verify_expression_binding.py

# BUG-25: an unknown DDL clause was absorbed into the previous clause's value, so
# `RETURNS DECIMAL(18,2) UNIT 'kg'` stored that as the type and validated clean.
# Asserts it is refused by name, UNIT is a real metric clause, and a malformed
# declared type fails ADD_METRIC and VALIDATE_MODEL (SEMANTIC_MODEL_073).
"$PYTHON_BIN" tools/verify_semantic_ddl_clauses.py

# BUG-26: an outer AVG over a per-group average weighted every group equally and
# answered 47.5 % high with STATUS = OK. Asserts SEMANTIC_QUERY_016 refuses the
# inexact shapes, the exact ones still return the metric's own value, and
# SET_MODEL_DERIVED_COMPOSITION opts out.
"$PYTHON_BIN" tools/verify_outer_reaggregation.py

# A dimension only filtered on joined the grain, so wrapping a statement (or
# expansion serving it bare) returned one row per value. Asserts wrapped equals
# bare, SEMANTIC_QUERY_017 where the filter cannot run first, and that filters
# on selected dimensions are untouched.
"$PYTHON_BIN" tools/verify_filter_grain.py

# BUG-27: the materialization registry held a free-text refresh intent and no
# state, so it could not say whether a materialization was stale. Asserts the
# policy is validated, MARK_MATERIALIZATION_REFRESHED records measured state,
# a stale MAX_AGE materialization falls back to live sources, and a compile
# that chose a time-bounded one is not cached. Order-dependent: needs the
# example's sales_revenue_by_region, loaded earlier.
"$PYTHON_BIN" tools/verify_materialization_freshness.py
"$PYTHON_BIN" tools/verify_promotion_gate.py
"$PYTHON_BIN" tools/verify_published_mutation_protection.py
"$PYTHON_BIN" tools/verify_published_f3_batch.py
"$PYTHON_BIN" tools/verify_published_multistep_declarations.py
"$PYTHON_BIN" tools/verify_composite_removal_and_recertification.py
"$PYTHON_BIN" tools/verify_published_identity_setup.py
"$PYTHON_BIN" tools/verify_representation_with_identity.py
"$PYTHON_BIN" tools/verify_relationship_types_and_removal.py
"$PYTHON_BIN" tools/verify_attribute_with_bindings.py

# Live-DB negative-path coverage for SEMANTIC_ADMIN_* / SEMANTIC_SURFACE_*
# error codes that the emitter grep found were untested. Cheap: every case is
# a parameter-validation or duplicate check that fails before touching state.
"$PYTHON_BIN" tools/verify_admin_error_codes.py

# Concurrent-admin regression net (BUG-D-004): runs a small grid of admin
# operations from several threads and asserts that (a) every refusal is a
# well-formed SEMANTIC_*_NNN or Exasol GlobalTransactionRollback, never an
# opaque error; (b) post-storm compile still returns OK; (c) no validation
# run is left in RUNNING; (d) no half-created race objects survive.
"$PYTHON_BIN" tools/verify_concurrent_admin.py

# Claude study bug-reproduction classifier. Reports on historical study
# findings and is safe to run last (uses zz_repro_* namespaces).
"$PYTHON_BIN" tools/verify_claude_study_issues.py

# NOTE: The compiler fuzzer (tools/fuzz_semantic_differential.py) is NOT part
# of this per-check gate — a wide campaign is minutes-long and grows with
# every seed. Run tools/run_release_gate.sh (which invokes this script and
# then a larger fuzz campaign) before every major release. See docs.
