# Semantic SQL Preprocessor

Milestone 4 installs a Lua SQL preprocessor in
`SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR`.

Purpose:

1. Early-out for non-semantic SQL.
2. Detect references to published semantic schemas.
3. Parse the supported top-level semantic SQL subset.
4. Call the shared semantic compiler.
5. Replace metric-column SQL with valid physical Exasol SQL before normal query
   validation.

The preprocessor is not a security boundary.

## Activation

Enable semantic SQL for the current session:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
```

Disable it:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL();
```

The install files explicitly clear `SQL_PREPROCESSOR_SCRIPT` before replacing
preprocessor-related scripts. `CREATE SCRIPT` statements are themselves parsed
while a session preprocessor is active, so extension installs should avoid
leaving an old preprocessor in the session.

Activation is session-scoped. BI sessions and SQL clients that want to run
semantic SQL directly must enable it on each connection. Agents and MCP
adapters should prefer `COMPILE_REQUEST_JSON` or `COMPILE_SQL` when they cannot
control session initialization.

For production BI environments, admins can also roll out the same preprocessor
as a system setting. See
[Admin setup for database-wide Semantic SQL](admin-db-wide-setup.md) for the
operator checklist, rollback, and upgrade flow.

## Published Surface

`SEMANTIC_ADMIN.PUBLISH_MODEL('sales')` validates the active model version,
creates the published schema if needed, and generates guarded typed views such
as `SEMANTIC_SALES.SALES`.

Those views are metadata surfaces only. Every column is a cast of
`SEMANTIC_ADMIN.SEMANTIC_GUARD()`, so direct execution without the preprocessor
raises `SEMANTIC_SURFACE_001`.

Published views include comments that point users and tools to
`ENABLE_SEMANTIC_SQL` and `COMPILE_REQUEST_JSON`.

## Supported SQL

The Milestone 4 parser supports the BI-oriented subset:

```sql
SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
WHERE order_status = 'COMPLETE'
GROUP BY customer_region
ORDER BY total_revenue DESC
LIMIT 10;
```

`SELECT` accepts semantic field names, `SELECT *`, and the Databricks-style
metric wrappers `MEASURE(metric)` and `agg(metric)`. `MEASURE()` / `agg()` may
only wrap metrics; wrapping a dimension returns `SEMANTIC_QUERY_006`.

Supported `WHERE` predicates are dimension predicates with `=`, `!=`, `<>`,
`<`, `<=`, `>`, `>=`, `LIKE`, `IN`, and `BETWEEN`. Text equality,
inequality, `LIKE`, and `IN` predicates compile case-insensitively. Single-value
comparison predicates may use a literal or a SQL expression on the right side,
which allows date expressions such as
`ADD_MONTHS(TRUNC(CURRENT_DATE, 'MM'), -1)`. `IN` requires a literal list, and
`BETWEEN` requires literal lower and upper values.

Metric predicates belong in `HAVING` and support the same predicate operators.
For compatibility with SQL users, a metric predicate written in `WHERE` is
routed to `HAVING` during parsing, while dimension predicates remain in
`WHERE`.

`GROUP BY` is optional. When omitted, it is inferred from the selected
dimensions, so this compiles and runs just like the explicit form above:

```sql
SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES;          -- GROUP BY customer_region is inferred
```

If a `GROUP BY` *is* supplied, it must be `GROUP BY ALL` or exactly cover the
selected dimensions (no missing or extra fields), otherwise compilation fails
with `SEMANTIC_QUERY_008`. Explicit `GROUP BY` lists may use selected
dimension names or ordinals.

`ORDER BY` is limited to selected semantic output fields, output aliases, or
ordinals. Databricks-style `ORDER BY MEASURE(metric)` is accepted for selected
metrics. `SELECT *` expands to the visible semantic dimensions and metrics for
the published object.

Unsupported semantic SQL fails closed with `SEMANTIC_QUERY_*` errors. Ordinary
SQL against non-semantic schemas is returned unchanged.

`ALTER SEMANTIC VIEW` currently supports `REPLACE FACTS`, `REPLACE METRICS`,
and single `ADD OR REPLACE METRIC`. Unsupported authoring forms, such as
`ADD OR REPLACE DIMENSION`, fail during preprocessing instead of returning a
result row that callers might ignore. Use `SEMANTIC_ADMIN.ADD_DIMENSION` for
dimension maintenance.

## Introspection Commands

After activation, modelers can use SQL-native introspection commands:

```sql
SHOW SEMANTIC VIEWS;
SHOW SEMANTIC VIEW sales.SALES;
SHOW SEMANTIC METRICS IN sales.SALES;
DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue;
EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct;
EXPORT SEMANTIC MODEL sales;
```

## Hot Path

The preprocessor lane does not call `VALIDATE_MODEL` and does not write request
logs. It uses the latest successful validation run for the model version and
fails if no valid snapshot exists. Explicit agent calls through
`COMPILE_REQUEST_JSON` still validate and log.
