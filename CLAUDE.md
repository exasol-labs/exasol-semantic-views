# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A database-native semantic layer for Exasol. All runtime logic runs inside the database as Lua scripts and SQL — no external services, no Python/Java containers. The layer turns business metric definitions into governed SQL that agents, BI tools, and SQL authors can query uniformly.

The installed system creates five schemas in Exasol:
- `SYS_SEMANTIC` — authoritative catalog tables (never write directly; use admin scripts)
- `SEMANTIC_ADMIN` — Lua admin, validation, compile, and agent scripts
- `SEMANTIC_CATALOG` — read-only views for human/tool introspection
- `SEMANTIC_AGENT` — role-scoped discovery views for autonomous agents
- `SEMANTIC_SALES` — published BI-compatible guarded views (one per model)

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

**Run a single milestone verification:**
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

The core runtime lives in four Lua source files:

| Source file | Packaged into | Installed as |
|---|---|---|
| `lua/semantic_layer/compiler/request_json.lua` | `003_create_semantic_admin_scripts.sql` | `SEMANTIC_ADMIN.COMPILER_RUNTIME` |
| `lua/semantic_layer/compiler/materializations.lua` | same | `SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME` |
| `lua/semantic_layer/admin/semantic_definition.lua` | same | `SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME` |
| `lua/semantic_layer/agent/runtime.lua` | `006_create_semantic_agent_views.sql` | `SEMANTIC_ADMIN.AGENT_RUNTIME` |
| `lua/semantic_layer/admin/validator.lua` | `003_create_semantic_admin_scripts.sql` | inline in `VALIDATE_MODEL` |

`package_lua_scripts.py` replaces `-- BEGIN GENERATED … / -- END GENERATED …` marker blocks in the install SQL files. The public TABLE-returning scripts (`COMPILE_REQUEST_JSON`, `COMPILE_SQL`, etc.) are thin wrappers that `import(...)` the runtime library and call one function.

### The Compiler Pipeline

`request_json.lua` is the entire compiler core (~2400 lines). It handles both paths:

```
COMPILE_REQUEST_JSON(json)
  -> compile_internal -> parse_json -> compile_request_table
  -> log_request -> AGENT_REQUEST_LOG

COMPILE_SQL(sql)  /  SQL preprocessor
  -> compile_sql_internal -> parse_semantic_sql -> compile_request_table
```

`compile_request_table` is the shared core: bind semantic names → validate metric/dimension pairs via `METRIC_DIMENSION_MATRIX` → plan join paths → expand metrics (facts → aggregates → derived formulas) → select materialization → emit physical Exasol SQL + PLAN_JSON.

Key functions to know when modifying the compiler:
- `load_catalog` — loads all model metadata from `SYS_SEMANTIC` into a `ctx` table
- `find_path` — graph search for entity join paths (same logic must match `validator.lua:find_path`)
- `expand_metric` — recursive metric dependency resolution
- `build_sql` / `build_materialized_sql` — final SQL generation
- `parse_semantic_sql` — tokenizes and parses the SQL subset for the preprocessor path
- `parse_where_filters` / `parse_having_filters` — WHERE/HAVING clause parsing

### The Validator

`validator.lua` (~1250 lines) runs `VALIDATE_MODEL`. It writes to `SYS_SEMANTIC.VALIDATION_RUNS`, `SYS_SEMANTIC.VALIDATION_RESULTS`, `SYS_SEMANTIC.METRIC_DEPENDENCIES`, and `SYS_SEMANTIC.METRIC_DIMENSION_MATRIX`. The compiler reads `METRIC_DIMENSION_MATRIX` as its compatibility gate.

**Critical invariant:** `validator.lua:find_path` and `compiler:find_path` must use identical join-path logic. If they diverge, `VALID_COMBINATIONS_FOR_AGENT` will report IS_VALID=True for combinations that the compiler rejects at runtime (BUG-003 in `reports/bug-log.md`).

### All SEMANTIC_ADMIN Scripts Are TABLE Scripts

