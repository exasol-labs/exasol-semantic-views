# Exasol MCP Server Integration

The official [Exasol MCP Server](https://github.com/exasol/mcp-server) can query
published Exasol Semantic Views directly. Its preprocessor tools are enabled by
default, so a client can activate the semantic SQL preprocessor for its pooled
database session and then use the normal read-query tool.

This path supports governed semantic SQL without a custom MCP server. A
dedicated semantic adapter is optional and adds access to the richer structured
compile, explanation, plan, and feedback contracts.

## Server Configuration

Enable read queries and, for normal object discovery, views:

```json
{
  "enable_read_query": true,
  "views": {
    "enable": true
  }
}
```

Pass the JSON through `EXA_MCP_SETTINGS` as described in the
[official tool setup guide](https://exasol.github.io/mcp-server/main/user_guide/tool_setup.html).
`list_exasol_preprocessors` and `set_exasol_preprocessor` are enabled by
default; setting `enable_preprocessor_tools` to `false` removes them.

For a local Exasol Personal instance with a self-signed certificate, the MCP
server may also need `EXA_SSL_CERT_VALIDATION=no`. Do not disable certificate
validation for production connections.

The connecting database user must be able to see the published semantic model,
set the session preprocessor, and read the physical objects used by the compiled
query. The preprocessor does not bypass Exasol privileges.

## User Workflow

1. Confirm that the tools are available:

   ```text
   list_exasol_preprocessors
   set_exasol_preprocessor
   execute_exasol_query
   ```

2. List preprocessors and confirm that
   `SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR` is available.

3. Activate it for the MCP server's database session:

   ```text
   set_exasol_preprocessor(
     schema_name="SEMANTIC_ADMIN",
     script_name="SEMANTIC_PREPROCESSOR"
   )
   ```

4. Call `list_exasol_preprocessors` again and require
   `current_preprocessor = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"`.

5. Discover published objects with `find_exasol_schemas`,
   `list_exasol_tables_and_views`, and `describe_exasol_table_or_view`. If view
   discovery is disabled, query the physical discovery tables instead:

   ```sql
   SELECT ENTRY_NAME, ENTRY_VALUE
   FROM SEMANTIC_SALES.SEMANTIC_DISCOVERY
   ORDER BY ENTRY_NAME;
   ```

6. Execute semantic SQL through `execute_exasol_query`:

   ```sql
   SELECT customer_region, total_revenue
   FROM SEMANTIC_SALES.SALES
   GROUP BY customer_region
   ORDER BY total_revenue DESC
   LIMIT 10;
   ```

Put `LIMIT` in the semantic SQL. Do not pass the MCP tool's `row_limit`
argument for a semantic query: the server currently implements it by wrapping
the query in `SELECT * FROM (<query>) LIMIT n`, while the semantic preprocessor
accepts only its documented top-level SQL subset.

## Agent Workflow

When only the official MCP tools are available, an autonomous agent should:

1. Inspect `tools/list`; do not assume preprocessor support is absent.
2. Ensure `execute_exasol_query` is present. If it is missing, ask the server
   operator to enable `enable_read_query`.
3. List, set, and verify the semantic preprocessor before the first semantic
   query.
4. Discover only role-visible `SEMANTIC_AGENT` metadata and published semantic
   objects. Never infer physical joins or metric formulas.
5. Generate SQL only from discovered semantic fields and valid
   metric/dimension combinations.
6. Include a SQL `LIMIT` when a bounded result is required; omit MCP
   `row_limit`.
7. If a communication error, authentication refresh, server restart, or other
   reconnect may have occurred, verify `current_preprocessor` and set it again
   before retrying.
8. Stop with an actionable error rather than falling back to physical-table SQL.

The official server normally preserves the setting because it pools a database
connection per effective user. Its tool contract correctly warns that a
database reconnect can silently reset session state, so verification is part
of the agent loop rather than a one-time installation step.

## Capability Boundary

| Capability | Official MCP tools | Dedicated semantic adapter |
|---|---|---|
| Discover schemas, views, and columns | Yes, subject to server settings | Yes |
| Read `SEMANTIC_AGENT` metadata | Yes | Yes |
| Execute governed semantic SQL | Yes, after setting the preprocessor | Yes |
| Compile `COMPILE_REQUEST_JSON` | Not through the SELECT-only read tool | Yes |
| Return `PLAN_JSON` and durable request handles | No | Yes |
| Explain compiled handles and record feedback | No | Yes |
| Apply hierarchical result shaping | External post-processing | Adapter-specific |

Use the official preprocessor path for conversational queries, dashboard
previews, and ordinary semantic SQL. Add a semantic adapter when an autonomous
workflow needs the structured request schema, deterministic plans, durable
handles, explanations, or feedback.

## Alternatives And Troubleshooting

- **Preprocessor tools are missing:** ensure `enable_preprocessor_tools` was not
  set to `false`. If the MCP server has no equivalent tools, use database-wide
  activation or a semantic adapter.
- **`execute_exasol_query` is missing:** set `enable_read_query` to `true`; it is
  disabled by default.
- **Published views are missing from discovery:** enable `views.enable`, or
  query `SEMANTIC_<MODEL>.SEMANTIC_DISCOVERY` and the named agent views.
- **A semantic query fails before compilation:** verify
  `current_preprocessor`, then set it again. A reconnect creates a new database
  session without the previous session setting.
- **A query succeeds without `row_limit` but fails with it:** put `LIMIT` in the
  semantic SQL and omit the tool argument.
- **The client needs structured requests or provenance:** use a dedicated
  semantic adapter over the scripts documented in
  [Agent Contract](agent-contract.md).

Database-wide activation remains useful for BI tools or MCP servers that do not
offer preprocessor controls. See
[Admin Setup For Database-Wide Semantic SQL](admin-db-wide-setup.md).
