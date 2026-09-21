# Creating Metrics

This guide explains how to create metrics in Exasol Semantic Views. It uses the
sales example from `sql/examples/sales_model_seed.sql`, but the same pattern
applies to any semantic model.

Metrics are not just SQL snippets. A good metric definition needs:

- a base business grain
- row-level facts to aggregate
- a clear aggregate expression
- valid dimensions for grouping and filtering
- privacy and certification metadata
- validation before use
- agent-readable names, descriptions, and examples

The semantic layer stores all of that in Exasol catalog tables. The preferred
authoring surface is SQL-native Semantic SQL, implemented by the Lua
preprocessor and persisted by Lua admin scripts. The older positional
`SEMANTIC_ADMIN.ADD_*` scripts remain compatibility APIs and are still useful
for bootstrap scripts and small migrations.

## The Mental Model

Metric authoring has three layers:

```text
Entity
  -> row-level facts
  -> aggregate metrics
  -> published semantic object
```

For the sales model:

```text
order_line entity
  -> net_revenue, net_cost, quantity facts
  -> total_revenue, total_cost, gross_margin metrics
  -> SEMANTIC_SALES.SALES semantic object
```

Facts are row-level expressions. Metrics are aggregate answers.

That distinction matters. A row-level expression such as
`ol.quantity * ol.net_unit_price` is not a metric yet. It becomes a metric only
when the semantic layer knows how to aggregate it, which dimensions are safe,
and how it should be exposed to users and agents.

## Prerequisites

Before creating metrics, create the surrounding model pieces:

1. A model, such as `sales`.
2. A semantic object, such as `SALES`.
3. One or more entities, such as `order_line`, `order`, `customer`, and
   `product`.
4. Relationships between entities.
5. Dimensions that users can group and filter by.

The sales seed file does this before adding facts and metrics:

```text
sql/examples/sales_model_seed.sql
```

When a script-based setup needs to add a dimension, use the compatibility API:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales',
  'SALES',
  'order',
  'order_quarter',
  'CAST(YEAR(o.order_date) AS VARCHAR(4)) || ''-Q'' || TO_CHAR(o.order_date, ''Q'')',
  'VARCHAR(7)',
  'Order Quarter',
  'Calendar quarter of the order',
  NULL,
  FALSE
);
```

`ADD_DIMENSION` takes:

```text
MODEL_NAME
OBJECT_NAME
ENTITY_NAME
DIMENSION_NAME
EXPRESSION
DATA_TYPE
DISPLAY_NAME
DESCRIPTION
FORMAT_HINT
IS_CERTIFIED
```

If active alternate representations use different expressions, call
`ADD_DIMENSION_WITH_BINDINGS` instead. Its final `BINDINGS_JSON` argument must
bind every non-partitioned alternate so creation and validation remain atomic.
F3 partitions inherit the top-level expression automatically.

## Recommended: SQL-Native Metric Definitions

For bootstrap or full object regeneration, define facts and metrics in one
Semantic SQL block:

```sql
ALTER SEMANTIC VIEW sales.SALES
REPLACE FACTS (
  FACT net_revenue
    ON ENTITY order_line
    AS ol.quantity * ol.net_unit_price
    RETURNS DECIMAL(18,2)
    ADDITIVE
    DISPLAY 'Net Revenue'
    COMMENT 'Net recognized revenue excluding tax'
    PUBLIC CERTIFIED
)
REPLACE METRICS (
  METRIC total_revenue
    AS SUM(net_revenue)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FORMAT 'currency'
    DISPLAY 'Total Revenue'
    COMMENT 'Net recognized revenue excluding tax'
    SYNONYMS ('revenue', 'sales')
    ADDITIVE PUBLIC CERTIFIED,

  METRIC completed_revenue
    AS SUM(net_revenue)
    ON ENTITY order_line
    RETURNS DECIMAL(18,2)
    FILTER (WHERE order_status = 'COMPLETE')
    FORMAT 'currency'
    DISPLAY 'Completed Revenue'
    COMMENT 'Net revenue for completed orders only'
    ADDITIVE PUBLIC CERTIFIED
);
```

`REPLACE DIMENSIONS`, `REPLACE FACTS` and `REPLACE METRICS` replace the
dimension, fact or metric membership of the semantic object. They are appropriate for bootstrap,
complete model regeneration, and deliberate resets. For one definition, use the
single forms instead, which upsert it and leave the object's other facts and
metrics in place:

```sql
ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE FACT gross_line_amount
  ON ENTITY order_line
  AS ol.quantity * ol.net_unit_price
  RETURNS DECIMAL(18,2)
  ADDITIVE
  DISPLAY 'Gross Line Amount'
  COMMENT 'Line amount before discounts'
  PUBLIC CERTIFIED;
