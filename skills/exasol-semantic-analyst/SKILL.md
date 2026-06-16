---
name: exasol-semantic-analyst
description: Use when an autonomous agent needs to answer business questions through an existing Exasol Semantic Views model. Covers metric and dimension discovery, valid combination checking, structured request compilation with COMPILE_REQUEST_JSON, semantic SQL compilation including Databricks-style MEASURE()/GROUP BY ALL compatibility, result execution, plan explanation, and feedback capture. Assumes the semantic model is already built and published.
---

# Exasol Semantic Analyst

## Core Rule

Use the semantic layer as the source of truth. Do not infer joins, reconstruct
metric formulas, or write physical-table SQL when the request can be answered
through Exasol Semantic Views.

Prefer this order:

1. Discover available models, objects, and fields.
2. Check metric/dimension compatibility before compiling.
3. Compile a structured request with `COMPILE_REQUEST_JSON`.
4. Execute only the returned `GENERATED_SQL` under the caller's privileges.
5. Attach `PLAN_JSON` and `AGENT_REQUEST_ID` to the answer for traceability.
6. Record feedback after delivering results.

Read [query-workflows.md](references/query-workflows.md) for copyable SQL and
JSON examples.

## Connection Requirements

Compile, explain, and feedback entrypoints are Exasol Lua scripts. They must
be called with `EXECUTE SCRIPT`, not `SELECT`.

If your only available tool accepts only `SELECT`, use it for discovery through
`SEMANTIC_AGENT` views. Do not write physical-table SQL as a workaround. Ask
for a semantic adapter that exposes `COMPILE_REQUEST_JSON`,
`EXPLAIN_COMPILED_SQL`, and `RECORD_AGENT_FEEDBACK` as callable tools.

## Discovery

Before compiling, orient yourself through the role-scoped `SEMANTIC_AGENT`
views. Query only what you need — do not load all views on every request.

**Available models and readiness:**

```sql
SELECT MODEL_NAME, PUBLISHED_SCHEMA, AGENT_READINESS
FROM SEMANTIC_AGENT.MODELS_FOR_AGENT
WHERE AGENT_READINESS = 'VALID'
ORDER BY MODEL_NAME;
```

**Available objects in a model:**

```sql
SELECT OBJECT_NAME, ROOT_ENTITY_NAME, QUERY_MODES
FROM SEMANTIC_AGENT.OBJECTS_FOR_AGENT
WHERE MODEL_NAME = '<model>'
ORDER BY OBJECT_NAME;
```

**Metrics and dimensions with types and descriptions:**

```sql
SELECT FIELD_KIND, FIELD_NAME, DISPLAY_NAME, DATA_TYPE,
       FILTER_EXPRESSION, FORMAT_HINT, IS_CERTIFIED
FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
WHERE MODEL_NAME = '<model>'
  AND OBJECT_NAME = '<object>'
ORDER BY FIELD_KIND, FIELD_NAME;
```

**Compiler contract (accepted keys, operators, handle types):**

```sql
SELECT CONTRACT_SECTION, KEY_NAME, KEY_ALIAS, DESCRIPTION
FROM SEMANTIC_AGENT.COMPILE_REQUEST_SCHEMA_FOR_AGENT
ORDER BY DISPLAY_ORDER;
```

**Current blocking errors (stop if any exist for the target model):**

```sql
SELECT OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT
WHERE MODEL_NAME = '<model>';
```

**Business glossary and contextual instructions (inject into LLM context):**

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY(
  '<model>', '<object>', 'STRUCTURED_REQUEST'
);
```

**Full-text search across semantic objects:**

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS('<query>', '<model>');
```

Pass `NULL` as the model argument for cross-model search.

