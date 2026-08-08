# Authoring Workflows

Use these examples when building or maintaining an Exasol Semantic Views model.
All `SEMANTIC_ADMIN` calls require `EXECUTE SCRIPT`.

## Inspect the Physical Schema

```sql
SELECT TABLE_NAME, TABLE_COMMENT, TABLE_ROW_COUNT
FROM EXA_ALL_TABLES
WHERE TABLE_SCHEMA = 'MART'
ORDER BY TABLE_NAME;
```

```sql
SELECT VIEW_NAME, VIEW_COMMENT
FROM EXA_ALL_VIEWS
WHERE VIEW_SCHEMA = 'MART'
ORDER BY VIEW_NAME;
```

```sql
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, NULLABLE, COLUMN_COMMENT
FROM EXA_ALL_COLUMNS
WHERE COLUMN_SCHEMA = 'MART'
ORDER BY TABLE_NAME, ORDINAL_POSITION;
```

Read non-null comments before sampling. Carry verified table/view meaning into
model, entity, grain, and semantic-object descriptions; carry verified column
meaning into fact and dimension descriptions. Enrich rather than merely copy:
record units, aggregation behavior, filters, exclusions, and sensitivity when
the source comment omits them. If comments conflict with data or constraints,
flag the conflict for review.

If the source schema already has reporting traffic, mine historical workload
queries before finalizing the semantic shape. Once a semantic layer is
published, `SYS_SEMANTIC.QUERY_LOG` can refine naming and coverage.

The most useful Exasol history sources are:

1. `EXA_DBA_AUDIT_SQL` for executed SQL, statement class, duration, and
   resource usage.
2. `EXA_DBA_AUDIT_SESSIONS` and `EXA_DBA_SESSIONS_LAST_DAY` for user, client,
   driver, host, login/logout, and success/failure context.
3. `EXA_DBA_PROFILE_LAST_DAY` and `EXA_USER_PROFILE_LAST_DAY` for operator-
   level evidence, touched objects, row counts, and `REMARKS` that often name
   join and filter columns.
4. `EXA_USAGE_LAST_DAY`, `EXA_USAGE_HOURLY`, `EXA_USAGE_DAILY`, and
   `EXA_USAGE_MONTHLY` for aggregate load trends when fine-grained history is
   not available.

Most DBA-prefixed history tables require `SELECT ANY DICTIONARY`. Use the
richest source available for the workload you are studying.

Useful usage-shape queries:

```sql
SELECT HANDLE_TYPE, MODEL_NAME, USER_NAME, CLIENT_NAME, STATUS, REQUEST_TIME
FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT
WHERE MODEL_NAME = 'sales'
ORDER BY REQUEST_TIME DESC;
```

```sql
SELECT REQUESTED_METRICS, REQUESTED_DIMENSIONS, COUNT(*) AS QUERY_COUNT
FROM SYS_SEMANTIC.QUERY_LOG
WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales')
  AND STATUS = 'OK'
GROUP BY REQUESTED_METRICS, REQUESTED_DIMENSIONS
ORDER BY QUERY_COUNT DESC;
```

```sql
SELECT ERROR_CODE, COUNT(*) AS ERROR_COUNT
FROM SYS_SEMANTIC.QUERY_LOG
WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME = 'sales')
  AND STATUS <> 'OK'
GROUP BY ERROR_CODE
ORDER BY ERROR_COUNT DESC;
```

Treat historical query shape as evidence for prioritization, not as a source of
truth for grain or relationships. The schema, comments, and constraints still
win when they disagree with usage patterns.

When translating history into semantic candidates:

- Repeated `GROUP BY` columns become candidate dimensions.
- Repeated `WHERE` predicates become candidate filter dimensions or filtered
  metrics.
- Repeated `SUM`, `COUNT`, `MIN`, `MAX`, `AVG`, and `COUNT DISTINCT` patterns
  become candidate metrics.
- Repeated arithmetic over aggregates becomes a derived or ratio metric.
- Columns repeatedly seen in joins or in profiling `REMARKS` become relationship
  or fact candidates.
- Repeated labels, aliases, and business phrases become synonym candidates.

Use these rules as a ranking mechanism, not as an automatic generator. The
physical schema still decides grain and relationship truth.

To find likely foreign key columns (columns whose names end in `_ID` or `_KEY`
and appear in more than one table):

