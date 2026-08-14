# Exasol Runtime

The installed runtime is implemented entirely with Exasol SQL and Lua. Host-side
Python tools package, install, test, and exchange model definitions, but they are
not dependencies of an installed semantic model.

## Runtime Boundary

Installed database objects use:

- Exasol SQL DDL, DML, views, and session settings.
- Lua `CREATE SCRIPT` programs for administration, validation, compilation,
  publication, import helpers, and agent workflows.
- A Lua SQL preprocessor for published-view and Semantic SQL rewriting.
- A Lua scalar guard used by published metadata views.

The runtime does not require Python, Java, R, an external parser service, or an
LLM. Generated SQL is executed by Exasol under the caller's normal privileges.

Use `EXECUTE SCRIPT`, not `CALL` or `SELECT`, for `SEMANTIC_ADMIN` APIs.

## Installed Schemas

| Schema | Responsibility |
| --- | --- |
| `SYS_SEMANTIC` | Authoritative internal catalog and operational state |
| `SEMANTIC_CATALOG` | Read-only administrative metadata views |
| `SEMANTIC_ADMIN` | Lua administration, validation, compiler, publication, and agent scripts |
| `SEMANTIC_AGENT` | Role-scoped discovery and review views |
| `SEMANTIC_<MODEL>` | Guarded relational metadata surface for each published model |

The installer applies seven files in dependency order:

```text
sql/install/000_create_schemas.sql
sql/install/001_create_semantic_catalog.sql
sql/install/002_create_semantic_catalog_views.sql
sql/install/003_create_semantic_admin_scripts.sql
sql/install/004_create_semantic_preprocessor.sql
sql/install/005_create_semantic_surface_helpers.sql
sql/install/006_create_semantic_agent_views.sql
```

Canonical Lua source lives under `lua/semantic_layer`. The installer runs
`tools/package_lua_scripts.py` unless `--skip-package` is supplied, so the
packaged SQL scripts and source modules remain synchronized.

## Runtime Components

### Catalog and authoring

Catalog scripts create and evolve models, entities, representations, semantic
objects, relationships, keys, dimensions, facts, metrics, materializations,
fusion declarations, semantic identities, instructions, and verified queries.

Single-row helpers remain useful for bootstrap and compatibility. Compound
helpers such as `ADD_UNIQUE_KEY_WITH_COLUMNS`,
`ADD_ENTITY_REPRESENTATION_WITH_COVERAGE`, and
`ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING` stage declarations that would
otherwise expose an invalid intermediate state on a published model.
Draft heterogeneous registration returns generated-binding diagnostics, and
`REPLACE_ATTRIBUTE_BINDING` repairs an existing generated row prospectively
without a remove/add gap.

`APPLY_SEMANTIC_DEFINITION` provides SQL-native metric authoring, dry-run
validation, atomic apply, metric rename/drop, Databricks translation support,
and export/introspection. `APPLY_NORMALIZED_OSI_IMPORT` applies a host-normalized
Ossie/OSI plan without making YAML or schema-version logic part of the database
runtime.

### Validation and certification

`VALIDATOR_RUNTIME` and `VALIDATE_MODEL` validate catalog structure, source
metadata, grain proofs, metric dependencies, representation equivalence,
coverage, reconciliation, and semantic identity. Validation writes durable run
and issue records plus the metric/dimension matrix consumed by compilation.

Multi-representation data probes require a bounded session `QUERY_TIMEOUT`.
Compilation reuses the latest successful validation for the active model version;
it does not rerun validation or remote probes per business query.

### Compiler and SQL generation

`COMPILER_RUNTIME` exposes:

- `COMPILE_REQUEST_JSON`
- `COMPILE_SQL`
- `COMPILE_SQL_DEBUG`
- `SUGGEST_GRAIN_METADATA`

JSON and Semantic SQL lower to the same `QuerySpec`, catalog snapshot, logical
metric plan, physical plan, and SQL renderer. The compiler handles strict grain
proofs, multi-fact aggregate-state merging, deterministic representation
selection, temporal partitions, authority-based reconciliation, semantic
identity, and safe materialization substitution.

### Publication and preprocessing

`PUBLISH_MODEL` validates a model and creates guarded typed views in its
published schema. `SEMANTIC_PREPROCESSOR` recognizes supported semantic queries,
calls the shared compiler, and replaces them with generated Exasol SQL.

Session activation is controlled by `ENABLE_SEMANTIC_SQL` and
`DISABLE_SEMANTIC_SQL`. `REFRESH_SEMANTIC_SURFACE` regenerates published metadata
views after a valid catalog change. Direct execution without preprocessing calls
`SEMANTIC_GUARD` and fails rather than bypassing semantic compilation.

### Agent and governance runtime

`AGENT_RUNTIME` supports semantic search, object descriptions, glossary output,
plan explanation, feedback, and governed model-evolution proposals and reviews.
Role-scoped views expose models, objects, fields, valid combinations, verified
queries, instructions, validation errors, request schema, request history, and
the evolution review queue.

No agent workflow mutates model semantics automatically. Suggestions are durable
proposals that require review through `REVIEW_MODEL_EVOLUTION`.

### Materialization runtime

`MATERIALIZATION_RUNTIME` registers aggregate sources and their semantic column
mappings. Materializations are selected only after logical correctness and grain
have been proven. An incomplete or unsafe candidate falls back to base-source SQL
and remains visible in plan rejection provenance.

## Source Connectivity

Entity representations may name ordinary Exasol relations or relations exposed
through a Virtual Schema. The semantic runtime treats both as queryable Exasol
relations and does not implement a source-specific adapter or hidden network
client. Remote pushdown and connectivity remain responsibilities of the
underlying Virtual Schema adapter.

## Exasol-Specific Implementation Notes

- `CREATE SCRIPT` parameter lists are untyped. Use `SCRIPT_NAME(arg1, arg2)`.
- Lua script parameters must be checked against Exasol's `null` sentinel; do not
  assume a global `is_null()` helper exists.
- Catalog DDL avoids unsupported generic `CHECK` and `UNIQUE` constraints.
  Allowed values and semantic uniqueness are enforced by admin and validation
  scripts.
- Column defaults use the tested order `DEFAULT ... NOT NULL`.
- Preprocessor install files clear `SQL_PREPROCESSOR_SCRIPT` before replacing
  preprocessor-related scripts because an active preprocessor also sees extension
  DDL.
- Published views use uppercase Exasol identifiers so ordinary unquoted SQL
  resolves semantic field names normally.
- Lua `query()` results are copied into plain row arrays before `exit(...)`.
  Iterating a query result and returning that query object are not equivalent.
- Local Nano pyexasol connections use TLS with certificate verification disabled
  only for the local self-signed development instance.

See [Architecture](architecture.md) for component rationale and
[Runtime Testing](runtime-testing.md) for database-free and Nano verification.
