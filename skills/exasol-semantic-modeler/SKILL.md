---
name: exasol-semantic-modeler
description: Use when an autonomous agent needs to create, bootstrap, or maintain an Exasol Semantic Views model. Covers schema inspection and autonomous metric derivation from physical tables, entity and relationship modelling, fact and dimension authoring, SQL-native metric DDL, model validation, publication, and governance configuration (agent instructions, verified queries, synonyms).
---

# Exasol Semantic Modeler

## Core Rule

The semantic layer encodes what the physical schema means. Before writing any
metric definition, understand the physical data — its grain, its relationships,
and the columns that carry business meaning. A well-derived model makes every
downstream agent query deterministic and governed. A poorly derived model
propagates ambiguity into every answer.

Prefer this order:

1. Inspect the physical schema and identify entities, relationships, and
   candidate facts.
2. Create the model and register entities, relationships, and dimensions.
3. Author metrics in order of dependency: additive first, then ratio/derived.
4. Validate and inspect issues after every structural change.
5. Publish when validation is clean; add governance metadata after publication.

Read [authoring-workflows.md](references/authoring-workflows.md) for copyable
SQL and script examples.

## Connection Requirements

All `SEMANTIC_ADMIN` scripts must be called with `EXECUTE SCRIPT`, not
`SELECT`. A full-privilege SQL connection (not a SELECT-only tool) is required
for all authoring, validation, and publication operations.

Discovery views in `SEMANTIC_AGENT` and `SEMANTIC_CATALOG` can be read with a
SELECT-only tool, but schema inspection (`EXA_ALL_COLUMNS`, `EXA_ALL_TABLES`)
also requires only SELECT.

## Autonomous Model Derivation

When building a model from scratch, derive the semantic structure from the
physical schema rather than asking the user to specify every field. Follow this
reasoning process:

### Step 1 — Inventory the physical schema

Query the target schema's tables and columns:

```sql
SELECT TABLE_NAME, TABLE_COMMENT, TABLE_ROW_COUNT
FROM EXA_ALL_TABLES
WHERE TABLE_SCHEMA = 'MART'
ORDER BY TABLE_NAME;

SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, COLUMN_COMMENT
FROM EXA_ALL_COLUMNS
WHERE COLUMN_SCHEMA = 'MART'
ORDER BY TABLE_NAME, ORDINAL_POSITION;
```

Sample a few rows from each candidate table to understand actual values:

```sql
SELECT * FROM MART.ORDERS LIMIT 5;
```

### Step 2 — Identify entities and their grain

An entity is a physical table with a clear, unique business grain. Signals:

- A column ending in `_ID`, `_KEY`, or `_CODE` that is unique — this is the
  primary key and defines the grain.
- Tables named as business nouns in plural (`ORDERS`, `ORDER_LINES`,
  `CUSTOMERS`, `PRODUCTS`) are strong entity candidates.
- Large row-count tables with numeric measure columns are **fact entities**
  (grain: one row = one transaction or event).
- Smaller tables with mostly categorical attributes are **dimension entities**
  (grain: one row = one entity instance such as a customer or product).

Choose a short, lowercase alias for each entity that matches the table's
business role: `ol` for order_line, `o` for order, `c` for customer.

### Step 3 — Identify relationships

Scan for columns that appear in more than one table with matching names and
types. These are join columns. Common patterns:

- A column named `ORDER_ID` in `ORDER_LINES` that matches the primary key
  `ORDER_ID` in `ORDERS` → many-to-one from order_line to order.
- A column named `CUSTOMER_ID` in `ORDERS` matching `CUSTOMER_ID` in
  `CUSTOMERS` → many-to-one from order to customer.

Determine cardinality:
- Fact-to-dimension join: almost always `MANY_TO_ONE` (many transactions per
  customer, many lines per order).
- Dimension-to-dimension join: `ONE_TO_ONE` or `MANY_TO_ONE` depending on
  hierarchy.
- `MANY_TO_MANY` requires an explicit fanout policy and should be used only
  when unavoidable.

### Step 4 — Derive facts from numeric columns

A fact is a row-level expression that can be meaningfully aggregated. For each
numeric column (`DECIMAL`, `FLOAT`, `INTEGER`):