```

Omitted definitions remain in the model catalog; use `DROP METRIC` for metric
removal. Fact removal has no DDL form yet — it waits until dependent-metric
rewrites are transactional.
Within one replacement block, a requested synonym is released from its prior
metric owner before assignment. Repeating that synonym on multiple metrics in
the block remains an ambiguity and fails with `SEMANTIC_MODEL_021`.

```sql
ALTER SEMANTIC VIEW sales.SALES
RENAME METRIC total_revenue TO gross_merchandise_value;

ALTER SEMANTIC VIEW sales.SALES
DROP METRIC obsolete_revenue;
```

Rename preserves the metric ID, updates dependent metric expressions, and
keeps the old name as a synonym. Drop removes the named object's membership and
deactivates the metric after its final membership is removed. Both operations
validate atomically and roll back when they would leave an invalid model.

A dropped metric is deactivated, not deleted: it stays in
`SEMANTIC_CATALOG.METRICS` and `SEMANTIC_CATALOG.METRIC_OVERVIEW` with
`STATUS = 'INACTIVE'` and, once its last membership is gone, `OBJECT_NAME` of
`NULL`. That row is the record of the definition, so filter on
`STATUS = 'ACTIVE'` for the live surface. Dropping it a second time is refused
with `SEMANTIC_DDL_080`, which names which of the three states applies — already
dropped, active but a column of a different semantic view (the other view is
named), or no such metric in the model.

### Dimension names are unique per model

A dimension belongs to an *entity* and is exposed by one or more semantic views,
but its **name is unique across the whole model**, not per view. Two views in
the same model therefore cannot both expose a column called `order_month`, even
when both legitimately need it — the second `ADD_DIMENSION` is refused with
`SEMANTIC_ADMIN_019`, naming the view that already owns it:

```
SEMANTIC_ADMIN_019: duplicate dimension: ship_mode. Dimension names are unique
per model, not per semantic view, so this name is taken. It is defined on entity
'order' and exposed by semantic view(s): SALES. Choose a distinct name for this
view's column; there is no operation that shares one dimension between views.
```

Give the second view's column a distinct name (`header_ship_mode`), or model the
two views so they do not need the same one. If a view ends up with metrics and no
dimensions because its dimensions were refused, validation now says so
(`SEMANTIC_MODEL_058`) instead of publishing a single grand-total column
quietly.

### Names that collide with SQL keywords

Any name position in a statement accepts a double-quoted identifier, which is
how a name that collides with a reserved word is written. The demo model's
`order` entity is one:

```sql
ALTER SEMANTIC VIEW "sales"."ORDER_HEADER"
ADD OR REPLACE FACT freight ON ENTITY "order"
  AS o.freight_amount RETURNS DECIMAL(18,2) ADDITIVE PUBLIC;
```

Quoting selects the name, it does not widen what a name may be: the quoted text
still has to be a valid identifier, so `"order line"` is refused with
`SEMANTIC_DDL_002`.

When Semantic SQL is enabled, Exasol routes that statement through the
preprocessor:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
```

The direct fallback is useful for CI and bootstrap sessions:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  '<ALTER SEMANTIC VIEW ...>',
  FALSE
);
```

Pass `TRUE` as the dry-run flag during review. It snapshots the model, simulates
the definition, runs `VALIDATE_MODEL`, and restores the snapshot. A valid
proposal returns `DRY_RUN`; an invalid proposal returns `ERROR` with the
blocking rule and object. The validation run remains in history, but proposed
semantic definitions are not committed.

Because this fallback passes Semantic SQL as a SQL string literal, any single
quotes inside the definition must be doubled. Enabling Semantic SQL and running
`ALTER SEMANTIC VIEW` directly avoids that string-literal escaping step.

`RATIO` accepts either references to two aggregate metrics or a division whose
numerator and denominator are aggregate expressions. For example:

```sql
METRIC avg_line_value
  AS SUM(line_revenue) / SUM(line_units)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  RATIO PUBLIC CERTIFIED
