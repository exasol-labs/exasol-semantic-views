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

"$PYTHON_BIN" tools/package_lua_scripts.py

"$PYTHON_BIN" tools/run_sql_files.py \
  tools/reset_milestone1.sql \
  sql/install/000_create_schemas.sql \
  sql/install/001_create_semantic_catalog.sql \
  sql/install/002_create_semantic_catalog_views.sql \
  sql/install/003_create_semantic_admin_scripts.sql \
  sql/install/004_create_semantic_preprocessor.sql \
  sql/install/005_create_semantic_surface_helpers.sql \
  sql/install/006_create_semantic_agent_views.sql \
  sql/examples/sales_physical_model.sql \
  sql/examples/sales_model_seed.sql \
  sql/examples/sales_semantic_queries.sql

"$PYTHON_BIN" tools/verify_milestone1.py
"$PYTHON_BIN" tools/verify_milestone2.py
"$PYTHON_BIN" tools/verify_milestone3.py
"$PYTHON_BIN" tools/verify_milestone4.py
"$PYTHON_BIN" tools/verify_milestone5.py

"$PYTHON_BIN" tools/run_sql_files.py \
  sql/examples/sales_materializations.sql

"$PYTHON_BIN" tools/verify_milestone6.py
"$PYTHON_BIN" tools/verify_sql_native_metrics.py