**Describe a single object:**

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT('<model>', '<object>');
```

## Checking Compatibility

Check the pre-computed compatibility matrix before building a multi-dimensional
request. This eliminates a class of trial-and-error compilation failures.

```sql
SELECT METRIC_NAME, DIMENSION_NAME, IS_VALID, REASON_CODE
FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT
WHERE MODEL_NAME = '<model>'
  AND OBJECT_NAME = '<object>'
  AND METRIC_NAME IN ('<metric1>', '<metric2>')
ORDER BY METRIC_NAME, DIMENSION_NAME;
```

Only include a metric/dimension pair in the request if `IS_VALID = TRUE`.

## Query Compilation

For all autonomous analytics, compile a structured request:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('<request-json>');
```

A standard request:

```json
{
  "model": "sales",
  "object": "SALES",
  "metrics": ["total_revenue", "gross_margin_pct"],
  "dimensions": ["customer_region", "order_month"],
  "filters": [
    {"field": "order_status", "op": "=", "value": "COMPLETE"}
  ],
  "order_by": [{"field": "total_revenue", "direction": "desc"}],
  "limit": 50,
  "client": "<your-agent-name>"
}
```

Filter field key aliases: `field`, `dimension`, `column`, `name`.
Operator key aliases: `op`, `operator`.
Supported operators: `=`, `!=`, `<>`, `>`, `>=`, `<`, `<=`, `LIKE`, `IN`,
`BETWEEN` (two-value array).
Text equality, `!=`, `LIKE`, and `IN` are compiled case-insensitively.
Metric predicates use the optional `having` array with the same object shape as
`filters`; each `having` entry must reference a metric.

The response row contains:

| Column | Use |
|--------|-----|
| `STATUS` | `OK` or `ERROR` |
| `ERROR_CODE` | Stable error namespace (e.g. `SEMANTIC_REQUEST_*`) |
| `ERROR_MESSAGE` | Human-readable error detail |
| `ORIGINAL_SQL` | Original semantic SQL text for `COMPILE_SQL`; `NULL` for `COMPILE_REQUEST_JSON` |
| `GENERATED_SQL` | Physical Exasol SQL to execute |
| `PLAN_JSON` | Metric roles, join paths, materialization decision |
| `CLARIFICATION_JSON` | Structured ambiguity prompt when fields are unclear |
| `VALIDATION_RUN_ID` | Validation snapshot used for this compile |
| `AGENT_REQUEST_ID` | Durable handle for explanation and feedback |

## Executing Results

When `STATUS = 'OK'`:

1. Execute `GENERATED_SQL` under the **caller's database privileges** — do not
   elevate.
2. Return results to the user along with relevant context from `PLAN_JSON`
   (e.g. whether a pre-computed materialization was used).
3. Keep `AGENT_REQUEST_ID` and `VALIDATION_RUN_ID` associated with the answer.

When `STATUS = 'ERROR'`:

- Report `ERROR_CODE` and `ERROR_MESSAGE`.
- If `CLARIFICATION_JSON` is present, present the structured choice to the
  user. Do not guess which field was meant.
- Do not fall back to physical-table SQL. Return the error.

## Semantic SQL Path

When the user has supplied semantic SQL directly, compile it explicitly rather
than relying on a session preprocessor. The SQL surface accepts selected
semantic fields, `SELECT *`, optional `GROUP BY` inference from selected
dimensions, `GROUP BY ALL`, metric predicates in `HAVING`, metric predicates in
`WHERE` auto-routed to `HAVING`, `BETWEEN`, selected-field aliases or ordinals
in `ORDER BY`, and Databricks-style `MEASURE(metric)` / `agg(metric)` wrappers
in `SELECT`, `HAVING`, and `ORDER BY`.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL(
  'SELECT customer_region, total_revenue
   FROM SEMANTIC_SALES.SALES
   WHERE order_status = ''COMPLETE''
   GROUP BY customer_region
   ORDER BY total_revenue DESC
   LIMIT 10'
);
```

An equivalent query may omit the explicit `GROUP BY`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL(
  'SELECT customer_region, total_revenue
   FROM SEMANTIC_SALES.SALES
   WHERE order_status = ''COMPLETE''
   ORDER BY total_revenue DESC
   LIMIT 10'
);
```

