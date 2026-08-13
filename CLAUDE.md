# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A database-native semantic layer for Exasol. All runtime logic runs inside the database as Lua scripts and SQL — no external services, no Python/Java containers. The layer turns business metric definitions into governed SQL that agents, BI tools, and SQL authors can query uniformly.

The installed system creates four managed schemas plus one schema per published
model:
- `SYS_SEMANTIC` — authoritative catalog tables (never write directly; use admin scripts)
- `SEMANTIC_ADMIN` — Lua admin, validation, compile, and agent scripts
- `SEMANTIC_CATALOG` — read-only views for human/tool introspection
- `SEMANTIC_AGENT` — role-scoped discovery views for autonomous agents
- `SEMANTIC_<MODEL>` — published BI-compatible guarded views

## Essential Commands

**Install onto a running Nano instance (full clean install with demo data):**
```sh
python3 tools/install.py --example --reset
```

**Install without wiping existing data:**
```sh
python3 tools/install.py --example
```

**Run the full smoke-test suite** (requires Nano running at localhost:8563):
```sh
sh tools/run_nano_smoke.sh
```

**Run database-free Lua runtime tests with coverage:**
```sh
sh tools/run_lua_tests.sh
```

**Run the live cold/warm and scale probe** (requires an installed model):
```sh
python3 tools/verify_runtime_performance.py
```

**Run a focused verification:**
```sh
python3 tools/verify_milestone3.py   # structured request compiler
python3 tools/verify_milestone6.py   # materialization selection
python3 tools/verify_semantic_sql_phase1.py   # ORDER BY ordinals, BETWEEN
python3 tools/verify_semantic_sql_phase2.py   # HAVING, metric WHERE predicates
```

**After editing any Lua source file, regenerate the install SQL before testing:**
```sh
python3 tools/package_lua_scripts.py
```
This is mandatory — the install SQL files contain embedded Lua. The source files under `lua/` are canonical; `sql/install/003_create_semantic_admin_scripts.sql` and `sql/install/006_create_semantic_agent_views.sql` are generated. Never edit the generated SQL directly.

**Connection defaults** (all tools read these env vars):
```sh
EXASOL_HOST=localhost EXASOL_PORT=8563 EXASOL_USER=sys EXASOL_PASSWORD=exasol
```
Nano uses a self-signed TLS cert; all tools disable cert verification by default for local use.

## Architecture

### The Lua Source → Install SQL Pipeline

The runtime is split into focused Lua modules:

| Source file | Packaged into | Installed as |
|---|---|---|
| `lua/semantic_layer/compiler/request_json.lua` | `003_create_semantic_admin_scripts.sql` | `SEMANTIC_ADMIN.COMPILER_RUNTIME` |
| `lua/semantic_layer/compiler/query_spec.lua` | same | imported compiler module |
| `lua/semantic_layer/compiler/catalog_snapshot.lua` | same | imported compiler module |
| `lua/semantic_layer/compiler/metric_plan.lua` | same | imported compiler module |
| `lua/semantic_layer/compiler/physical_plan.lua` | same | imported compiler module |
| `lua/semantic_layer/compiler/grain_sql.lua` | same | imported compiler module |
| `lua/semantic_layer/compiler/materializations.lua` | same | `SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME` |
| `lua/semantic_layer/shared/grain_graph.lua` | same | shared validator/compiler module |
| `lua/semantic_layer/admin/semantic_definition.lua` | same | `SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME` |
| `lua/semantic_layer/agent/runtime.lua` | `006_create_semantic_agent_views.sql` | `SEMANTIC_ADMIN.AGENT_RUNTIME` |
| `lua/semantic_layer/admin/validator.lua` | `003_create_semantic_admin_scripts.sql` | inline in `VALIDATE_MODEL` |

`package_lua_scripts.py` replaces `-- BEGIN GENERATED … / -- END GENERATED …` marker blocks in the install SQL files. The public TABLE-returning scripts (`COMPILE_REQUEST_JSON`, `COMPILE_SQL`, etc.) are thin wrappers that `import(...)` the runtime library and call one function.

### The Compiler Pipeline

`request_json.lua` orchestrates both public input paths:

```
JSON / Semantic SQL
  -> QuerySpec
  -> model-versioned CatalogSnapshot
  -> typed MetricPlan with grain proofs
  -> PhysicalPlan with representations, fusion, and materializations
  -> decision-free SQL rendering
  -> response envelope, cache, and optional logging
```

Both paths share the same canonical request and planner. Do not add semantic
decisions to the SQL renderer or implement a feature in only one input lane.

Key functions to know when modifying the compiler:
- `query_spec.lua` — closed request schema and normalization
- `catalog_snapshot.lua` — detached planner catalog and private dependencies
- `metric_plan.lua` — metric DAG, branch requirements, and strict grain proofs
- `physical_plan.lua` — aggregate states, representation partitions, and fusion
- `grain_sql.lua` — rendering after decisions are complete
- `materializations.lua` — complete-source matching and rejection provenance
- `request_json.lua` — parsing, orchestration, caching, logging, and envelopes

### The Validator

`validator.lua` runs `VALIDATE_MODEL`. It writes to `SYS_SEMANTIC.VALIDATION_RUNS`, `SYS_SEMANTIC.VALIDATION_RESULTS`, `SYS_SEMANTIC.METRIC_DEPENDENCIES`, and `SYS_SEMANTIC.METRIC_DIMENSION_MATRIX`. The compiler reads the latest successful run and compatibility metadata instead of validating during compilation.

**Critical invariant:** validator and compiler relationship proofs must delegate
to `lua/semantic_layer/shared/grain_graph.lua`. Do not reimplement path safety,
key matching, ambiguity, or identity remapping in one runtime only.