```

If an apply fails model validation, the admin runtime rejects the definition and
restores the previous catalog state. Check
`SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES` for the latest validation details.
Semantic SQL statements also raise the apply error to the SQL client; direct
calls to `APPLY_SEMANTIC_DEFINITION` return the same error as a structured
`STATUS = 'ERROR'` result row.

For single-metric edits, use:

```sql
ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC total_revenue
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  FORMAT 'currency'
  DISPLAY 'Total Revenue'
  COMMENT 'Net recognized revenue excluding tax'
  SYNONYMS ('revenue', 'sales')
  ADDITIVE PUBLIC CERTIFIED;
```

Semantic filters should reference semantic dimensions, not physical aliases:

```sql
FILTER (WHERE order_status = 'COMPLETE')
```

The admin runtime stores both the semantic filter and the resolved SQL filter
so the compiler can keep generating Exasol-compatible SQL.

## Reviewing Metrics

Use Semantic SQL introspection to inspect the catalog in the same vocabulary as
the definitions:

```sql
SHOW SEMANTIC METRICS IN sales.SALES;

DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue;

SHOW SEMANTIC DIMENSIONS FOR METRIC sales.SALES.total_revenue;

EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct;

EXPORT SEMANTIC METRIC sales.SALES.total_revenue;
```

`SHOW` and `DESCRIBE` are intended for model review and discovery.
`EXPLAIN` shows lineage, compatibility, and validation context. `EXPORT`
returns canonical Semantic SQL that can be reapplied.

The direct export script has the same data underneath the SQL-native commands:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', NULL, NULL);
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', 'DIMENSION');
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', 'total_revenue');
```

The third argument is either a metric name or one of the definition-kind filters
`ENTITY`, `RELATIONSHIP`, `FACT`, `DIMENSION`, or `METRIC`.

## Compatibility API

The script examples below show the lower-level compatibility API. They map to
the same catalog tables, but new documentation and model reviews should prefer
the SQL-native form above.

## Step 1: Create Row-Level Facts

Facts are reusable numeric expressions at an entity grain. They are normally
created on the entity where the expression is naturally true.

For revenue, the natural grain is `order_line`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'net_revenue',
  'ol.quantity * ol.net_unit_price',
  'DECIMAL(18,2)',
  'ADDITIVE',
  'Net Revenue',
  'Net recognized revenue excluding tax',
  FALSE,
  TRUE
);
```

For cost:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT(
  'sales',
  'order_line',
  'net_cost',
  'ol.quantity * ol.unit_cost',
  'DECIMAL(18,2)',
  'ADDITIVE',
  'Net Cost',
  'Cost recognized for sold units',
  FALSE,
  TRUE
);
```

`ADD_FACT` takes:

```text
MODEL_NAME
ENTITY_NAME
FACT_NAME
EXPRESSION
DATA_TYPE
ADDITIVE_POLICY
DISPLAY_NAME
DESCRIPTION
IS_PRIVATE
IS_CERTIFIED
```

If active alternate representations use different fact expressions, call
`ADD_FACT_WITH_BINDINGS` instead. Its final `BINDINGS_JSON` argument must bind
every non-partitioned alternate; F3 partitions inherit the top-level
expression. Use the literal expression `NULL` only when an alternate genuinely
lacks the fact.

Important choices:

- `EXPRESSION` is row-level Exasol SQL using the source alias of the entity.
  In the sales model, `order_line` uses alias `ol`.
- `ADDITIVE_POLICY` is one of `ADDITIVE`, `SEMI_ADDITIVE`, or
  `NON_ADDITIVE`.
- `IS_PRIVATE` hides implementation details from direct public use.
- `IS_CERTIFIED` marks the fact as reviewed and trustworthy.

Facts are useful because multiple metrics can depend on the same row-level
logic. If the expression changes, the metric definitions do not need to repeat
the physical formula.

## Step 2: Create Additive Metrics

