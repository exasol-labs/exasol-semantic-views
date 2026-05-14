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

# Phase 2: register pre-built aggregates and verify materialization selection.
"$PYTHON_BIN" tools/run_sql_files.py sql/examples/sales_materializations.sql

"$PYTHON_BIN" tools/verify_milestone6.py
"$PYTHON_BIN" tools/verify_sql_native_metrics.py
