#!/usr/bin/env sh
set -eu

# pyexasol 3 reports usage on connect; a test run never does.
export EXASOL_TELEMETRY_DISABLE=true

if [ -z "${PYTHON_BIN:-}" ]; then
  if [ -x ../exasol-json-tables/.venv/bin/python ]; then
    PYTHON_BIN="../exasol-json-tables/.venv/bin/python"
  else
    PYTHON_BIN="python3"
  fi
fi
export PYTHONDONTWRITEBYTECODE="${PYTHONDONTWRITEBYTECODE:-1}"

# CI opts in to coverage for every Python process in this live-database lane.
# coverage.py's subprocess patch also measures the legacy verify_*.py tests.
run_python() {
  if [ "${ESV_SYSTEM_COVERAGE:-0}" = "1" ]; then
    "$PYTHON_BIN" -m coverage run --rcfile=tools/coverage-integration.ini "$@"
  else
    "$PYTHON_BIN" "$@"
  fi
}

# Fast database-free runtime tests run first so parser/planner regressions fail
# before the slower clean install and live-DB integration suite.
sh tools/run_lua_tests.sh
run_python tests/unit/test_osi_tool.py
run_python tests/unit/test_sql_splitter.py

# Install the extension and load the base sales model from scratch.
# --reset drops all managed schemas so this is always a clean run.
# --example loads sales_physical_model and sales_model_seed.
# This exercises tools/install.py end-to-end: Lua packaging, schema creation,
# every install SQL file, and the base example SQL files.
run_python tools/install.py --example --reset

# Catalog sanity check: verify the seeded model is visible in SEMANTIC_CATALOG.
run_python tools/run_sql_files.py sql/examples/sales_semantic_queries.sql

# What the installer leaves behind, checked before anything else changes it.
run_python -m pytest tests/integration/fresh_install

run_python tools/run_sql_files.py tests/integration/sql/validation_smoke.sql tests/integration/sql/compile_request_smoke.sql

# Register the pre-built aggregates the materialization tests select from.
run_python tools/run_sql_files.py sql/examples/sales_materializations.sql
run_python tools/run_sql_files.py tests/integration/sql/materialization_smoke.sql

# Cold/warm compiler latency thresholds for verify_runtime_performance.py; they
# are configurable for dedicated large-model CI fixtures, see
# docs/runtime-testing.md.
export PERF_MIN_MODEL_FIELDS="${PERF_MIN_MODEL_FIELDS:-9}"
export PERF_MIN_CARDINALITY="${PERF_MIN_CARDINALITY:-3}"

# The live-database suite: every module in tests/integration, discovered by
# pytest. Each states the invariant it holds in its docstring.
run_python -m pytest tests/integration "$@"
