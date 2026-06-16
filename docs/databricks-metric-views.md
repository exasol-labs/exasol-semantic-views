# Databricks Unity Catalog Metric View (UCMV) compatibility

This layer can ingest [Databricks Unity Catalog Metric Views](https://docs.databricks.com/aws/en/business-semantics/metric-views/)
and accept the Databricks query surface, so teams migrating off Databricks can
reuse their metric-view YAML and their `MEASURE(...)` / `GROUP BY ALL` SQL.

There are two independent pieces:

1. **Import** — translate a UCMV YAML definition into this project's native
   semantic DDL and apply it to the catalog. The translation runs **in the
   database** (Lua); only file transport is host-side.
2. **SQL compatibility** — the semantic SQL preprocessor accepts the Databricks
   query idioms (`MEASURE(metric)`, `agg(metric)`, `GROUP BY ALL`) against
   published semantic objects.

## Importing a metric view

The translator is the database script `SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(
  '<metric view YAML>',   -- the full YAML body
  'sales_dbx',            -- target model name
  'SEMANTIC_SALES_DBX',   -- published schema (NULL => SEMANTIC_<MODEL>)
  TRUE                    -- apply (FALSE = translate and return DDL only)
);
```

It returns one row: `STATUS, ERROR_CODE, ERROR_MESSAGE, MODEL_NAME,
GENERATED_DDL, DIAGNOSTICS_JSON, VALIDATION_RUN_ID`. `GENERATED_DDL` is the
reviewable native DDL (positional `ADD_*` scaffolding plus an
`ALTER SEMANTIC VIEW ... REPLACE FACTS/METRICS` block). When `apply` is `TRUE`
the model is created, validated, and **published** — so it is queryable
immediately, matching Databricks.

A thin host helper reads a `.yaml` file and calls the script:

```sh
python3 tools/import_databricks.py path/to/metric_view.yaml \
  --model sales_dbx --schema SEMANTIC_SALES_DBX --apply
```

Without `--apply` it prints the generated DDL and diagnostics so you can review
(or hand-edit) before applying. A worked example over the demo MART tables lives
at `sql/examples/sales_databricks_metric_view.yaml`.

### How concepts map

Databricks describes a metric view with one `source`, optional `joins`,
`fields` (dimensions), and `measures` (aggregates). This project splits a
measure into a row-level **fact** and an aggregate **metric**, and models joins
as **entities + relationships**:

| Databricks UCMV | This project | Notes |
|---|---|---|
| `source: cat.schema.table` | root `ENTITY` (`CREATE_MODEL` + `ADD_ENTITY` + `ADD_SEMANTIC_OBJECT`) | 3-part name → `SOURCE_SCHEMA.SOURCE_OBJECT` (catalog dropped); a short alias is derived |
| `source: SELECT ...` | unsupported (`DBX_IMPORT_210`) | wrap the query in a view and import that view |
| `joins[]` (`name`, `source`, `on`, `cardinality`) | one `ENTITY` per joined table + one `RELATIONSHIP` | `many_to_one`→`MANY_TO_ONE`, `one_to_many`→`ONE_TO_MANY`; `source.x = join.y` rewritten to alias form |
| nested `joins` (snowflake) | chained relationships | each level becomes its own entity + relationship |
| `fields[]` | `DIMENSION` | `joinname.col` / bare columns rewritten to entity source aliases; bound to the referenced entity |
| `measures[]` `SUM/AVG/MIN/MAX(expr)` | private `FACT` (inner expr) + `METRIC AGG(fact)` (`ADDITIVE`) | |
| `measures[]` `COUNT(1)` / `COUNT(*)` | `FACT ... AS 1` + `METRIC COUNT(fact)` | row count |
| `measures[]` `COUNT(DISTINCT col)` | `FACT col` + `METRIC COUNT(DISTINCT fact)` | |
| `measures[]` `... FILTER (WHERE pred)` | `METRIC ... FILTER (WHERE pred)` (`FILTERED`) | predicate columns mapped to semantic dimension names where possible |
| `measures[]` `MEASURE(a)/MEASURE(b)` | `METRIC a / NULLIF(b, 0)` (`RATIO`) | `MEASURE()`/`agg()` refs unwrapped |
| `measures[]` arithmetic of `MEASURE()` refs | `METRIC ...` (`DERIVED`) | |
| `comment` / `display_name` / `synonyms` / `format` | `COMMENT` / `DISPLAY` / `SYNONYMS` / `FORMAT` | `format.type` currency/percent/number → format hint |

### Supported, partial, and unsupported

**Supported:** table/SQL-view `source`; star and snowflake `joins`
(`many_to_one` and `one_to_many`); `fields`; `SUM`/`AVG`/`MIN`/`MAX`/`COUNT`/
`COUNT(DISTINCT)` measures; `FILTER (WHERE ...)` measures; ratio and derived
measures composed from `MEASURE()`; `comment`, `display_name`, `synonyms`,
`format`.

**Partial / dropped (with a diagnostic):**
- `window:` measures — skipped (`DBX_IMPORT_410`).
- View-level `filter:` — not auto-applied (`DBX_IMPORT_500`); add it to the
  relevant metrics if needed.
- `materialization:` — ignored (`DBX_IMPORT_510`); use this project's own
  materialization selection (see `docs/semantic-compiler.md`).
- `USING` joins — skipped (`DBX_IMPORT_240`); provide an `on:` condition.

**Unsupported:** inline-query `source` (`DBX_IMPORT_210`).

Diagnostics are returned as `DIAGNOSTICS_JSON` (a list of
`{code, severity, path, message}`) using the `DBX_IMPORT_*` namespace.

### Expressions are translated, not dialect-converted

Field and measure expressions are copied through after qualifying column
references with entity aliases — they are **not** translated between Spark SQL
and Exasol SQL. Functions that do not exist in Exasol (for example Databricks
`QUARTER()`) pass the validator's blocklist and only fail at execution time (the
same caveat as BUG-002). Review imported expressions and adjust to documented
Exasol functions where dialects differ.

