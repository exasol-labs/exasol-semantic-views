# Agent Contract

Milestone 5 installs the first agent-facing database contract.

Agents should discover semantic context through `SEMANTIC_AGENT` views and
compile structured requests through `SEMANTIC_ADMIN.COMPILE_REQUEST_JSON`.
External MCP, REST, or application agents should wrap this database contract
without duplicating semantic logic outside Exasol.

All `SEMANTIC_ADMIN` entrypoints listed here are Lua scripts. Call them with
`EXECUTE SCRIPT`, not `SELECT`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('<request-json>');
```

A generic SQL tool that accepts only `SELECT` statements can inspect the
`SEMANTIC_AGENT` and `SEMANTIC_CATALOG` views, but it cannot compile requests,
enable Semantic SQL, explain compiled handles, or record feedback. MCP and REST
adapters should expose dedicated semantic tools for those script calls.

Milestone 4 adds a second deterministic surface for SQL clients:
`SEMANTIC_ADMIN.COMPILE_SQL`. Autonomous agents should still prefer structured
requests, but adapters that accept SQL should compile SQL explicitly and execute
the returned generated SQL. They should not depend on a session preprocessor
being active unless they are intentionally emulating a BI session.

The database must validate, compile, explain, and log requests
deterministically. It must not call an LLM.

Compiler responses should include the validation run or validation status used
to bind the request. Agents should treat missing or failed validation as a hard
stop, not as a hint to generate SQL themselves.

## Views

- `SEMANTIC_AGENT.MODELS_FOR_AGENT`
- `SEMANTIC_AGENT.OBJECTS_FOR_AGENT`
- `SEMANTIC_AGENT.FIELDS_FOR_AGENT`
- `SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT`
- `SEMANTIC_AGENT.MEASURE_GROUPS_FOR_AGENT`
- `SEMANTIC_AGENT.VERIFIED_QUERIES_FOR_AGENT`
- `SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT`
- `SEMANTIC_AGENT.BUSINESS_GLOSSARY_FOR_AGENT`
- `SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT`
- `SEMANTIC_AGENT.COMPILE_REQUEST_SCHEMA_FOR_AGENT`
- `SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT`

These views expose both canonical semantic names and published SQL surface names
where relevant, so adapters do not need to infer Exasol identifier casing rules.
`FIELDS_FOR_AGENT` exposes both `FIELD_KIND` and the compatibility alias
`FIELD_ROLE`, plus semantic and resolved SQL filter expressions for filtered
metrics. `VALIDATION_ERRORS_FOR_AGENT` exposes the latest role-visible blocking
validation errors. `COMPILE_REQUEST_SCHEMA_FOR_AGENT` exposes the accepted
request keys, filter aliases, operators, order fields, handle types, and enum
values as rows. `REQUEST_HISTORY_FOR_AGENT` exposes both `STARTED_AT` and the
compatibility alias `REQUEST_TIME`.

## Scripts

- `SEMANTIC_ADMIN.COMPILE_REQUEST_JSON`
- `SEMANTIC_ADMIN.COMPILE_SQL`
- `SEMANTIC_ADMIN.COMPILE_SQL_DEBUG`
- `SEMANTIC_ADMIN.VALIDATE_MODEL`
- `SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION`
- `SEMANTIC_ADMIN.ADD_VERIFIED_QUERY`
- `SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS`
- `SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT`
- `SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY`
- `SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL`
- `SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK`

Common signatures:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('<request-json>');

EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL('<semantic-sql>');

EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS(
  '<query_text>',
  '<model_or_null>'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT(
  '<model>',
  '<object>'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY(
  '<model>',
  '<object>',
  '<STRUCTURED_REQUEST_or_SEMANTIC_SQL>'
);

EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  '<model>',
  '<scope_type>',
  '<scope_name>',
  '<instruction_kind>',
  '<instruction_text>',
  '<applies_to_role>',
  <priority>
);

EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK(
  '<handle_type>',
  <handle_id>,
  '<verdict>',
  '<comment_text>',
  '<proposed_change_json>'
);
```

`SEARCH_SEMANTIC_OBJECTS` requires both parameters. Pass `NULL` as the model
parameter for cross-model search. `GET_BUSINESS_GLOSSARY` requires all three
parameters so the database can return mode-specific guidance.

Valid feedback verdicts are `ACCEPTED`, `HELPFUL`, `NEEDS_CHANGE`,
`NOT_HELPFUL`, and `REJECTED`. Other values are rejected so downstream review
queues can rely on a stable vocabulary.