Every active entity has exactly one active `PRIMARY` representation. Alternates
must satisfy validation contracts for keys, bindings, coverage, fusion, and
identity. Compilation may choose an alternate through explicit binding policy,
temporal partitioning, or reconciliation; every choice is recorded in plan
provenance.

### Call SEMANTIC_ADMIN Scripts with EXECUTE SCRIPT

Always call `SEMANTIC_ADMIN` scripts with `EXECUTE SCRIPT`, never `SELECT`.
Many scripts return a result set, but some mutation scripts, including
`ADD_ENTITY`, `ADD_SEMANTIC_OBJECT`, and `ADD_RELATIONSHIP`, complete without
returning rows:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('<json>');
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales');
```

### COMPILE_REQUEST_JSON and COMPILE_SQL Column Layout

Both scripts return the **identical 9-column** result set:

`STATUS, ERROR_CODE, ERROR_MESSAGE, ORIGINAL_SQL, GENERATED_SQL, PLAN_JSON, CLARIFICATION_JSON, VALIDATION_RUN_ID, AGENT_REQUEST_ID`

`GENERATED_SQL` is at **index 4** for both. For `COMPILE_REQUEST_JSON` there is no original SQL string, so `ORIGINAL_SQL` (index 3) is always `NULL` — but the column is still present, so positional indices line up with `COMPILE_SQL`.

Python helper pattern to avoid positional indexing bugs (matches `tools/semantic_client.py`):
```python
def sql_string(value): return "'" + value.replace("'", "''") + "'"

rows = conn.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(json.dumps(req))})").fetchall()
row = rows[0]
result = {"status": row[0], "error_code": row[1], "error_message": row[2],
          "original_sql": row[3], "generated_sql": row[4], "plan_json": row[5],
          "clarification_json": row[6], "validation_run_id": row[7], "agent_request_id": row[8]}
```
`EXECUTE SCRIPT` does not support pyexasol bind parameters (`?` or `{name}`) — escape manually with `sql_string()`.

### SQL Expression Validation: Static Policy, Not SQL Compilation

Dimension, fact, binding, filter, and identity expressions are checked for alias
scope, source columns, and unsupported functions. The validator does not parse
or compile every complete Exasol expression. Invalid dialect syntax can pass
static validation and fail at execution time. Smoke-test each physical
expression against its owning source relation before registering or certifying
it.

### The Sales Demo Model

The reference model is in `sql/examples/`. Authoring order matters:
1. `CREATE_MODEL` -> `ADD_ENTITY` x N -> `ADD_SEMANTIC_OBJECT`
2. `ADD_UNIQUE_KEY_WITH_COLUMNS` -> `ADD_RELATIONSHIP` -> `ADD_RELATIONSHIP_KEY_MAPPING`
3. `ADD_DIMENSION` -> `ADD_FACT` -> `ADD_METRIC`
4. Optional representations, bindings, coverage, authority, and identity through complete or compound declarations
5. `VALIDATE_MODEL` -> `PUBLISH_MODEL`

The preferred authoring surface is SQL-native Semantic DDL via `APPLY_SEMANTIC_DEFINITION`. The positional `ADD_*` scripts are compatibility APIs. See `sql/examples/sales_metrics_semantic_definition.sql` for the DDL syntax.

## Key Files

| File | Purpose |
|---|---|
| `lua/semantic_layer/compiler/` | Request, catalog, logical plan, physical plan, materialization, and SQL-rendering modules |
| `lua/semantic_layer/shared/grain_graph.lua` | Shared relationship, key, and identity proof logic |
| `lua/semantic_layer/admin/validator.lua` | Model validation, dependency extraction, compatibility matrix |
| `lua/semantic_layer/admin/semantic_definition.lua` | Semantic DDL parser and admin operations |
| `lua/semantic_layer/agent/runtime.lua` | Agent search, glossary, feedback, explain scripts |
| `sql/install/003_create_semantic_admin_scripts.sql` | Generated — wraps compiler + validator Lua into Exasol scripts |
| `sql/install/006_create_semantic_agent_views.sql` | Generated — wraps agent runtime + all SEMANTIC_AGENT views |
| `sql/examples/sales_model_seed.sql` | Reference model definition (canonical example) |
| `tools/package_lua_scripts.py` | Regenerates install SQL from Lua source |
| `tools/install.py` | Full installer: package → connect → reset? → run SQL files |
| `tools/import_databricks.py` | Host helper: reads a Databricks UCMV YAML file and calls the in-DB importer |
| `tools/run_nano_smoke.sh` | Full smoke suite |

The Databricks UCMV importer (`SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW`) and its YAML parser/translator live in `semantic_definition.lua`; the MEASURE()/`GROUP BY ALL` query surface lives in `request_json.lua`. See `docs/databricks-metric-views.md`.

## Known Issues

Known issues and their current status are tracked in the checked-in `docs/known-issues.md`. As of the last verification against Exasol 2026.1.0, the historical BUG-001/002/003 do **not** reproduce on a clean install — see that doc for details before assuming any of them is still live.

## Documentation

- `docs/creating-metrics.md` — how to define metrics; mental model for entity → fact → metric
- `docs/agent-contract.md` — the agent discovery and compilation contract
- `docs/validation-rules.md` — all SEMANTIC_MODEL_* rule codes
- `docs/semantic-compiler.md` — compiler entrypoints and supported features
- `docs/semantic-sql-preprocessor.md` — preprocessor activation and supported SQL subset
- `docs/known-issues.md` — known issues with verified status per Exasol version
- `docs/databricks-metric-views.md` — Databricks UCMV import + MEASURE()/GROUP BY ALL SQL compatibility
- `docs/architecture.md` — standalone design rationale and code map
- `docs/semantic-catalog.md` — catalog and lifecycle surfaces