An additive metric is the simplest and most common metric form. It aggregates a
fact with an aggregate function such as `SUM`.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(
  'sales',
  'SALES',
  'total_revenue',
  'SUM(net_revenue)',
  NULL,
  'ADDITIVE',
  'order_line',
  'DECIMAL(18,2)',
  'Total Revenue',
  'Net recognized revenue excluding tax',
  'currency',
  FALSE,
  TRUE
);
```

`ADD_METRIC` takes:

```text
MODEL_NAME
OBJECT_NAME
METRIC_NAME
EXPRESSION
FILTER_EXPR
METRIC_TYPE
BASE_ENTITY_NAME
DATA_TYPE
DISPLAY_NAME
DESCRIPTION
FORMAT_HINT
IS_PRIVATE
IS_CERTIFIED
```

The important fields are:

- `OBJECT_NAME`: the semantic object that exposes the metric.
- `EXPRESSION`: an aggregate expression over semantic facts or other metrics.
- `FILTER_EXPR`: an optional row filter for filtered metrics.
- `METRIC_TYPE`: one of `ADDITIVE`, `RATIO`, `DISTINCT`, `SEMI_ADDITIVE`,
  `WINDOW`, or `DERIVED`.
- `BASE_ENTITY_NAME`: the entity grain where the metric starts.
- `FORMAT_HINT`: a display hint such as `currency`, `percentage`, or `count`.

`ADD_METRIC` returns a confirmation row with the metric id, model, object,
metric name, privacy/certification flags, and whether the semantic object
column was registered. The operation validates the model before returning. If
the metric expression is invalid, the inserted metric and object column are
rolled back and the script fails with a validation error, so callers do not get
active invalid metrics that break compilation.

Implementation note: the current compiler path is implemented and tested for
additive, filtered, derived, and ratio metrics. The catalog accepts `DISTINCT`,
`SEMI_ADDITIVE`, and `WINDOW` so those semantics can be represented, but treat
them as later compiler work unless your deployment has added the corresponding
runtime behavior.

Create cost the same way:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(
  'sales',
  'SALES',
  'total_cost',
  'SUM(net_cost)',
  NULL,
  'ADDITIVE',
  'order_line',
  'DECIMAL(18,2)',
  'Total Cost',
  'Cost recognized for sold units',
  'currency',
  FALSE,
  TRUE
);
```

## Step 3: Create Derived Metrics

Derived metrics combine other aggregate metrics. They should be written over
semantic metric names, not by repeating physical table expressions.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(
  'sales',
  'SALES',
  'gross_margin',
  'total_revenue - total_cost',
  NULL,
  'DERIVED',
  'order_line',
  'DECIMAL(18,2)',
  'Gross Margin',
  'Total revenue minus total cost',
  'currency',
  FALSE,
  TRUE
);
```

This lets the compiler expand the dependency tree safely:

```text
gross_margin
  -> total_revenue
     -> net_revenue
  -> total_cost
     -> net_cost
```

Validation checks that dependencies resolve and that the graph is acyclic.

## Step 4: Create Ratio Metrics

Ratio metrics should be formulas over aggregate metrics. Do not calculate a
row-level ratio and then average it unless that is the explicit business
definition.

Correct:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(
  'sales',
  'SALES',
  'gross_margin_pct',
  'gross_margin / NULLIF(total_revenue, 0)',
  NULL,
  'RATIO',
  'order_line',
  'DECIMAL(18,6)',
  'Gross Margin %',
  'Gross margin as a percentage of revenue',
  'percentage',
  FALSE,
  TRUE
);
```

This compiles as:

```text
SUM(revenue) - SUM(cost)
------------------------
       SUM(revenue)
```

That is different from:

```text
AVG((revenue - cost) / revenue)
```

The first is usually the correct metric. The second weights each row equally and
can produce misleading results.

## Step 5: Create Filtered Metrics

A filtered metric applies a row filter before aggregation. The current runtime
uses Exasol-compatible `CASE` expansion rather than aggregate `FILTER` syntax.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC(
  'sales',
  'SALES',
  'completed_revenue',
  'SUM(net_revenue)',
  'o.order_status = ''COMPLETE''',
  'ADDITIVE',
  'order_line',
  'DECIMAL(18,2)',
  'Completed Revenue',
  'Net revenue for completed orders only',
  'currency',
  FALSE,
  TRUE
);
```

The compiled aggregate uses the filter inside the aggregate expression:

```sql
SUM(CASE WHEN o.order_status = 'COMPLETE' THEN <net_revenue expression> ELSE NULL END)
```

In SQL-native definitions, prefer `FILTER (WHERE order_status = 'COMPLETE')`
over physical alias syntax. The admin runtime resolves semantic dimensions to
SQL and records the filter dimension for compatibility and materialization
planning. In the compatibility API, `FILTER_EXPR` remains a physical SQL escape
hatch over source aliases such as `o.order_status = 'COMPLETE'`.

## Step 6: Add Synonyms For Discovery

Synonyms help users and agents find the right metric without changing the
canonical metric name.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM(
  'sales',
  'METRIC',
  'total_revenue',
  'revenue',
  'MANUAL'
);
```