Instruction scope types include `MODEL`, `SEMANTIC_OBJECT`, `METRIC`,
`DIMENSION`, `ENTITY`, and `FACT`. Instruction kinds include `GENERAL`,
`AMBIGUITY`, `DEFINITION`, `POLICY`, `PREFERENCE`, `SAFETY`, and `STYLE`.

## Structured Request Shape

Autonomous agents should prefer this JSON form:

```json
{
  "model": "sales",
  "object": "SALES",
  "metrics": ["total_revenue"],
  "dimensions": ["customer_region"],
  "filters": [
    {"field": "order_status", "op": "=", "value": "COMPLETE"}
  ],
  "order_by": [
    {"field": "total_revenue", "direction": "desc"}
  ],
  "limit": 100,
  "client": "agent-name"
}
```

Filter field aliases are `field`, `dimension`, `column`, and `name`. Operator
aliases are `op` and `operator`. Supported operators are `=`, `!=`, `<>`, `>`,
`>=`, `<`, `<=`, `LIKE`, `IN`, and `BETWEEN`; `BETWEEN` expects a two-element
array. `ORDER BY` fields must refer to selected metrics or dimensions.

The database also exposes this contract in
`SEMANTIC_AGENT.COMPILE_REQUEST_SCHEMA_FOR_AGENT`, so adapters can discover the
accepted keys without scraping documentation.

## Error Codes and Retry

`COMPILE_REQUEST_JSON` and `COMPILE_SQL` return `ERROR_CODE` values in two
families:

- `SEMANTIC_REQUEST_NNN` for structured requests
- `SEMANTIC_QUERY_NNN` for the SQL preprocessor entry points

Two codes carry retry semantics rather than user fix-up semantics:

- `SEMANTIC_REQUEST_100` / `SEMANTIC_QUERY_100` —
  **transient transaction collision, safe to retry.** Emitted when the
  compile path hit `GlobalTransactionRollback` after the compiler's own
  bounded retries were exhausted. Callers should retry the same request
  after a short backoff (≥50 ms). The generated SQL would have been
  identical, so caching keyed on the request is safe.
- `SEMANTIC_REQUEST_999` / `SEMANTIC_QUERY_999` —
  **unexpected error, not retryable.** Indicates an exception that did not
  match any known compile error. Treat as a bug report signal; the
  `ERROR_MESSAGE` carries the underlying Lua / SQL message.

All other codes are deterministic input or model errors. Retrying them
without changing the request will reproduce the same failure.

A compile call is itself idempotent: re-running with the same request and the
same model version produces the same `GENERATED_SQL` and `PLAN_JSON`. Each
call still appends a row to `AGENT_REQUEST_LOG`.

## Catalog Usage

Agent and application integrations should read `SEMANTIC_AGENT` for
role-scoped machine context and `SEMANTIC_CATALOG` for human/admin catalog
review. Avoid direct reads from `SYS_SEMANTIC` unless you are writing admin
maintenance tooling; internal tables deliberately use implementation-oriented
ids and do not duplicate every display column such as `MODEL_NAME`.

## MCP Semantic Mode

A thin MCP adapter should map common semantic tools onto the database-resident
surface:

- `list_semantic_views()` reads `MODELS_FOR_AGENT` and `OBJECTS_FOR_AGENT`.
- `describe_semantic_view(view_name)` reads object, field, valid-combination,
  sample-value, and measure-group metadata.
- `get_business_glossary()` calls `GET_BUSINESS_GLOSSARY`.
- `execute_semantic_query(sql)` calls `COMPILE_SQL`, executes the returned SQL
  under the caller's database privileges, and returns the result plus plan
  metadata.
- `execute_structured_semantic_query(request_json)` calls
  `COMPILE_REQUEST_JSON`; this is the preferred autonomous-agent path.

MCP must not enforce security by SQL rewriting. It should authenticate the
caller, preserve effective user context, call the database semantic contract,
and return the generated plan/results.

Feedback and explanation should use durable database handles. Structured agent
requests return `AGENT_REQUEST_ID`; explicit SQL debug compiles return
`QUERY_LOG_ID`. The normal preprocessor path intentionally does not create a log
row.

Use these handle types for explanations:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL('AGENT_REQUEST', <agent_request_id>);
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL('QUERY_LOG', <query_log_id>);
```

Use feedback to capture a reviewable signal, not to mutate the catalog
directly:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK(
  'AGENT_REQUEST',
  <agent_request_id>,
  'NEEDS_CHANGE',
  'The user expected completed revenue.',
  '{"metric":"completed_revenue"}'
);
```

Glossary output must be mode-specific. Structured request mode should not
instruct agents to write `GROUP BY`, joins, or aggregate formulas. Semantic SQL
mode should describe the supported SQL subset against published semantic views.
