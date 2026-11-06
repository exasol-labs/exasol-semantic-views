# Development reference

This page retains operational details from the former root `CLAUDE.md`. Shared
rules live in [AGENTS.md](../AGENTS.md).

## Local Exasol setup

Install Exasol Personal once with `exasol install local -d dev`. The deployment
chooses a random TCP port. Read it from
`~/.exasol/personal/deployments/dev/deployment.json` at `.connection.dbPort` and
set `EXASOL_PORT`. Defaults are `EXASOL_HOST=localhost`, `EXASOL_PORT=8563`,
`EXASOL_USER=sys`, `EXASOL_PASSWORD=exasol`. Local tooling disables TLS
verification for Personal's self-signed certificate.

Install with demo data using `python3 tools/install.py --example`; use
`--reset` for a clean install. The installer builds generated SQL first.

## Install pipeline and code map

All runtime logic is Lua and SQL inside Exasol; there are no external runtime
services. Hand-written SQL and Lua are under `sql/install/` and `lua/`.
`tools/package_lua_scripts.py` assembles `build/install/` from Lua runtime
manifests and SQL placeholders. Each script has an annotation block describing
its signature. Shared catalog views are generated from compiler catalog reads.
The installer and unit tests build automatically.

Runtime modules are grouped under `lua/semantic_layer/compiler/`, `admin/`,
`agent/`, `shared/`, and `scripts/`. `request_json.lua` coordinates both JSON
and Semantic SQL inputs through a common query spec, catalog snapshot, metric
plan, physical plan, SQL rendering, and response envelope. Keep semantic
decisions in planning, not rendering, and support both input lanes.

`validator.lua` writes validation runs, results, metric dependencies and the
metric-dimension matrix to `SYS_SEMANTIC`. The compiler consumes the latest
successful validation metadata. Relationship proofs must use
`shared/grain_graph.lua`; SQL text handling must use `shared/sql_text.lua`; F5
identity joins must use `shared/identity_join.lua`. Every entity has one active
primary representation; alternate selection and provenance are validated.

Lua SQL NULL parameters are Exasol `userdata`, not `nil`, and are truthy. Check
`value == nil or value == null` before normalizing; use the script `missing`
helper where available. `CALL_ADMIN_JSON` renders omitted keys as SQL NULL.

An installed runtime is one Lua chunk. The 200-local limit applies to the
combined chunk, including locals inside `do` blocks; splitting files does not
reduce the count. Namespace helpers behind module tables. The packager measures
generated chunks with Lua when available. Any shared module must be included in
every runtime that uses it.

## Script and catalog usage

Call admin scripts with `EXECUTE SCRIPT`, never `SELECT`; some mutation scripts
return no rows. Read script result columns by name, never positional index.
`COMPILE_REQUEST_JSON` and `COMPILE_SQL` share the nine-column result layout;
the authoritative contract is `SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT`.
`EXECUTE SCRIPT` does not support pyexasol bind parameters; escape SQL string
literals manually.

Use `SEMANTIC_CATALOG.CATALOG_COLUMNS` for exact catalog column names and
`CATALOG_RELATIONSHIPS` for join edges. The latter includes discriminated edges;
always join their discriminator as well as the identifier. System catalog
foreign keys are declared disabled and must be included in the declaration
block when adding tables or ID columns.

Expression validation statically checks references and supported functions.
Some expressions are additionally bound against their source, but metric,
filter, and identity expressions are not; smoke-test those against their source
before registration or certification.

## Authoring surfaces

Use scripts to create and relate graph objects: models, entities, semantic
objects, relationships, keys, representations, fusion declarations and
materializations. Use Semantic DDL for an object's dimensions, facts, and
metrics. `REPLACE` blocks are atomic and support `DRY_RUN`. Fusion declarations
use `APPLY_FUSION_DECLARATION` / `EXPORT_FUSION_DECLARATION` and must be complete
when applied to a published model. Removing a semantic object uses
`REMOVE_SEMANTIC_OBJECT`; it retains facts and entities and refuses removal when
derived dependency metadata shows another metric depends on it.

The sales model example is in `sql/examples/`. Its order is: create model and
entities, semantic objects, keys and relationships, dimensions/facts/metrics,
optional representations and bindings, then validate and publish.

## Checking loaded instructions

Start a fresh Codex session at the repository root; Codex reads root `AGENTS.md`.
Start Claude Code at the root; Claude imports it through `CLAUDE.md`'s
`@AGENTS.md`. Ask each to summarize the repository's core invariants and compare
the answer with the root instructions. This verifies the expected instruction
entry point is active.
