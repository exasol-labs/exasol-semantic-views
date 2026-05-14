# Admin Setup For Database-Wide Semantic SQL

This page is for admins and data engineers who want published semantic views to
behave like a normal database feature for BI and SQL users, without asking every
user to run `ENABLE_SEMANTIC_SQL()` manually.

Semantic SQL depends on Exasol's `SQL_PREPROCESSOR_SCRIPT` setting. The safe
default in this project is session activation:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
```

For a permanent rollout, an operator can set the semantic preprocessor at the
system level:

```sql
ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR;
```

Use system-wide activation only after testing the same script in normal user
sessions. A broken system preprocessor can affect all new sessions.

## Rollout Options

Use the narrowest rollout that satisfies the user workflow:

| Scope | Setup | Best For |
|---|---|---|
| One session | `EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()` | Developers, CI, notebooks, debugging |
| BI connection init | Run `ENABLE_SEMANTIC_SQL()` when the pool opens a connection | Pilot groups and tools with connection hooks |
| Database-wide | `ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = ...` | Production BI environments where semantic SQL should be on by default |

Agents and MCP-style tools should still prefer `COMPILE_REQUEST_JSON` or
`COMPILE_SQL` through a semantic adapter. They should not depend on an ambient
session preprocessor unless they are intentionally emulating a BI SQL session.

## Effect On Generic MCP Servers

Database-wide activation mitigates one common MCP failure mode: a generic
SELECT-only MCP SQL tool cannot run
`EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()`, so it cannot enable the
preprocessor for itself. If the semantic preprocessor is configured with
`ALTER SYSTEM`, new database sessions opened by that MCP server inherit semantic
SQL support and can run SELECT queries against published semantic views:

```sql
SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
GROUP BY customer_region
ORDER BY total_revenue DESC;
```

This is a mitigation, not a complete MCP integration:

- Existing MCP database connections may need to be reconnected before they pick
  up the system setting. For pooled servers, restart the MCP server or recycle
  its database connection pool after changing `SQL_PREPROCESSOR_SCRIPT`.
- Generic MCP object-listing tools may still omit views, depending on how they
  query Exasol metadata.
- SELECT-only MCP tools still cannot execute semantic admin scripts such as
  `COMPILE_REQUEST_JSON`, `COMPILE_SQL`, `EXPLAIN_COMPILED_SQL`, or
  `RECORD_AGENT_FEEDBACK`.

For agent-grade conversational analytics, use a semantic MCP adapter that maps
tool calls to the database-resident semantic scripts. Database-wide
preprocessing makes the generic SELECT path more usable for BI-style questions,
but it does not replace semantic MCP tools.

## MCP Hardening Checklist

For a generic MCP server that can list tables and run SELECT statements, admins
can improve the experience without changing the MCP server:

1. Publish every semantic model that should be visible:

   ```sql
   EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('<model_name>');
   ```

2. Enable semantic SQL database-wide:

   ```sql
   ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR;
   ```

3. Restart the MCP server or recycle its database connections.
4. Verify a generic MCP SELECT succeeds:

   ```sql
   SELECT customer_region, total_revenue
   FROM SEMANTIC_SALES.SALES
   GROUP BY customer_region
   ORDER BY total_revenue DESC;
   ```

5. Point agents at the MCP-visible discovery tables when view listing is weak:

   ```sql
   SELECT ENTRY_NAME, ENTRY_VALUE
   FROM SEMANTIC_SALES.SEMANTIC_DISCOVERY
   ORDER BY ENTRY_NAME;

   SELECT ENTRY_NAME, ENTRY_VALUE
   FROM SEMANTIC_AGENT.SEMANTIC_AGENT_DISCOVERY
   ORDER BY ENTRY_NAME;

   SELECT ENTRY_NAME, ENTRY_VALUE
   FROM SEMANTIC_CATALOG.SEMANTIC_CATALOG_DISCOVERY
   ORDER BY ENTRY_NAME;
   ```

These discovery tables are physical tables, not views, so generic MCP table
listing tools tend to expose them even when they omit Exasol views. They contain
entrypoint guidance and SELECT statements for the richer `SEMANTIC_AGENT` and
`SEMANTIC_CATALOG` views.

Useful SELECT-only metadata queries:

```sql
SELECT MODEL_NAME, PUBLISHED_SCHEMA, PUBLISHED_OBJECT_NAME, AGENT_READINESS
FROM SEMANTIC_AGENT.OBJECTS_FOR_AGENT
ORDER BY MODEL_NAME, OBJECT_NAME;