```sql
SELECT COLUMN_NAME, COUNT(DISTINCT TABLE_NAME) AS TABLE_COUNT
FROM EXA_ALL_COLUMNS
WHERE COLUMN_SCHEMA = 'MART'
  AND (COLUMN_NAME LIKE '%_ID' OR COLUMN_NAME LIKE '%_KEY')
GROUP BY COLUMN_NAME
HAVING COUNT(DISTINCT TABLE_NAME) > 1
ORDER BY TABLE_COUNT DESC, COLUMN_NAME;
```

## Register Entities

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'order_line',
  'MART',
  'ORDER_LINES',
  'ol',
  'CAST(ol.order_id AS VARCHAR(36)) || ''-'' || CAST(ol.line_id AS VARCHAR(36))',
  'One row per order line',
  'One row per order line item'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'order',
  'MART',
  'ORDERS',
  'o',
  'o.order_id',
  'One row per order',
  'One row per customer order'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'customer',
  'MART',
  'CUSTOMERS',
  'c',
  'c.customer_id',
  'One row per customer',
  'One row per customer account'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT(
  'sales',
  'SALES',
  'order_line',
  'Sales metrics and dimensions'
);
```

## Register Relationships

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  'sales',
  'order_line_to_order',
  'order_line',
  'order',
  'ol.order_id = o.order_id',
  'MANY_TO_ONE',
  'INNER',
  NULL
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  'sales',
  'order_to_customer',
  'order',
  'customer',
  'o.customer_id = c.customer_id',
  'MANY_TO_ONE',
  'LEFT',
  NULL
);
```

## Add Facts

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'net_revenue',
  'ol.quantity * ol.net_unit_price',
  'DECIMAL(18,2)',
  'ADDITIVE',
  'Net Revenue',
  'Net revenue per order line before tax',
  FALSE,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'net_cost',
  'ol.quantity * ol.unit_cost',
  'DECIMAL(18,2)',
  'ADDITIVE',
  'Net Cost',
  'Cost of goods per order line',
  FALSE,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'gross_margin',
  'ol.quantity * ol.net_unit_price - ol.quantity * ol.unit_cost',
  'DECIMAL(18,2)',
  'ADDITIVE',
  'Gross Margin',
  'Revenue minus cost per order line',
  FALSE,
  TRUE
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'quantity',
  'ol.quantity',
  'DECIMAL(18,3)',
  'ADDITIVE',
  'Quantity',
  'Units sold per line',
  FALSE,
  TRUE
);
```

## Add Dimensions

Categorical dimensions:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'order',
  'order_status',
  'o.order_status',
  'VARCHAR(32)',
  'Order Status',
  'Fulfilment status of the order',
  NULL,
  1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'customer',
  'customer_region',
  'c.region',
  'VARCHAR(100)',
  'Customer Region',
  'Geographic region of the customer',
  NULL,
  1
);
```