## SQL-level query compatibility

After `EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();`, the preprocessor
accepts the Databricks query surface against any published semantic object:

```sql
-- Databricks style
SELECT customer_region,
       MEASURE(total_revenue) AS total_revenue,
       MEASURE(order_count)   AS order_count
FROM SEMANTIC_SALES.SALES
GROUP BY ALL
HAVING MEASURE(total_revenue) > 1000
ORDER BY MEASURE(total_revenue) DESC;
```

is compiled identically to the native bare-name form:

```sql
SELECT customer_region, total_revenue, order_count
FROM SEMANTIC_SALES.SALES
GROUP BY customer_region
HAVING total_revenue > 1000
ORDER BY total_revenue DESC;
```

Details:
- `MEASURE(metric)` and its `agg(metric)` synonym are unwrapped to the metric
  name in `SELECT`, `HAVING`, and `ORDER BY`. `MEASURE()` of a dimension is
  rejected with `SEMANTIC_QUERY_006`.
- `GROUP BY ALL` groups by every non-aggregated `SELECT` column (the selected
  dimensions); an explicit `GROUP BY` list is still accepted.
- The generated physical SQL is unchanged — only the accepted input surface is
  wider. Metric compatibility, joins, and materialization selection behave
  exactly as for native semantic SQL (`docs/semantic-sql-preprocessor.md`).

## Verifying

```sh
python3 tools/install.py --example --reset
python3 tools/verify_databricks_sql_compat.py   # MEASURE()/agg(), GROUP BY ALL, HAVING/ORDER BY
python3 tools/verify_databricks_import.py        # end-to-end import over the demo MART tables
```

Both are part of `sh tools/run_nano_smoke.sh`.