SELECT MODEL_NAME, OBJECT_NAME, FIELD_KIND, FIELD_NAME, DATA_TYPE, DESCRIPTION
FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT
ORDER BY MODEL_NAME, OBJECT_NAME, FIELD_KIND, FIELD_NAME;

SELECT MODEL_NAME, OBJECT_NAME, METRIC_NAME, DIMENSION_NAME, IS_VALID, REASON_CODE
FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT
ORDER BY MODEL_NAME, OBJECT_NAME, METRIC_NAME, DIMENSION_NAME;
```

The semantic preprocessor deliberately leaves
`SEMANTIC_<MODEL>.SEMANTIC_DISCOVERY` unchanged, so those tables remain readable
even when database-wide semantic preprocessing is active.

Facilities still worth adding in a dedicated semantic MCP adapter:

- `list_semantic_views`.
- `describe_semantic_view`.
- `execute_structured_semantic_query` backed by `COMPILE_REQUEST_JSON`.
- `execute_semantic_sql` backed by `COMPILE_SQL`.
- `explain_semantic_request` backed by `EXPLAIN_COMPILED_SQL`.
- `record_semantic_feedback` backed by `RECORD_AGENT_FEEDBACK`.

## Prerequisites

Before enabling semantic SQL database-wide:

1. Install the extension SQL files in order.
2. Validate the model:

   ```sql
   EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales');
   ```

   The result should contain no `ERROR` rows.

3. Publish the model:

   ```sql
   EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales');
   ```

4. Test semantic SQL in one admin session:

   ```sql
   EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();

   SELECT customer_region, total_revenue
   FROM SEMANTIC_SALES.SALES
   GROUP BY customer_region
   ORDER BY total_revenue DESC;
   ```

5. Test from a representative BI or analyst role, not only from `SYS`.

The semantic preprocessor is not a security boundary. Users may be able to
disable session preprocessing, and rewritten SQL executes under normal Exasol
privileges. Grant physical table, materialization, and metadata privileges
according to your regular governance model.

## Enable Database-Wide

Run as a database operator:

```sql
ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR;
```

The system setting affects new connections. Existing sessions and existing BI
connection pools may need to reconnect before they inherit it.

Open a fresh session and verify:

```sql
SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
GROUP BY customer_region
ORDER BY total_revenue DESC
LIMIT 10;
```

Also verify ordinary SQL still works unchanged:

```sql
SELECT COUNT(*) FROM MART.ORDER_LINES;
```

The semantic preprocessor is designed to early-out for non-semantic SQL, but
production rollout should still include representative dashboard and ETL smoke
queries.

## Rollback

To disable semantic SQL for future sessions:

```sql
ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = NULL;
```

For the current session:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL();
-- equivalent:
ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;
```

After rollback, restart or recycle BI connection pools so new connections pick
up the cleared system setting.

## Upgrade Procedure

When replacing semantic preprocessor or compiler scripts in an environment that
has system-wide activation:

1. Disable the system preprocessor:

   ```sql
   ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = NULL;
   ```

2. Open a fresh admin session.
3. Disable preprocessing in that session as a belt-and-suspenders step:

   ```sql
   ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;
   ```

4. Run the install files in the documented order.
5. Run validation and representative semantic queries in a session-scoped test.
6. Re-enable the system setting:

   ```sql
   ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR;
   ```

The install files clear the session preprocessor before replacing
preprocessor-related scripts, but disabling the system setting before an upgrade
keeps new admin or BI sessions from picking up a partially upgraded runtime.

## Coexistence With Other Preprocessors

`SQL_PREPROCESSOR_SCRIPT` points to one active preprocessor script for a session
or for the system. If your database already uses a preprocessor, do not overwrite
it blindly. Decide whether semantic SQL should be enabled only in specific
sessions, whether another owner should route to the semantic preprocessor, or
whether the existing preprocessor should be replaced.

## Operational Notes

- `ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = ...` changes behavior for new
  sessions.
- `ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = ...` overrides behavior for the
  current session.
- `ALTER SESSION` and `ALTER SYSTEM` can also clear preprocessing by setting the
  parameter to `NULL`.
- Statements that include passwords are excluded from Exasol preprocessing.
- Exasol audit tables record the preprocessor script execution and the
  transformed SQL separately.

References:

- [Exasol SQL preprocessor](https://docs.exasol.com/db/latest/database_concepts/sql_preprocessor.htm)
- [Exasol ALTER SYSTEM](https://docs.exasol.com/db/latest/sql/alter_system.htm)
