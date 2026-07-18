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
# before the slower clean install and Nano integration suite.
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
"$PYTHON_BIN" tools/verify_milestone1.py
"$PYTHON_BIN" tools/verify_milestone2.py
"$PYTHON_BIN" tools/verify_milestone3.py
"$PYTHON_BIN" tools/verify_milestone4.py
"$PYTHON_BIN" tools/verify_milestone5.py
"$PYTHON_BIN" tools/verify_semantic_sql_phase1.py
"$PYTHON_BIN" tools/verify_group_by_inference.py
"$PYTHON_BIN" tools/run_sql_files.py tests/sql/validation_smoke.sql tests/sql/compile_request_smoke.sql

# Phase 2: register pre-built aggregates and verify materialization selection.
"$PYTHON_BIN" tools/run_sql_files.py sql/examples/sales_materializations.sql

"$PYTHON_BIN" tools/verify_milestone6.py
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