Use synonyms for common business terms, abbreviations, and natural-language
phrases. Keep the canonical metric name stable and precise.

The second argument is the semantic object type, not the semantic view name.
Common values are `METRIC`, `DIMENSION`, `FACT`, `ENTITY`, and
`SEMANTIC_OBJECT`.

## Step 7: Validate The Model

After creating facts and metrics, validate the model:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
```

Validation persists:

- validation runs
- validation issues
- metric dependencies
- valid metric/dimension combinations

The compiler uses those outputs to reject unsafe queries before generating SQL.

Useful metadata checks:

```sql
SELECT SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
WHERE MODEL_NAME = 'sales'
ORDER BY SEVERITY, OBJECT_TYPE, OBJECT_NAME;

SELECT METRIC_NAME, EXPRESSION, FILTER_EXPR, METRIC_TYPE
FROM SEMANTIC_CATALOG.METRICS
WHERE MODEL_NAME = 'sales'
ORDER BY METRIC_NAME;

SELECT METRIC_NAME, DIMENSION_NAME, IS_VALID, REASON_CODE
FROM SEMANTIC_CATALOG.METRIC_DIMENSION_MATRIX
WHERE MODEL_NAME = 'sales'
ORDER BY METRIC_NAME, DIMENSION_NAME;
```

## Step 8: Query The Metric

After publishing and enabling semantic SQL, users can query metrics as columns:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
GROUP BY customer_region
ORDER BY total_revenue DESC
LIMIT 5;
```