Databricks-style semantic SQL is also accepted against published semantic
objects:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL(
  'SELECT customer_region, MEASURE(total_revenue) AS total_revenue
   FROM SEMANTIC_SALES.SALES
   GROUP BY ALL
   HAVING MEASURE(total_revenue) > 1000
   ORDER BY MEASURE(total_revenue) DESC'
);
```

Use `COMPILE_SQL_DEBUG` only when the user needs a durable `QUERY_LOG_ID` for
later explanation or audit — it writes a log row and is not appropriate for
hot-path queries.

## Explaining Results

Use durable handles to explain a compiled request after the fact:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL('AGENT_REQUEST', <id>);
```

Use `QUERY_LOG` as the first argument for a `QUERY_LOG_ID` returned by
`COMPILE_SQL_DEBUG`.

## Feedback

Record a user verdict against a specific request rather than mutating the
catalog directly. This creates a reviewable suggestion queue.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK(
  'AGENT_REQUEST',
  <agent_request_id>,
  '<verdict>',
  '<comment>',
  '<proposed-change-json>'
);
```

Valid verdicts: `ACCEPTED`, `HELPFUL`, `NEEDS_CHANGE`, `NOT_HELPFUL`,
`REJECTED`.

Record `ACCEPTED` or `HELPFUL` when the user confirms the answer was correct —
positive signal is as important as negative.

## Request History

Review recent requests for the current session or user:

```sql
SELECT STARTED_AT, REQUEST_TIME, HANDLE_TYPE, HANDLE_ID,
       CLIENT_NAME, STATUS, ERROR_CODE
FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT
ORDER BY STARTED_AT DESC
LIMIT 20;
```

## Mapping Natural Language to Structured Requests

When translating a natural language question into a structured request:

1. **Identify metrics** — the thing being measured ("revenue", "margin",
   "count of orders"). Look for `FIELD_KIND = 'METRIC'` in `FIELDS_FOR_AGENT`.
2. **Identify dimensions** — how results should be grouped ("by region", "per
   month", "for each product"). Look for `FIELD_KIND = 'DIMENSION'`.
3. **Identify filters** — constraints on the data ("completed orders", "last
   quarter", "North region"). Map to dimension names and operator/value pairs.
4. **Identify sort and limit** — "top 10", "highest first".
5. **Check compatibility** — run `VALID_COMBINATIONS_FOR_AGENT` for every
   metric/dimension pair before compiling.
6. If a term is ambiguous (matches multiple fields), use `CLARIFICATION_JSON`
   from a test compile, or ask the user before building the request.

Time-based filters should use `BETWEEN` with a two-element array or `=` against
a `DATE_TRUNC`-based dimension rather than open-ended comparisons where
possible.

## Verified Queries

If the question closely matches a verified query, reference it as a starting
point:

```sql
SELECT QUERY_NAME, NATURAL_LANGUAGE_TEXT, REQUEST_JSON, GENERATED_SQL,
       EXPECTED_RESULT_SHAPE
FROM SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT
WHERE MODEL_NAME = '<model>'
ORDER BY QUERY_NAME;
```

Verified queries have been reviewed by the model owner. Prefer them over
constructing a novel request when the question is the same.

## Safety

- Execute `GENERATED_SQL` as the caller. Do not elevate privileges.
- Do not expose private or hidden fields. `FIELDS_FOR_AGENT` already filters
  by role — use only what appears there.
- Do not rewrite a failing semantic request as physical-table SQL. Return the
  structured error instead.
- Do not mutate catalog objects (metrics, dimensions, entities) from the
  analyst role. That is the modeler's responsibility.
- Treat the session preprocessor as syntax support, not a security boundary.
  Prefer `COMPILE_REQUEST_JSON` over relying on preprocessor state.
