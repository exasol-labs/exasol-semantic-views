# Semantic Compiler

The compiler has three installed SQL-facing entrypoints:

1. `SEMANTIC_ADMIN.COMPILE_REQUEST_JSON`, for structured agent requests.
2. `SEMANTIC_ADMIN.COMPILE_SQL`, for SQL users, tests, and BI/debug workflows.
3. `SEMANTIC_ADMIN.COMPILE_SQL_DEBUG`, for opt-in SQL compile logging to
   `SYS_SEMANTIC.QUERY_LOG`.

Both entrypoints reuse the same binding, validation, planning, materialization
selection, metric expansion, and SQL generation core in
`SEMANTIC_ADMIN.COMPILER_RUNTIME`, packaged from
`lua/semantic_layer/compiler/request_json.lua`.

These entrypoints are Lua scripts. Call them with `EXECUTE SCRIPT`, not
`SELECT`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('<request-json>');
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL('<semantic-sql>');
```

The explicit agent and SQL lanes are validation-gated:

- uses `SEMANTIC_ADMIN.VALIDATE_MODEL` before
  generating SQL
- rejects metric/dimension pairs through
  `SYS_SEMANTIC.METRIC_DIMENSION_MATRIX`
- reuses `SYS_SEMANTIC.METRIC_DEPENDENCIES` for dependency-aware planning
- returns a table-shaped response with status, error fields, generated SQL, plan
  JSON, clarification JSON, and validation run id
- records explicit agent compile calls in `SYS_SEMANTIC.AGENT_REQUEST_LOG`

The structured compiler supports:

1. Metrics and dimensions by canonical names or visible synonyms.
2. Dimension filters with `=`, `!=`, `<>`, `<`, `<=`, `>`, `>=`, `LIKE`,
   `IN`, and `BETWEEN`. Text `=`, `!=`, `<>`, `LIKE`, and `IN` filters compile
   case-insensitively. Structured request filters accept `field`, `dimension`,
   `column`, or `name` for the field key, and `op` or `operator` for the
   operator key.
3. `ORDER BY` over selected output fields.
4. `LIMIT` up to the configured maximum.
5. Additive metrics, filtered metrics using `CASE`, and derived metrics as
   arithmetic over expanded aggregate expressions.
6. Relationship planning from the semantic object root to required entities.
7. Optional materialized aggregate selection when registered catalog metadata
   fully covers the selected metrics, selected dimensions, filter dimensions,
   and rollup policy requirements.
8. Stable structured errors for malformed JSON, unknown fields, invalid limits,
   invalid metric/dimension pairs, and missing relationship paths.

Materialization selection is an optimization below both `COMPILE_REQUEST_JSON`
and `COMPILE_SQL`. The compiler validates the semantic request first, then
selects an active same-version aggregate materialization only when every
selected or filtered dimension and every selected metric is mapped. Unsafe
rollups, missing columns, unsupported freshness policies, inactive
materializations, and non-additive rollup attempts fall back to base-source SQL.
The selected materialization and rejected-candidate diagnostics are recorded in
`PLAN_JSON`; SQL debug logging also stores the selected name in
`SYS_SEMANTIC.QUERY_LOG.MATERIALIZATION_USED`.

`COMPILE_SQL` parses a deliberately small semantic SQL subset and translates it
into the same request shape before invoking the shared compiler core. Its errors
use the `SEMANTIC_QUERY_*` namespace. It supports semantic `SELECT *` expansion
and SQL expressions on the right side of dimension predicates, such as
`order_month = ADD_MONTHS(TRUNC(CURRENT_DATE, 'MM'), -1)`. `ORDER BY` can refer
to selected semantic fields or their output aliases.

`COMPILE_SQL_DEBUG` has the same compile behavior as `COMPILE_SQL`, but records
the original SQL, generated SQL, plan JSON, requested dimensions, requested
metrics, status, and error fields in `SYS_SEMANTIC.QUERY_LOG`. This is
intentionally separate from the preprocessor path.

The preprocessor lane calls `compile_sql_for_preprocessor` inside the runtime.
That lane:

1. Returns non-semantic SQL unchanged.
2. Parses only a supported top-level semantic `SELECT`.
3. Uses the latest successful validation run instead of running validation per
   query.
4. Avoids hot-path DML logging.
5. Fails closed if validation is missing or stale.
6. Uses the same materialization decision path as explicit agent and SQL
   compilation.

`tools/package_lua_scripts.py` embeds the compiler runtime, materialization
runtime, and wrappers into `sql/install/003_create_semantic_admin_scripts.sql`.