Every `SEMANTIC_ADMIN` script returns a result set. Always call with `EXECUTE SCRIPT`, never `SELECT`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('<json>');
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales');
```

### COMPILE_REQUEST_JSON vs COMPILE_SQL Column Layout

These two scripts return **different** column sets:
- `COMPILE_SQL`: `STATUS, ERROR_CODE, ERROR_MESSAGE, ORIGINAL_SQL, GENERATED_SQL, PLAN_JSON, CLARIFICATION_JSON, VALIDATION_RUN_ID, AGENT_REQUEST_ID` (9 cols)
- `COMPILE_REQUEST_JSON`: same but **without** `ORIGINAL_SQL` (8 cols — GENERATED_SQL is at index 3, not 4)

Python helper pattern to avoid positional indexing bugs:
```python
def sql_string(value): return "'" + value.replace("'", "''") + "'"

rows = conn.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(json.dumps(req))})").fetchall()
row = rows[0]
result = {"status": row[0], "error_code": row[1], "error_message": row[2],
          "generated_sql": row[3], "plan_json": row[4], "agent_request_id": row[7]}
```
`EXECUTE SCRIPT` does not support pyexasol bind parameters (`?` or `{name}`) — escape manually with `sql_string()`.

### SQL Expression Validation: Blocklist, Not Allowlist

Dimension and fact expressions are validated against an explicit **blocklist** of unsupported functions in `validator.lua:unsupported_functions`. Functions not on the blocklist are allowed. This means invalid Exasol functions (e.g. `QUARTER()`, which doesn't exist) pass validation and only fail at SQL execution time. When adding expressions to the model, use only documented Exasol SQL functions.

### The Sales Demo Model

The reference model is in `sql/examples/`. Authoring order matters:
1. `CREATE_MODEL` → `ADD_ENTITY` × N → `ADD_SEMANTIC_OBJECT`
2. `ADD_RELATIONSHIP` × N
3. `ADD_DIMENSION` × N
4. `ADD_FACT` × N → `ADD_METRIC` × N
5. `VALIDATE_MODEL` → `PUBLISH_MODEL`

The preferred authoring surface is SQL-native Semantic DDL via `APPLY_SEMANTIC_DEFINITION`. The positional `ADD_*` scripts are compatibility APIs. See `sql/examples/sales_metrics_semantic_definition.sql` for the DDL syntax.

## Key Files

| File | Purpose |
|---|---|
| `lua/semantic_layer/compiler/request_json.lua` | Entire compiler + preprocessor Lua runtime |
| `lua/semantic_layer/admin/validator.lua` | Model validation, dependency extraction, compatibility matrix |
| `lua/semantic_layer/admin/semantic_definition.lua` | Semantic DDL parser and admin operations |
| `lua/semantic_layer/agent/runtime.lua` | Agent search, glossary, feedback, explain scripts |
| `sql/install/003_create_semantic_admin_scripts.sql` | Generated — wraps compiler + validator Lua into Exasol scripts |
| `sql/install/006_create_semantic_agent_views.sql` | Generated — wraps agent runtime + all SEMANTIC_AGENT views |
| `sql/examples/sales_model_seed.sql` | Reference model definition (canonical example) |
| `tools/package_lua_scripts.py` | Regenerates install SQL from Lua source |
| `tools/install.py` | Full installer: package → connect → reset? → run SQL files |
| `tools/run_nano_smoke.sh` | Full smoke suite |

## Known Issues

Active bugs are tracked in `reports/bug-log.md`. The most important ones affecting development:

- **BUG-002**: `order_quarter` dimension in the demo uses `QUARTER()` which doesn't exist in Exasol — compiles OK, fails at execution.
- **BUG-003**: `VALID_COMBINATIONS_FOR_AGENT` reports IS_VALID=True for some metric/dimension combinations that `COMPILE_REQUEST_JSON` rejects with SEMANTIC_REQUEST_042.
- **BUG-001**: Concurrent `COMPILE_REQUEST_JSON` calls cause transaction collisions (SEMANTIC_REQUEST_999).

## Plans and Docs

- `plans/next-steps-proposal.md` — current roadmap and prioritized work items
- `plans/semantic_layer_design_rationale.md` — full architectural rationale and competitive context
- `docs/creating-metrics.md` — how to define metrics; mental model for entity → fact → metric
- `docs/agent-contract.md` — the agent discovery and compilation contract
- `docs/validation-rules.md` — all SEMANTIC_MODEL_* rule codes
- `docs/semantic-compiler.md` — compiler entrypoints and supported features
- `docs/semantic-sql-preprocessor.md` — preprocessor activation and supported SQL subset
- `reports/` — simulated user study reports and bug log from rounds 2 and 3
