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

**A pinned `EXA_DSN` is unsafe on Exasol Personal.** Each deployment picks its
port at start, and a stopped deployment can lose `8563` to another one, so a
config that hardcodes `127.0.0.1:8563` can silently attach to a *different*
database — and answer confidently from the wrong catalog. Read the port back
from the deployment:

```sh
export EXASOL_PORT=$(jq -r .connection.dbPort ~/.exasol/personal/deployments/default/deployment.json)
```

and assert which deployment you reached before trusting an answer:

```sql
SELECT DATABASE_NAME, PRODUCT_VERSION, RUNTIME_CHECKSUM, MODEL_COUNT
FROM SEMANTIC_AGENT.DEPLOYMENT_IDENTITY_FOR_AGENT;
```

`DATABASE_NAME` plus `RUNTIME_CHECKSUM` identify the database and the exact
installed build; `MODELS_FOR_AGENT` carries the same two columns, so an agent
already reading that view can check without a second query.

The connecting database user needs two grants, and broad read privileges are
not a substitute for the first:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('sales', 'MCP_READER');  -- the model
GRANT SELECT ON SCHEMA MART TO MCP_READER;                              -- its sources
```

`GRANT_MODEL_ROLE` carries the `SEMANTIC_USER` baseline that running the
preprocessor and reading the catalog need. A user holding only `SELECT ANY
TABLE` and `USE ANY SCHEMA` can *set* the preprocessor — `ALTER SESSION` is
open to everyone — but every semantic query is then refused. The `GROUP BY`
form fails worse: Exasol's own parser rejects it with `not a valid GROUP BY
expression` before the layer can say what is missing. The compiled SQL reads
the physical sources with the caller's rights, so the second grant is needed
too; the preprocessor does not bypass Exasol privileges. The full table is in
[BI tools: Who needs what](bi-tools.md#who-needs-what).

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
7. After **any** failed query, and after a communication error,
   authentication refresh, server restart or other reconnect, verify
   `current_preprocessor` and set it again before retrying. In
   exasol-mcp-server 2.2.0 a query that raises does not return its pooled
   connection, so the next call gets a fresh session without the preprocessor
   ([exasol/mcp-server#309](https://github.com/exasol/mcp-server/issues/309)).
   A refused semantic query is a failed query, so this is the common case, not
   the rare one.
8. Stop with an actionable error rather than falling back to physical-table SQL.

The official server pools a database connection per effective user, which
preserves the setting between successful queries. A reconnect resets it, and
until mcp-server#309 is fixed so does every failed query, so verification is
part of the agent loop rather than a one-time installation step.

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
- **A semantic query fails before compilation**, typically with `not a valid
  GROUP BY expression` right after another query failed: verify
  `current_preprocessor`, then set it again. A reconnect, and in
  exasol-mcp-server 2.2.0 any failed query (mcp-server#309), leaves a new
  database session without the setting. If it is set and the error persists,
  check the user's grants (above).
- **A query succeeds without `row_limit` but fails with it:** put `LIMIT` in the
  semantic SQL and omit the tool argument.
- **The client needs structured requests or provenance:** use a dedicated
  semantic adapter over the scripts documented in
  [Agent Contract](agent-contract.md).

Database-wide activation remains useful for BI tools or MCP servers that do not
offer preprocessor controls. See
[Admin Setup For Database-Wide Semantic SQL](admin-db-wide-setup.md).
