# Exasol Runtime

Installed runtime behavior must be implemented with SQL and Lua.

Allowed database runtime surfaces:

- Exasol SQL DDL and DML.
- Lua `CREATE SCRIPT` admin programs.
- Lua SQL preprocessor script.
- Lua scalar helper scripts for guarded metadata views.
- Optional Lua Virtual Schema adapter in a later milestone.

Disallowed core runtime surfaces:

- Python script containers.
- Java script containers.
- R script containers.
- External parser runtimes required by installed database objects.

Host-side development tooling may use other languages if useful, but those tools
must not become required database runtime dependencies.

## Milestone 1 Runtime Objects

Milestone 1 installs:

- SQL schemas and catalog tables.
- Read-only metadata views in `SEMANTIC_CATALOG`.
- Lua `CREATE SCRIPT` admin programs in `SEMANTIC_ADMIN`.
- Sales example physical tables in `MART`.

Use `EXECUTE SCRIPT`, not `CALL`, for admin APIs.

## Milestone 2 Runtime Objects

Milestone 2 adds:

- `SEMANTIC_ADMIN.VALIDATOR_RUNTIME`.
- `SEMANTIC_ADMIN.VALIDATE_MODEL`.
- Validation result tables and the metric/dimension matrix.

## Milestone 3 Runtime Objects

Milestone 3 adds:

- `SEMANTIC_ADMIN.COMPILER_RUNTIME`.
- `SEMANTIC_ADMIN.COMPILE_REQUEST_JSON`.
- Pure-Lua JSON parsing and SQL generation inside the database.

## Milestone 4 Runtime Objects

Milestone 4 adds:

- `SEMANTIC_ADMIN.COMPILE_SQL`.
- `SEMANTIC_ADMIN.COMPILE_SQL_DEBUG`.
- `SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR`.
- `SEMANTIC_ADMIN.SEMANTIC_GUARD`.
- `SEMANTIC_ADMIN.PUBLISH_MODEL`.
- `SEMANTIC_ADMIN.REFRESH_SEMANTIC_SURFACE`.
- `SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL`.
- `SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL`.
- Published guarded views such as `SEMANTIC_SALES.SALES`.

## Milestone 5 Runtime Objects

Milestone 5 adds:

- `SEMANTIC_AGENT.MODELS_FOR_AGENT`.
- `SEMANTIC_AGENT.OBJECTS_FOR_AGENT`.
- `SEMANTIC_AGENT.FIELDS_FOR_AGENT`.
- `SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT`.
- `SEMANTIC_AGENT.MEASURE_GROUPS_FOR_AGENT`.
- `SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT`.
- `SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT`.
- `SEMANTIC_AGENT.BUSINESS_GLOSSARY_FOR_AGENT`.
- `SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT`.
- `SEMANTIC_AGENT.COMPILE_REQUEST_SCHEMA_FOR_AGENT`.
- `SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT`.
- `SEMANTIC_ADMIN.AGENT_RUNTIME`.
- `SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION`.
- `SEMANTIC_ADMIN.ADD_VERIFIED_QUERY`.
- `SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS`.
- `SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT`.
- `SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY`.
- `SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL`.
- `SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK`.

## Nano-Validated Script And DDL Notes

- `CREATE SCRIPT` parameter lists are untyped. Use `SCRIPT_NAME(arg1, arg2)`.
- Lua script parameters should be checked against the `null` sentinel. Do not
  assume a global `is_null()` helper exists.
- Catalog DDL should avoid unquoted reserved or parser-sensitive names. The
  implemented catalog uses `RELATIONSHIP_CARDINALITY` and `SYNONYM_SOURCE`.
- Column defaults should use the tested order `DEFAULT ... NOT NULL`.
- Local Nano requires TLS for pyexasol connections; development tools disable
  certificate verification only for local self-signed Nano.
- Preprocessor install files should start by clearing
  `SQL_PREPROCESSOR_SCRIPT`; an active session preprocessor can otherwise see
  extension DDL.
- Published guarded views use conventional uppercase Exasol column identifiers
  so unquoted user SQL such as `select customer_region ...` resolves normally.
- Lua `query()` results should be copied into plain row arrays before passing
  them to `exit(...)`; iterating a query result and returning it directly are
  not equivalent in Nano.