| Column name pattern | Derived fact expression | Suggested metric |
|---------------------|------------------------|------------------|
| `*_amount`, `*_price`, `*_cost`, `*_revenue`, `*_value` | `alias.column` | `SUM(fact)` → ADDITIVE metric |
| `*_quantity`, `*_units`, `*_qty` | `alias.column` | `SUM(fact)` → ADDITIVE metric |
| Numeric ID (order_id, line_id) | `alias.column` | `COUNT(DISTINCT fact)` → use as ADDITIVE COUNT metric |

Compound facts (e.g. gross margin = revenue − cost) should be expressed as a
row-level fact expression (`ol.net_amount - ol.cost_amount`) so that multiple
metrics can reuse the same row-level value.

Do not create ratio facts. Ratios (margin rate, conversion rate, AOV) should
be **RATIO metrics** referencing two additive metrics, not facts.

### Step 5 — Derive dimensions from categorical and temporal columns

| Column type | Pattern | Dimension |
|-------------|---------|-----------|
| `VARCHAR`/`CHAR` low-cardinality | `status`, `type`, `category`, `region`, `country` | Categorical dimension |
| `DATE`/`TIMESTAMP` | `*_date`, `*_at`, `*_time` | Time dimension — create one per grain: year, quarter, month, week, day using `DATE_TRUNC` or `EXTRACT` |
| `VARCHAR` high-cardinality ID | `customer_id`, `product_id` | Generally **not** a dimension — too many values; use the human-readable name column instead |

For time columns, derive multiple dimensions from a single date column:

```
order_year   → EXTRACT('YEAR', o.order_date)
order_quarter → 'Q' || EXTRACT('QUARTER', o.order_date)
order_month  → DATE_TRUNC('MONTH', o.order_date)
order_week   → DATE_TRUNC('WEEK', o.order_date)
```

### Step 6 — Propose metrics in dependency order

Build metrics in this order to satisfy dependency resolution:

1. **ADDITIVE** (`SUM`, `COUNT`, `MAX`, `MIN`) — no dependencies.
2. **FILTERED** (`SUM … FILTER WHERE`) — depends on a filtered subset.
3. **RATIO** (`additive / NULLIF(additive, 0)`) — depends on two additives.
4. **DERIVED** (arithmetic over existing metrics) — depends on prior metrics.
5. **WINDOW** (`LAG`, `RANK`, period-over-period) — derived from additive +
   time dimension.

Propose names in `snake_case`. Write a business `COMMENT` for every metric —
downstream agents depend on descriptions to resolve ambiguity.

### Step 7 — Validate and iterate

After each structural change:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('<model>');
```

Inspect issues:

```sql
SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
WHERE MODEL_NAME = '<model>'
ORDER BY SEVERITY, OBJECT_TYPE, OBJECT_NAME;
```

Fix errors before adding further definitions. Warnings can be deferred but
should be resolved before publication.

## Bootstrap Sequence

When starting from zero, create objects in this order. Each step requires the
previous to succeed.

```
1. CREATE MODEL (name, description)
2. ADD_ENTITY (per entity — one per physical table)
3. ADD_RELATIONSHIP (per join — entities must exist)
4. ADD_FACT (per row-level expression — entities must exist)
5. ADD_DIMENSION (per dimension — entities must exist)
6. ADD OR REPLACE METRIC (per aggregate — facts must exist for ADDITIVE;
   metrics must exist for RATIO/DERIVED)
7. VALIDATE_MODEL
8. PUBLISH_MODEL
```

See [authoring-workflows.md](references/authoring-workflows.md) for the full
script syntax.

## Entity and Relationship Management

Register entities with `ADD_ENTITY`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  '<model>',       -- model name
  '<alias>',       -- short alias used in expressions (e.g. 'order_line')
  '<schema.table>',-- physical table (e.g. 'MART.ORDER_LINES')
  '<expr_alias>',  -- SQL alias in expressions (e.g. 'ol')
  '<pk_expr>',     -- primary key expression (e.g. 'ol.order_line_id')
  '<display_name>',
  '<description>'
);
```

Register relationships with `ADD_RELATIONSHIP`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP(
  '<model>',
  '<rel_name>',
  '<from_entity>',
  '<to_entity>',
  '<join_condition>',  -- e.g. 'ol.order_id = o.order_id'
  '<cardinality>',     -- MANY_TO_ONE | ONE_TO_ONE | ONE_TO_MANY | MANY_TO_MANY
  '<join_type>',       -- INNER | LEFT
  '<description>'
);
```

## Dimension Maintenance

Use the Lua admin script for all dimension changes. `ALTER SEMANTIC VIEW … ADD
OR REPLACE DIMENSION` is not yet supported in DDL.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  '<model>', '<object>', '<entity_alias>',
  '<dim_name>', '<expression>',
  '<data_type>', '<display_name>', '<description>',
  '<format_hint>', <is_certified>
);
```

