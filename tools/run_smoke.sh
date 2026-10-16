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

# Install the extension and load the base sales model from scratch.
# --reset drops all managed schemas so this is always a clean run.
# --example loads sales_physical_model and sales_model_seed.
# This exercises tools/install.py end-to-end: Lua packaging, schema creation,
# every install SQL file, and the base example SQL files.
"$PYTHON_BIN" tools/install.py --example --reset

# Catalog sanity check: verify the seeded model is visible in SEMANTIC_CATALOG.
"$PYTHON_BIN" tools/run_sql_files.py sql/examples/sales_semantic_queries.sql

# What the installer leaves behind, checked before anything else changes it.
"$PYTHON_BIN" -m pytest tests/integration/fresh_install

"$PYTHON_BIN" tools/run_sql_files.py tests/sql/validation_smoke.sql tests/sql/compile_request_smoke.sql

# Register the pre-built aggregates the materialization tests select from.
"$PYTHON_BIN" tools/run_sql_files.py sql/examples/sales_materializations.sql
"$PYTHON_BIN" tools/run_sql_files.py tests/sql/materialization_smoke.sql

# Cold/warm compiler latency thresholds for verify_runtime_performance.py; they
# are configurable for dedicated large-model CI fixtures, see
# docs/runtime-testing.md.
export PERF_MIN_MODEL_FIELDS="${PERF_MIN_MODEL_FIELDS:-9}"
export PERF_MIN_CARDINALITY="${PERF_MIN_CARDINALITY:-3}"

# The live-database suite: every module in tests/integration, discovered by
# pytest. Each states the invariant it holds in its docstring.
"$PYTHON_BIN" -m pytest tests/integration "$@"
