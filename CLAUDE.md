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

**Provision a local Exasol Personal deployment** (one-time; requires the `exasol` CLI from https://github.com/exasol/exasol-personal):
```sh
exasol install local -d dev            # creates ~/.exasol/personal/deployments/dev
```
The deployment picks a random TCP port. Read it back with
`cat ~/.exasol/personal/deployments/dev/deployment.json | jq -r .connection.dbPort`
and export it via `EXASOL_PORT` (see connection defaults below). To run more
than one deployment side-by-side, pass a different `-d <name>` to `install`.

**Install onto the deployment (full clean install with demo data):**
```sh
python3 tools/install.py --example --reset
```

**Install without wiping existing data:**
```sh
python3 tools/install.py --example
```

**Run the full smoke-test suite** (requires an Exasol Personal deployment reachable via `$EXASOL_HOST:$EXASOL_PORT`):
```sh
sh tools/run_smoke.sh
```

**Run the release gate before major releases** (smoke + wide fuzz campaign, minutes long):
```sh
sh tools/run_release_gate.sh
```
This is deliberately NOT part of `run_smoke.sh` — a full fuzz campaign is
too slow to run on every check. The release gate wraps the smoke suite and adds
`tools/fuzz_semantic_differential.py` under both oracles (`differential` and
`tlp`) across multiple seeds. Override cadence with `FUZZ_SEEDS` and `FUZZ_CASES`.

**Run database-free Lua runtime tests with coverage:**
```sh
sh tools/run_lua_tests.sh
```

**Run database-free Python tests with coverage:**
```sh
sh tools/run_python_tests.sh
```
Enforces per-file thresholds from `tests/python_coverage_thresholds.py` and
runs the property-based tests in `tests/test_property.py`. Same ratcheting
discipline as the Lua coverage gate: raise a threshold whenever coverage
grows; do not lower one to merge.

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
Exasol Personal deployments use self-signed TLS certs; all tools disable cert verification by default for local use.

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

`COMPILE_REQUEST_JSON` and `COMPILE_SQL` return the **identical 9-column** result set:

`STATUS, ERROR_CODE, ERROR_MESSAGE, ORIGINAL_SQL, GENERATED_SQL, PLAN_JSON, CLARIFICATION_JSON, VALIDATION_RUN_ID, AGENT_REQUEST_ID`

For `COMPILE_REQUEST_JSON` there is no original SQL string, so `ORIGINAL_SQL` is
always `NULL` — but the column is still present, so positional indices line up
with `COMPILE_SQL`. `COMPILE_SQL_DEBUG` shares the first eight columns and ends
with **`QUERY_LOG_ID`**, not `AGENT_REQUEST_ID`.

**Read the result set by column name, not by index.** `EXECUTE SCRIPT` result
sets are named — the `RETURNS TABLE` declaration carries the names over the
wire — so no consumer needs to know where `GENERATED_SQL` sits. This is the
pattern `tools/semantic_client.py` uses:

```python
def sql_string(value): return "'" + value.replace("'", "''") + "'"

statement = conn.execute(
    f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(json.dumps(req))})")
names = [name.lower() for name in statement.columns().keys()]
result = dict(zip(names, statement.fetchone()))
generated_sql = result["generated_sql"]
```

The contract is also queryable, so nothing has to trust a doc that can rot:

```sql
SELECT ORDINAL_POSITION, COLUMN_NAME, NULL_WHEN, DESCRIPTION
FROM SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT
WHERE SCRIPT_NAME = 'COMPILE_SQL' ORDER BY ORDINAL_POSITION;
```

`EXECUTE SCRIPT` does not support pyexasol bind parameters (`?` or `{name}`) — escape manually with `sql_string()`.

### Catalog Column Introspection

Catalog column names are not guessable from the concept they expose
(`CURRENT_VALIDATION_ISSUES` uses `RULE_CODE`, not `ISSUE_CODE`;
`VALIDATION_RUNS` uses `FINISHED_AT`, not `COMPLETED_AT`). Do not guess, and do
not hand-maintain a list — ask the catalog:

```sql
SELECT ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE
FROM SEMANTIC_CATALOG.CATALOG_COLUMNS
WHERE SURFACE_NAME = 'VALIDATION_RUNS' ORDER BY ORDINAL_POSITION;
```

`CATALOG_COLUMNS` covers `SEMANTIC_CATALOG` (`SURFACE_KIND = CATALOG`),
`SEMANTIC_AGENT` (`AGENT`), `SYS_SEMANTIC` (`CORE`), and published model
schemas (`PUBLISHED`).

### Catalog Join Introspection

Do not guess how two surfaces join, and do not read it out of the compiler's
Lua. `SEMANTIC_CATALOG.CATALOG_RELATIONSHIPS` carries every edge in the
installation and hands back a ready-to-paste ON clause:

```sql
SELECT RELATIONSHIP_KIND, CHILD_COLUMN, PARENT_SURFACE, JOIN_TEMPLATE
FROM SEMANTIC_CATALOG.CATALOG_RELATIONSHIPS
WHERE CHILD_SURFACE = 'METRIC_INPUTS' ORDER BY RELATIONSHIP_KIND, CHILD_COLUMN;
```

The `SYS_SEMANTIC` tables carry 106 declared `FOREIGN KEY` constraints, all
created `DISABLE` — declared and visible in `EXA_ALL_CONSTRAINTS`, deliberately
not enforced on write. Adding a table or an ID column means adding its FK to the
declaration block at the end of
`sql/install/001_create_semantic_catalog.sql`; the block is idempotent
(`DROP CONSTRAINT IF EXISTS` then `ADD CONSTRAINT`) because 001 re-runs over an
existing catalog. `tests/test_sql_splitter.py` pins the statement count, so it
fails if a new statement is added there without updating it.

Two kinds of edge are not FK constraints and will not appear in
`EXA_ALL_CONSTRAINT_COLUMNS`: **discriminated** references, whose target table is
chosen by a sibling discriminator column (`METRIC_INPUTS.INPUT_OBJECT_ID` is a
`FACT_ID` or a `METRIC_ID` per `INPUT_OBJECT_TYPE` — always join on the
discriminator too, or rows of different object kinds sharing an id will silently
mix), and **view** edges, since a view carries no constraints. Both are covered
by `CATALOG_RELATIONSHIPS`. See `docs/semantic-catalog.md`.

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
4. Optional representations, bindings, coverage, authority, and identity — use
   `ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS` and pass `{authority, coverage,
   identity}` in one call; the one-dimensional `_WITH_AUTHORITY` / `_WITH_COVERAGE`
   / `_WITH_IDENTITY_BINDING` forms remain for existing callers
5. `VALIDATE_MODEL` -> `PUBLISH_MODEL`

### Two Authoring Surfaces, Neither Complete

Do not reach for Semantic DDL expecting to author a model with it. It covers a
narrow slice, and the scripts cover the rest:

- **SQL-native Semantic DDL** — `APPLY_SEMANTIC_DEFINITION`, or `ALTER SEMANTIC
  VIEW` directly once `ENABLE_SEMANTIC_SQL()` is on — covers **facts and metrics
  only**, on a semantic object that already exists. The accepted forms are
  `REPLACE FACTS`, `REPLACE METRICS`, `ADD OR REPLACE FACT`, `ADD OR REPLACE
  METRIC`, `DROP METRIC`, `RENAME METRIC`. An unsupported clause — **including
  `DIMENSION`** — is refused with `SEMANTIC_DDL_012`, which lists those six
  forms; any other statement, including `CREATE SEMANTIC VIEW`, is refused with
  `SEMANTIC_DDL_010: expected ALTER SEMANTIC VIEW`. Note that
  `APPLY_SEMANTIC_DEFINITION` reports a refusal as `STATUS = 'ERROR'` in its
  result row rather than raising, so check the column, not just for an exception.
  See `sql/examples/sales_metrics_semantic_definition.sql`.
- **The `ADD_*` / `SET_*` / `REMOVE_*` scripts** cover everything else, which is
  most of a model: the model itself, entities, semantic objects, relationships,
  unique keys, dimensions, representations, coverage (F3), authority (F4),
  identity (F5), and materializations. Call them positionally, or by name through
  `CALL_ADMIN_JSON` to avoid counting arguments.

So: bootstrap with the scripts, and maintain facts and metrics in DDL where it is
the clearer record. Calling the scripts "compatibility APIs" would be misleading
— for representations, identity, authority and materializations they are the only
surface that exists.

### SQL NULL Is Truthy Userdata in Lua

Inside an Exasol Lua script, a SQL NULL parameter is not `nil` — it is a
`userdata` value, and userdata is **truthy**. So the ordinary Lua idiom for a
default is silently wrong here:

```lua
local name = tostring(MODEL_NAME or ""):match("^%s*(.-)%s*$")  -- WRONG
if name == "" then error("SEMANTIC_ADMIN_001: MODEL_NAME is required") end
```

With `MODEL_NAME` omitted, `MODEL_NAME or ""` yields the userdata, `tostring`
renders it as `userdata: 0xffff8c986a44`, the `== ""` check never fires, and the
address is reported back to the caller as if it were the value they supplied.
Concatenating the userdata directly is worse — `attempt to concatenate a
userdata value` is a runtime crash, not a refusal. Guard explicitly:

```lua
local function trim(value)
    if value == nil or value == null then return "" end
    return tostring(value):match("^%s*(.-)%s*$")
end
```

`null` is Exasol's script-context global for the SQL NULL value; comparing
against it is the only reliable test. The scripts' own `missing(value)` helper
already does this (`value == nil or value == null or tostring(value) == ""`), so
check `missing` *before* normalizing, not after.

This matters most through `CALL_ADMIN_JSON`, which renders every omitted key as
SQL NULL. Two tests hold the line: `NullNormalisationTest` in
`tests/test_install.py` rejects the idiom statically, and
`tools/verify_g02_named_admin_api.py` calls every model-scoped script with only
`MODEL_NAME` set and fails if any refusal mentions `userdata`.

## Conventions

Three rules with no correctness consequence, so nothing else fails when one is
broken. `tests/test_conventions.py` enforces each as a ratchet — the current
state is pinned, may shrink, and may not grow.

**One condition, one rule code.** A new condition gets a new code unless it is
genuinely the same defect from another angle. There are three digits in every
family and no cost to using them. `SEMANTIC_MODEL_047` reached fourteen distinct
meanings, and one of them was the *cause* of the others — so promoting it to the
head of the report had to search the message text, because the code could not
tell it apart. It is now `SEMANTIC_MODEL_060` and the promotion is a comparison. When you
next touch an overloaded code, split it; `docs/validation-rules.md` carries one
row per code, so the drift is visible.

**Name a verifier for the invariant, not the ticket.** `verify_fanout_guardrails.py`,
not `verify_bug26_published_f3_batch.py`. 24 of 58 verifiers are named after bug
IDs and are grandfathered in the test; adding a 25th fails. Fold a bug-specific
case into the file that owns the behaviour — `verify_fusion_f5.py` absorbed
BUG-G03's lower-case mapping column rather than growing a `verify_g03_*.py`.

**Derive a surface, do not restate it.** `CATALOG_COLUMNS`,
`ADMIN_SCRIPT_PARAMETERS` and `CATALOG_RELATIONSHIPS` read `EXA_ALL_*`, so they
cannot drift from what the install actually created. Where SQL genuinely cannot
declare something — `CATALOG_RELATIONSHIPS`' discriminated edges — declare it
**once** and have everything else read it: that view's polymorphic-column
exclusion is a subquery over its own `discriminated` CTE, not a second copy of
the six names.

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
| `tools/run_smoke.sh` | Full smoke suite |

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
- `docs/data-fusion.md` — data fusion primer, six semantic fusion levels, and anti-patterns
