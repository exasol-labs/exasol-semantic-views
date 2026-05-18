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

- reuses the latest successful `VALIDATE_MODEL` run for the model's active
  version. Compiling does not re-run the validator: `PUBLISH_MODEL` (and the
  admin DDL scripts after every model mutation) own the writes to
  `VALIDATION_RUNS`, `METRIC_DEPENDENCIES`, and `METRIC_DIMENSION_MATRIX`.
  This eliminates the transaction collisions concurrent compile callers
  used to see, and roughly quarters the per-compile latency. A model that
  has never been validated returns `SEMANTIC_REQUEST_010`; run
  `EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL` or
  `SEMANTIC_ADMIN.PUBLISH_MODEL` first.
- rejects metric/dimension pairs through
  `SYS_SEMANTIC.METRIC_DIMENSION_MATRIX`
- reuses `SYS_SEMANTIC.METRIC_DEPENDENCIES` for dependency-aware planning
- returns a table-shaped response with status, error fields, generated SQL, plan
  JSON, clarification JSON, and validation run id
- records explicit agent compile calls in `SYS_SEMANTIC.AGENT_REQUEST_LOG`,
  with `CACHE_HIT` set to `TRUE` when the result came from the compile cache
- emits `SEMANTIC_REQUEST_100` / `SEMANTIC_QUERY_100` for transient
  transaction collisions after the runtime's own bounded retries are
  exhausted. These are safe to retry by the caller

### Compile cache

`SYS_SEMANTIC.COMPILE_CACHE` stores `GENERATED_SQL` + `PLAN_JSON` keyed by
`(MODEL_VERSION_ID, CACHE_KEY)`. `CACHE_KEY` is a 64-bit polynomial hash
(computed in Lua) of the canonical parsed request. The compiler is
deterministic per `(model_version_id, normalized request)`, so a cache hit
returns the stored result without re-running catalog load, matrix lookup,
join planning, materialization selection, or SQL emission.

Normalization rules for the cache key:

- top-level object keys are sorted, so JSON key order in the request does
  not affect the cache key
- `client`, `purpose`, and `natural_language_text` are stripped before
  hashing - they are logging metadata, not compile inputs
- arrays (`metrics`, `dimensions`, `filters`, `having`, `order_by`) keep
  the caller's order, since that order can affect the generated SQL

Invalidation: cache entries are dropped on any event that can change compile
output for a model version: `PUBLISH_MODEL`, `VALIDATE_MODEL` (and therefore
every admin DDL script that re-validates), `REGISTER_MATERIALIZATION`,
`ADD_MATERIALIZATION_COLUMN`, and `SET_MATERIALIZATION_STATUS`. Cache writes
on miss are best-effort: a PK collision from a concurrent identical compile
is swallowed, since the caller already has the correct result. Only
`STATUS = OK` results are cached - errors and clarifications are never
stored, so a user fixing an invalid request and retrying is not blocked by
a stale cache row.

The structured compiler supports:

0. **Dimension-only discovery requests.** A request with `dimensions` set
   and `metrics` empty compiles to `SELECT dim1, dim2, ... FROM <root>
   [JOIN ...] [WHERE filters] GROUP BY dim1, dim2, ...`. This is the
   intended shape for populating facet filters or any other distinct-values
   discovery flow. `HAVING` requires a metric (returns
   `SEMANTIC_REQUEST_026` if supplied alongside zero metrics) and
   aggregate materializations are skipped, since they exist to serve
   aggregations.
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
