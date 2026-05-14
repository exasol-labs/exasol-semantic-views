# Query Workflows

Use these examples when answering business questions through an Exasol
Semantic Views model. All `SEMANTIC_ADMIN` calls require `EXECUTE SCRIPT`.

## Check Model Readiness

```sql
SELECT MODEL_NAME, PUBLISHED_SCHEMA, AGENT_READINESS
FROM SEMANTIC_AGENT.MODELS_FOR_AGENT
WHERE AGENT_READINESS = 'VALID'
ORDER BY MODEL_NAME;
```

Stop if `AGENT_READINESS` is not `VALID`. Check blocking errors:

```sql
SELECT OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE
FROM SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT
WHERE MODEL_NAME = 'sales';
```

## Discover Available Fields

```sql
SELECT FIELD_KIND, FIELD_NAME, DISPLAY_NAME, DATA_TYPE,
       FILTER_EXPRESSION, FORMAT_HINT, IS_CERTIFIED
FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
WHERE MODEL_NAME = 'sales'
  AND OBJECT_NAME = 'SALES'
ORDER BY FIELD_KIND, FIELD_NAME;
```

`FILTER_EXPRESSION` is non-null for filtered metrics — it shows the semantic
filter that is always applied (e.g. `order_status = 'COMPLETE'`).

## Get Business Context

Inject the glossary into LLM context before building a request:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY(
  'sales', 'SALES', 'STRUCTURED_REQUEST'
);
```

Use `SEMANTIC_SQL` mode when helping a user write semantic SQL directly.

## Search for a Field by Name or Topic

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS('margin', 'sales');
```

Pass `NULL` as the second argument for cross-model search:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS('revenue', NULL);
```

## Check Metric/Dimension Compatibility

```sql
SELECT METRIC_NAME, DIMENSION_NAME, IS_VALID, REASON_CODE
FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT
WHERE MODEL_NAME = 'sales'
  AND OBJECT_NAME = 'SALES'
  AND METRIC_NAME IN ('total_revenue', 'gross_margin_pct')
ORDER BY METRIC_NAME, DIMENSION_NAME;
```

Only include a pair in the request if `IS_VALID = TRUE`.

## Compile a Structured Request — Additive Metric

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  '{
    "model": "sales",
    "object": "SALES",
    "metrics": ["total_revenue"],
    "dimensions": ["customer_region"],
    "filters": [
      {"field": "order_status", "op": "=", "value": "COMPLETE"}
    ],
    "order_by": [{"field": "total_revenue", "direction": "desc"}],
    "limit": 10,
    "client": "autonomous-agent"
  }'
);
```

## Compile a Structured Request — Multiple Metrics + Date Range

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  '{
    "model": "sales",
    "object": "SALES",
    "metrics": ["total_revenue", "gross_margin_pct"],
    "dimensions": ["customer_region", "order_month"],
    "filters": [
      {"field": "order_month", "op": "BETWEEN",
       "value": ["2026-01-01", "2026-03-31"]}
    ],
    "order_by": [
      {"field": "gross_margin_pct", "direction": "desc"}
    ],
    "limit": 50,
    "client": "autonomous-agent"
  }'
);
```

## Compile a Structured Request — IN Filter

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  '{
    "model": "sales",
    "object": "SALES",
    "metrics": ["total_revenue"],
    "dimensions": ["product_category"],
    "filters": [
      {"field": "customer_region", "op": "IN",
       "value": ["North", "West"]}
    ],
    "limit": 100,
    "client": "autonomous-agent"
  }'
);
```

## Compile Semantic SQL Explicitly

Use this when the user supplied semantic SQL and session preprocessor state
should not be assumed:

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

## Expected Response Shape

```text
STATUS
ERROR_CODE
ERROR_MESSAGE
GENERATED_SQL
PLAN_JSON
CLARIFICATION_JSON
VALIDATION_RUN_ID
AGENT_REQUEST_ID
```

When `STATUS = 'OK'`:
- Execute `GENERATED_SQL` under the caller's database privileges.
- Surface `PLAN_JSON` to show materialization decisions and join paths.
- Keep `AGENT_REQUEST_ID` for explanation and feedback.

When `STATUS = 'ERROR'`:
- Report `ERROR_CODE` and `ERROR_MESSAGE` to the user.
- If `CLARIFICATION_JSON` is non-null, present the structured choices rather
  than guessing.
- Do not fall back to physical-table SQL.

## Explain a Compiled Request

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL(
  'AGENT_REQUEST',
  <agent_request_id>
);
```

Use `QUERY_LOG` for `QUERY_LOG_ID` values returned by `COMPILE_SQL_DEBUG`.

## Review Recent Requests

```sql
SELECT STARTED_AT, REQUEST_TIME, HANDLE_TYPE, HANDLE_ID,
       CLIENT_NAME, STATUS, ERROR_CODE
FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT
ORDER BY STARTED_AT DESC
LIMIT 20;
```

## Check Verified Queries

```sql
SELECT QUESTION, REQUEST_JSON, NOTES
FROM SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT
WHERE MODEL_NAME = 'sales'
ORDER BY QUESTION;
```

## Record Feedback

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK(
  'AGENT_REQUEST',
  <agent_request_id>,
  'NEEDS_CHANGE',
  'The user expected completed revenue only, not total revenue.',
  '{"metric":"completed_revenue","reason":"user wanted COMPLETE orders only"}'
);
```

Record positive signal too:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK(
  'AGENT_REQUEST',
  <agent_request_id>,
  'ACCEPTED',
  'Answer confirmed correct by user.',
  NULL
);
```

Valid verdicts: `ACCEPTED`, `HELPFUL`, `NEEDS_CHANGE`, `NOT_HELPFUL`,
`REJECTED`.

## Measure Groups (Logical Metric Clusters)

When presenting available metrics to a user, group them by measure group:

```sql
SELECT GROUP_NAME, FIELD_NAME, DISPLAY_NAME, DATA_TYPE
FROM SEMANTIC_AGENT.MEASURE_GROUPS_FOR_AGENT
WHERE MODEL_NAME = 'sales'
  AND OBJECT_NAME = 'SALES'
ORDER BY GROUP_NAME, FIELD_NAME;
```