## Metric Authoring

Use SQL-native DDL for metric authoring. Enable Semantic SQL for the session
first if using the DDL form:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
```

Single-metric add or replace:

```sql
ALTER SEMANTIC VIEW <model>.<object>
ADD OR REPLACE METRIC <metric_name>
  AS <aggregate-expression>
  ON ENTITY <base_entity>
  RETURNS <data_type>
  FORMAT '<format_hint>'
  DISPLAY '<display_name>'
  COMMENT '<business definition>'
  [ADDITIVE] [PUBLIC | PRIVATE] [CERTIFIED];
```

Filtered metric:

```sql
ALTER SEMANTIC VIEW <model>.<object>
ADD OR REPLACE METRIC <metric_name>
  AS SUM(<fact>)
  ON ENTITY <base_entity>
  RETURNS DECIMAL(18,2)
  FILTER (WHERE <dimension_name> = '<value>')
  FORMAT 'currency'
  DISPLAY '<display_name>'
  COMMENT '<definition>'
  ADDITIVE PUBLIC CERTIFIED;
```

Ratio metric:

```sql
ALTER SEMANTIC VIEW <model>.<object>
ADD OR REPLACE METRIC <metric_name>
  AS <numerator_metric> / NULLIF(<denominator_metric>, 0)
  ON ENTITY <base_entity>
  RETURNS DECIMAL(18,6)
  FORMAT 'percent'
  DISPLAY '<display_name>'
  COMMENT '<definition>'
  PUBLIC CERTIFIED;
```

Apply without session preprocessing using `APPLY_SEMANTIC_DEFINITION`. Always
dry-run first (`TRUE`), then apply (`FALSE`):

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('<semantic-sql>', TRUE);
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION('<semantic-sql>', FALSE);
```

Do not use `REPLACE METRICS (...)` unless deliberately replacing the entire
metric membership of an object (bootstrap or full reset only).

## Validation and Publication

Validate after every structural change:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('<model>');
```

Publish when validation is clean:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('<model>');
```

`PUBLISH_MODEL` validates internally and aborts if any errors remain.
Publishing creates the guarded views in `SEMANTIC_<MODEL>` schema.

## Governance Metadata

Add agent instructions after publication:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  '<model>',
  '<scope_type>',   -- MODEL | SEMANTIC_OBJECT | METRIC | DIMENSION | ENTITY | FACT
  '<scope_name>',
  '<kind>',         -- GENERAL | DEFINITION | AMBIGUITY | POLICY | PREFERENCE | SAFETY | STYLE
  '<instruction_text>',
  '<applies_to_role>',  -- NULL for all roles
  <priority>
);
```

Register verified queries:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY(
  '<model>', '<object>',
  '<business_question>',
  '<request_json_or_semantic_sql>',
  '<notes>'
);
```

Add synonyms so agents can discover metrics by alternative names:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  '<model>', '<object>', '<canonical_name>', '<synonym>', <is_certified>
);
```

## Introspection

After enabling Semantic SQL for the session:

```sql
SHOW SEMANTIC VIEWS;
SHOW SEMANTIC METRICS IN <model>.<object>;
DESCRIBE SEMANTIC METRIC <model>.<object>.<metric>;
SHOW SEMANTIC DIMENSIONS FOR METRIC <model>.<object>.<metric>;
EXPLAIN SEMANTIC METRIC <model>.<object>.<metric>;
EXPORT SEMANTIC METRIC <model>.<object>.<metric>;
EXPORT SEMANTIC VIEW <model>.<object>;
EXPORT SEMANTIC MODEL <model>;
```

## Safety

- Do not expose private metrics or hidden fields outside role-scoped views.
- Validate before publishing. Never call `PUBLISH_MODEL` without a clean
  `VALIDATE_MODEL` pass.
- Treat `REPLACE METRICS (...)` as destructive — it removes all metrics not
  listed. Use `ADD OR REPLACE METRIC` for incremental changes.
- Do not hardcode physical table column references in metric expressions when
  a fact exists — reuse the fact layer.
- Dry-run every `APPLY_SEMANTIC_DEFINITION` call before the live apply.
