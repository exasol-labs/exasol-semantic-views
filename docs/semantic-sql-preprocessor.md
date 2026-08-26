# Semantic SQL Preprocessor

The installed Lua SQL preprocessor is
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

The official Exasol MCP Server can control this state directly with its
`list_exasol_preprocessors` and `set_exasol_preprocessor` tools, which are
enabled by default. Agents should set and verify
`SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR`, then use `execute_exasol_query`. See
[Exasol MCP Server Integration](mcp-server-integration.md) for the exact
workflow and the current `row_limit` caveat.

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

The parser supports this BI-oriented subset:

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
`<`, `<=`, `>`, `>=`, `LIKE`, `IN`, `BETWEEN`, `IS NULL`, and `IS NOT NULL`.
Text equality, inequality, `LIKE`, and `IN` predicates compile
case-insensitively. Null predicates are unary. Single-value comparison
predicates may use a literal or a SQL expression on the right side, which
allows date expressions such as
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

Every name position accepts a double-quoted identifier for names that collide
with SQL keywords (`ON ENTITY "order"`); the quoted text must still be a valid
identifier.

`ALTER SEMANTIC VIEW` supports `REPLACE DIMENSIONS`, `REPLACE FACTS`, `REPLACE
METRICS`, single `ADD OR REPLACE DIMENSION`, `ADD OR REPLACE FACT`, `ADD OR
REPLACE METRIC`, `DROP METRIC`, and `RENAME METRIC ... TO ...`. Any `REPLACE`
block is a valid statement on its own, and the blocks compose — one statement may
carry dimensions, facts and metrics together, validated once and rolled back as a
unit. The three single forms each take the rest of the statement as one clause,
so none can be combined with another change (`SEMANTIC_DDL_037` for a fact,
`SEMANTIC_DDL_038` for a dimension).

A dimension takes the same clauses as a fact — `ON ENTITY`, `AS`, `RETURNS`, and
optionally `DISPLAY`, `COMMENT`, `FORMAT`, `CERTIFIED`, `PRIVATE`:

```sql
ALTER SEMANTIC VIEW sales.SALES
REPLACE DIMENSIONS (
  DIMENSION ship_mode
    ON ENTITY "order"
    AS o.ship_mode
    RETURNS VARCHAR(20)
    DISPLAY 'Ship Mode'
    COMMENT 'How the order shipped'
    CERTIFIED
);
```

`PRIVATE` maps to the catalog's `IS_HIDDEN`, which is how `DIMENSIONS` spells
what `FACTS` calls `IS_PRIVATE`. `AS` requires `SEMANTIC_DDL_026` and `RETURNS`
requires `SEMANTIC_DDL_027`, mirroring a fact's `_021`/`_022`.

**Column order is a side effect of block order.** Each `REPLACE` block deletes
its kind's `OBJECT_COLUMNS` rows first, and the apply then re-adds dimensions,
facts and metrics in that order, each taking `MAX(ORDINAL_POSITION) + 1`. So one
statement carrying all three blocks renumbers the object from 1, in that order —
which is the order `sales_model_seed.sql` produces by calling `ADD_DIMENSION`
before applying its fact and metric blocks. Two separate statements interleave
instead: replacing dimensions on their own lands them *after* the surviving facts
and metrics. That matters beyond cosmetics, because OSI export carries these
ordinals into the imported model, so it is a published column order.

Fact and dimension *removal* have no single DDL form: they wait until
dependent-metric rewrites are transactional. A `REPLACE` block does remove — it
decides the object's membership, so anything left out of the block leaves the
object. Unsupported authoring forms fail during preprocessing instead of
returning a result row that callers might ignore. `SEMANTIC_ADMIN.ADD_DIMENSION`
and `SEMANTIC_ADMIN.ADD_OR_REPLACE_DIMENSION` remain available and are the way to
remove a single dimension (`REMOVE_DIMENSION`) or to add one outside a `REPLACE`
block's set semantics.

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
`COMPILE_REQUEST_JSON` use the same validation gate and additionally write an
agent request log; they do not rerun validation during compilation.
