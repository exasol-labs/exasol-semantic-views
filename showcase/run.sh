#!/usr/bin/env sh
# Databricks UCMV on Exasol — one-command showcase. No Python: Docker + exapump only.
#
#   sh showcase/run.sh            # bring up Exasol (nano), install, import, query
#   sh showcase/run.sh --down     # stop the database and remove the temp profile
#
# Runs from the repo root. The Exasol nano image is multi-arch, so this works
# unchanged on Apple Silicon Macs and on x86 Linux.
set -eu

COMPOSE="docker compose -f showcase/docker-compose.yml"
PROFILE="ucmv-showcase"
YAML="sql/examples/sales_databricks_metric_view.yaml"

EXASOL_HOST="${EXASOL_HOST:-localhost}"
EXASOL_PORT="${EXASOL_PORT:-8563}"
EXASOL_USER="${EXASOL_USER:-sys}"
EXASOL_PASSWORD="${EXASOL_PASSWORD:-exasol}"

if [ "${1:-}" = "--down" ]; then
  echo ">>> Tearing down the showcase database"
  $COMPOSE down -v
  exapump profile remove "$PROFILE" >/dev/null 2>&1 || true
  exit 0
fi

command -v exapump >/dev/null 2>&1 || { echo "exapump is required (https://github.com/exasol-labs/exapump)." >&2; exit 1; }
command -v docker  >/dev/null 2>&1 || { echo "docker is required." >&2; exit 1; }

banner() { printf '\n========================================\n>>> %s\n========================================\n' "$1"; }

# exapump splits SQL on ';' only; the install files terminate CREATE SCRIPT blocks
# with a lone '/'. The script bodies contain no bare ';', so turning each lone '/'
# into ';' yields exactly the project's own statement split (tools/run_sql_files.py).
run_sql_file() {
  awk '{ s=$0; sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s); if (s=="/") print ";"; else print $0 }' "$1" \
    | exapump sql -p "$PROFILE"
}

banner "1/6  Starting Exasol (nano) in Docker"
$COMPOSE up -d

banner "2/6  Connecting"
# (Re)create a throwaway exapump profile for this showcase; nano uses a self-signed cert.
exapump profile remove "$PROFILE" >/dev/null 2>&1 || true
exapump profile add "$PROFILE" --host "$EXASOL_HOST" --port "$EXASOL_PORT" \
  --user "$EXASOL_USER" --password "$EXASOL_PASSWORD" --tls true --validate-certificate false >/dev/null

printf 'Waiting for Exasol to accept connections'
i=0
until exapump sql -p "$PROFILE" "SELECT 1" >/dev/null 2>&1; do
  i=$((i+1))
  if [ "$i" -ge 90 ]; then echo " timed out." >&2; exit 1; fi
  printf '.'; sleep 2
done
echo " ready."

banner "3/6  Installing the semantic layer + demo MART data (via exapump)"
for f in \
  sql/install/000_create_schemas.sql \
  sql/install/001_create_semantic_catalog.sql \
  sql/install/002_create_semantic_catalog_views.sql \
  sql/install/003_create_semantic_admin_scripts.sql \
  sql/install/004_create_semantic_preprocessor.sql \
  sql/install/005_create_semantic_surface_helpers.sql \
  sql/install/006_create_semantic_agent_views.sql \
  sql/examples/sales_physical_model.sql \
  sql/examples/sales_model_seed.sql
do
  printf '  %-50s ' "$(basename "$f")"
  run_sql_file "$f" | tail -1
done

banner "4/6  The Databricks metric view we are importing (UCMV YAML)"
cat "$YAML"

banner "5/6  The pure-SQL demo we are about to run (showcase/demo.sql)"
echo "Import (inline YAML) + ENABLE_SEMANTIC_SQL + Databricks-style queries — see showcase/demo.sql."

banner "6/6  Running showcase/demo.sql (one session) — MEASURE / agg / GROUP BY ALL"
exapump sql -p "$PROFILE" -f csv < showcase/demo.sql

cat <<EOF

Done. The model is published at SEMANTIC_SALES_DBX.SALES_DBX.
Try your own queries:  exapump sql -p $PROFILE -f csv -   (then type SQL, end with ';')
First enable the surface in that session:  EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

Tear down with:  sh showcase/run.sh --down
EOF