Time dimensions from a single date column (one per grain):

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'order',
  'order_year',
  'EXTRACT(''YEAR'' FROM o.order_date)',
  'DECIMAL(4,0)',
  'Order Year',
  'Calendar year of the order',
  'year',
  1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'order',
  'order_quarter',
  '''Q'' || CAST(EXTRACT(''QUARTER'' FROM o.order_date) AS VARCHAR(1))',
  'VARCHAR(2)',
  'Order Quarter',
  'Calendar quarter of the order',
  'quarter',
  1
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales', 'SALES', 'order',
  'order_month',
  'DATE_TRUNC(''MONTH'', o.order_date)',
  'DATE',
  'Order Month',
  'First day of the calendar month',
  'month',
  1
);
```

## Author Metrics

Enable Semantic SQL for the session before using DDL form:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
```

Additive metric (dry-run then apply):

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC total_revenue
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FORMAT ''currency_usd''
  DISPLAY ''Total Revenue''
  COMMENT ''Sum of net revenue across all order lines''
  ADDITIVE PUBLIC CERTIFIED',
  TRUE   -- dry-run
);

EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC total_revenue
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FORMAT ''currency_usd''
  DISPLAY ''Total Revenue''
  COMMENT ''Sum of net revenue across all order lines''
  ADDITIVE PUBLIC CERTIFIED',
  FALSE  -- apply
);
```

Filtered metric:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC completed_revenue
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FILTER (WHERE order_status = ''COMPLETE'')
  FORMAT ''currency_usd''
  DISPLAY ''Completed Revenue''
  COMMENT ''Net revenue restricted to orders with status COMPLETE''
  ADDITIVE PUBLIC CERTIFIED',
  FALSE
);
```

Ratio metric:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  'ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC gross_margin_pct
  AS total_gross_margin / NULLIF(total_revenue, 0)
  ON ENTITY order_line
  RETURNS DECIMAL(18,6)
  FORMAT ''percent''
  DISPLAY ''Gross Margin %''
  COMMENT ''Gross margin as a percentage of net revenue''
  PUBLIC CERTIFIED',
  FALSE
);
```

## Import a Databricks UCMV

Use this path when the source model is a Databricks Unity Catalog Metric View
YAML. Dry-run first to inspect `GENERATED_DDL` and `DIAGNOSTICS_JSON`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(
  '<metric view YAML>',
  'sales_dbx',
  'SEMANTIC_SALES_DBX',
  FALSE
);
```

Apply after review:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(
  '<metric view YAML>',
  'sales_dbx',
  'SEMANTIC_SALES_DBX',
  TRUE
);
```

The host helper reads the YAML file and calls the same in-database importer:

```sh
python3 tools/import_databricks.py sql/examples/sales_databricks_metric_view.yaml \
  --model sales_dbx --schema SEMANTIC_SALES_DBX --apply
```

Supported imports include plain table/view sources, star and snowflake joins,
fields, aggregate measures, filtered measures, and derived/ratio measures using
`MEASURE()`. Review any `DBX_IMPORT_*` diagnostics before treating the imported
model as production-ready.

## Validate and Publish

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
```

Inspect all current issues:

```sql
SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
WHERE MODEL_NAME = 'sales'
ORDER BY SEVERITY, OBJECT_TYPE, OBJECT_NAME;
```

Inspect agent-visible blocking errors:

```sql
SELECT OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT
WHERE MODEL_NAME = 'sales';
```

Publish when clean:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales');
```

Verify that semantic context is visible after publication:

```sql
SELECT SCHEMA_NAME, SCHEMA_COMMENT
FROM EXA_ALL_SCHEMAS
WHERE SCHEMA_NAME = 'SEMANTIC_SALES';

SELECT VIEW_NAME, VIEW_COMMENT
FROM EXA_ALL_VIEWS
WHERE VIEW_SCHEMA = 'SEMANTIC_SALES';

SELECT FIELD_KIND, FIELD_NAME, DESCRIPTION
FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
WHERE MODEL_NAME = 'sales' AND OBJECT_NAME = 'SALES'
ORDER BY FIELD_KIND, FIELD_NAME;
```

## Add Agent Instructions

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'MODEL',
  'sales',
  'GENERAL',
  'All revenue metrics are reported in USD. Do not convert currencies.',
  NULL,
  10
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'METRIC',
  'completed_revenue',
  'DEFINITION',
  'Counts only orders with status COMPLETE. Excludes PENDING, CANCELLED, and RETURNED.',
  NULL,
  10
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'MODEL',
  'sales',
  'SAFETY',
  'Do not answer questions about individual customer PII. Aggregate to region or segment level only.',
  NULL,
  1
);
```

## Add Verified Queries

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY(
  'sales',
  'SALES',
  'Revenue by region this year',
  'What is total revenue by customer region this year?',
  '{"model":"sales","object":"SALES","metrics":["total_revenue"],"dimensions":["customer_region"],"filters":[{"field":"order_year","op":"=","value":2026}],"order_by":[{"field":"total_revenue","direction":"desc"}]}',
  '{"columns":["customer_region","total_revenue"],"grain":"one row per customer_region"}',
  TRUE
);
```

## Add Synonyms

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  'sales', 'METRIC', 'total_revenue', 'revenue', 'MANUAL'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  'sales', 'METRIC', 'gross_margin_pct', 'margin rate', 'MANUAL'
);
```

## Introspect the Model

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

SHOW SEMANTIC VIEWS;

SHOW SEMANTIC METRICS IN sales.SALES;

DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue;

SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue;

EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct;

EXPORT SEMANTIC METRIC sales.SALES.completed_revenue;

EXPORT SEMANTIC MODEL sales;
```

## Review Validation Run History

```sql
SELECT RUN_ID, MODEL_NAME, RUN_STATUS, STARTED_AT, ISSUE_COUNT
FROM SEMANTIC_CATALOG.VALIDATION_RUNS
WHERE MODEL_NAME = 'sales'
ORDER BY STARTED_AT DESC
LIMIT 10;
```