Agents should prefer structured requests:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  '{
    "model": "sales",
    "object": "SALES",
    "metrics": ["gross_margin_pct"],
    "dimensions": ["order_month"],
    "filters": [
      {"field": "order_status", "op": "=", "value": "COMPLETE"}
    ],
    "order_by": [{"field": "order_month", "direction": "asc"}],
    "client": "metrics-guide"
  }'
);
```

The response includes generated SQL and plan JSON so the caller can explain
which metrics, dimensions, joins, validation run, and warnings were involved.
Filter objects also accept `dimension`, `column`, or `name` as aliases for
`field`, and `operator` as an alias for `op`. Supported operators are `=`,
`!=`, `<>`, `>`, `>=`, `<`, `<=`, `LIKE`, `IN`, `BETWEEN`, `IS NULL`, and
`IS NOT NULL`; `BETWEEN` uses a two-value array, while null predicates omit
`value` and `value_sql`.

## Metric Design Guidelines

Use these rules when adding metrics:

1. Start with the business definition, not the SQL expression.
2. Identify the base entity and grain before writing the aggregate.
3. Put row-level math in facts.
4. Put aggregate math in metrics.
5. Define ratios over aggregate metrics, not row-level ratios.
6. Use filtered metrics for named business subsets that appear repeatedly.
7. Keep private helper facts and metrics private.
8. Add descriptions and format hints for every public certified metric.
9. Add synonyms only when they reduce real user ambiguity.
10. Run validation after changing facts, metrics, dimensions, or relationships.

## Common Metric Patterns

| Pattern | Example | Recommended Shape |
| --- | --- | --- |
| Sum | Total revenue | `SUM(net_revenue)` over an additive fact |
| Count | Order count | `COUNT(order_id)` or a dedicated count fact |
| Distinct count | Active customers | `COUNT(DISTINCT customer_id)` with `DISTINCT` metric type |
| Filtered sum | Completed revenue | `SUM(net_revenue)` plus `FILTER (WHERE order_status = 'COMPLETE')` |
| Difference | Gross margin | `total_revenue - total_cost` as `DERIVED` |
| Percentage | Gross margin % | `gross_margin / NULLIF(total_revenue, 0)` as `RATIO` |
| Private helper | Cost component | private fact or metric used by certified public metrics |

## When A Model Has To Split By Grain, And What It Costs

A metric aggregates at its base entity's grain. If that entity is *coarser* than
the semantic view's root, the join repeats each row and the aggregate is
multiplied by the fan-out — so `SEMANTIC_MODEL_059` refuses it, and the remedy is
to expose that metric in a second semantic view rooted at its own entity. The
reference model does exactly this: `SALES` is rooted at the order line and
`ORDER_HEADER` at the order, because freight is charged per order and cannot be
attributed to a line.

That is a sound rule. What is easy to miss is that **three further rules follow
from it**, and an author currently meets them one at a time, each in a different
place:

| you try | you get |
|---|---|
| add the same dimension to both views, so each can be sliced the same way | `SEMANTIC_ADMIN_019` — dimension names are unique per *model*, not per view, and there is no operation that shares one between views |
| ask for a field of the other view | `SEMANTIC_QUERY_020` — naming the view that does have it |
| join the two published views to put the numbers side by side | `SEMANTIC_QUERY_012` — the join can repeat rows and re-aggregation double-counts |

So one business question — *"revenue and freight by region"* — becomes two
queries, and slicing both by region needs two differently named dimensions over
the same column (`customer_region` on one view, `order_customer_region` on the
other). That is the design working as intended: the alternative is a single view
that answers the question with a number inflated by the fan-out. But it is worth
knowing at design time rather than discovering across three refusals.

If you get the shape wrong, `REMOVE_SEMANTIC_OBJECT(model, object)` takes a view
back out — with the dimensions and metrics it exposes, freeing their names, and
dropping its published view. Facts and entities stay, because a fact belongs to
an entity and may feed other views. This matters more than tidiness: a semantic
view with no visible columns cannot be published at all
(`SEMANTIC_SURFACE_014`), so before this existed a single mistyped
`ADD_SEMANTIC_OBJECT` left a model that could neither be published nor repaired
except by dropping it.

**What to decide up front:**

- Which grains does this model genuinely have? Each one is a semantic view.
- Which dimensions does each need? Name them per view from the start
  (`order_ship_mode`, `line_product_category`) rather than discovering the
  collision when the second view is authored.
- Is the split real? A metric that *can* be evaluated at the finer root belongs
  in the one view. Only a genuinely coarser aggregate forces the split.

Joining the two views is refused by default, not forbidden: a model that accepts
ordinary-SQL semantics can opt in with `SET_MODEL_DERIVED_COMPOSITION`, which
means accepting that a join may repeat rows. See
[data fusion](data-fusion.md) for combining *sources* for one entity, which is a
different problem from combining *grains*.

`tools/verify_fanout_guardrails.py` asserts each of the four steps above, so this
section cannot drift from what the layer does.

## Common Mistakes

### Repeating Physical SQL In Every Metric

Avoid this:

```text
SUM(ol.quantity * ol.net_unit_price)
```

Prefer this:

```text
fact net_revenue = ol.quantity * ol.net_unit_price
metric total_revenue = SUM(net_revenue)
```

The second form creates reusable dependency metadata and makes later changes
safer.

### Averaging Row-Level Percentages

Avoid this unless the business explicitly wants an unweighted row average:

```text
AVG((net_revenue - net_cost) / net_revenue)
```

Prefer:

```text
gross_margin / NULLIF(total_revenue, 0)
```

### Skipping Validation

Do not publish or query new metrics until validation succeeds. Validation is
what creates the dependency and compatibility metadata used by the compiler,
preprocessor, and agent context.

### Exposing Helper Fields

Implementation details should stay private. For example, a public
`gross_margin_pct` metric can depend on a private cost fact, but users should
not necessarily be able to query the raw cost field directly.

## Troubleshooting

`SEMANTIC_ADMIN_003: invalid METRIC_TYPE`

Use one of `ADDITIVE`, `RATIO`, `DISTINCT`, `SEMI_ADDITIVE`, `WINDOW`, or
`DERIVED`.

`METRIC_002: dependencies resolve`

The metric expression references a fact, metric, dimension, or function that
the validator cannot resolve. Check spelling and whether the dependency exists
in the active model version.

`METRIC_003: dependency graph is acyclic`

A metric depends on itself directly or indirectly. Break the cycle by moving
shared logic into a fact or helper metric.

`SEMANTIC_QUERY_003: metric cannot be grouped by invalid dimension`

The metric/dimension pair is not valid according to the persisted compatibility
matrix. Check the relationship path and entity grain: the reason code names the
edge that blocks the join. No fanout policy makes a fanning traversal valid --
see [Fanout policy](validation-rules.md#fanout-policy).

`SEMANTIC_QUERY_008: row-level facts cannot be mixed with aggregate metrics`

The query selected row-level facts and aggregate metrics together. Use
dimensions plus metrics, or query row-level fields separately.

## Where To Look Next

- [Semantic catalog](semantic-catalog.md)
- [Semantic catalog](semantic-catalog.md)
- [Semantic compiler](semantic-compiler.md)
- [Validation rules](validation-rules.md)
- [Agent contract](agent-contract.md)
- [Sales model seed](../sql/examples/sales_model_seed.sql)
