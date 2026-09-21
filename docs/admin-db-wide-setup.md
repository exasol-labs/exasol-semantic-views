# Admin Setup For Database-Wide Semantic SQL

This page is for admins and data engineers who want published semantic views to
behave like a normal database feature for BI and SQL users, without asking every
user to run `ENABLE_SEMANTIC_SQL()` manually.

**For BI tools, database-wide activation is the supported deployment mode, not
an advanced option.** A BI tool opens its own connections, pools them, and gives
you nowhere to run a per-session setup statement — so session activation is not
something a Tableau or Power BI deployment can use at all. Set it at the system
level and published semantic views behave like ordinary views to every client.

Session activation remains the right default for *development*: it is reversible
in one statement and scoped to the person trying it.

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

### What every principal needs before you do that

Exasol runs the preprocessor **as the caller**, for every statement in the
database — including statements from principals who have never heard of this
layer. So the script has to be executable by all of them, or `ALTER SYSTEM`
denies service database-wide: a user with nothing but `CREATE SESSION` gets
`insufficient privileges for executing a script` on `SELECT 1`.

The installer grants it:

```sql
GRANT EXECUTE ON SCRIPT SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR TO PUBLIC;
```

Check it is in place before switching a production system over:

```sql
SELECT GRANTEE FROM EXA_DBA_OBJ_PRIVS
WHERE OBJECT_SCHEMA = 'SEMANTIC_ADMIN' AND OBJECT_NAME = 'SEMANTIC_PREPROCESSOR';
```

The grant is safe to make to `PUBLIC`: the script decides whether a statement is
semantic and does nothing else. The runtimes that read the catalog are imported
only when a statement could need them, and a caller who may not execute those
has their SQL passed through unchanged rather than refused — so an ordinary
statement from an unprivileged principal behaves exactly as it did before
activation.

### Rolling back

```sql
ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = NULL;
```

Takes effect for sessions opened afterwards. Published semantic views then
refuse with `SEMANTIC_SURFACE_001` until a session enables the preprocessor
itself; ordinary SQL is unaffected either way.

Use system-wide activation only after testing the same script in normal user
sessions. A broken system preprocessor can affect all new sessions.

## Rollout Options

Use the narrowest rollout that satisfies the user workflow:

| Scope | Setup | Best For |
|---|---|---|
| One session | `EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()` | Developers, CI, notebooks, debugging |
| BI connection init | Run `ENABLE_SEMANTIC_SQL()` when the pool opens a connection | Pilot groups and tools with connection hooks |
| Database-wide | `ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = ...` | Production BI environments where semantic SQL should be on by default |

Agents that need structured plans or durable handles should prefer
`COMPILE_REQUEST_JSON` or `COMPILE_SQL` through a semantic adapter. For ordinary
semantic SQL, the official Exasol MCP Server can explicitly activate and verify
the session preprocessor as described below.

## What An Active Preprocessor Costs

An active preprocessor runs for **every** statement in the session, and every
nested query a Lua script issues is itself a statement. So the per-statement cost
of the preprocessor is multiplied by the internal query count of every admin
script that runs in that session — `VALIDATE_MODEL`, `PUBLISH_MODEL`, the
`ADD_*` scripts, and the structured compile lane included. Exasol suppresses
preprocessing *inside* the preprocessor, but not inside a script called from a
preprocessed statement.

The preprocessor is therefore written to decide what a statement could possibly
be before importing either runtime, and to import neither when nothing can
apply. A statement that names no published semantic schema costs one small
catalog read rather than ~500 kB of Lua. Measured on the bundled sales model:

| Statement in a preprocessor-enabled session | Before | Now |
|---|---|---|
| `SELECT 1` | 32 ms | 7 ms |
| `SELECT COUNT(*) FROM MART.ORDERS` | 98 ms | 16 ms |
| semantic SQL | 303 ms | 91 ms |
| `EXECUTE SCRIPT VALIDATE_MODEL('sales')` | 2.9× its cost with the preprocessor off | ~1.1× |

Two consequences for a database-wide rollout:

- It is now a reasonable default. Before this change, `ALTER SYSTEM` applied a
  multi-fold tax to every script in every session, including sessions that never
  ran a semantic query.
- The residual cost is not zero. A session that runs long administrative scripts
  — a large `VALIDATE_MODEL`, an OSI import, a fusion apply — still pays the
  per-statement gate on each of that script's internal queries. Run bulk
  administrative work with the preprocessor off:

```sql
ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL;
```

See [plans/preprocessor-latency.md](../plans/preprocessor-latency.md) for the
measurements and the remaining upstream request.

## MCP Servers

The official Exasol MCP Server exposes `list_exasol_preprocessors` and
`set_exasol_preprocessor` by default. It can therefore activate
`SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR` for its pooled session and query
published semantic views without database-wide activation. Use the session
workflow in [Exasol MCP Server Integration](mcp-server-integration.md) first.

Database-wide activation is an alternative for MCP servers that expose only a
SELECT tool and have no preprocessor control. New database sessions opened by
such a server inherit semantic SQL support:

```sql
SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
GROUP BY customer_region
ORDER BY total_revenue DESC;
```

Neither route exposes the complete structured agent contract:

- Existing MCP database connections may need to be reconnected before they pick
  up the system setting. For pooled servers, restart the MCP server or recycle
  its database connection pool after changing `SQL_PREPROCESSOR_SCRIPT`.
- Generic MCP object-listing tools may still omit views, depending on how they
  query Exasol metadata.
- SELECT-only MCP tools still cannot execute semantic admin scripts such as
  `COMPILE_REQUEST_JSON`, `COMPILE_SQL`, `EXPLAIN_COMPILED_SQL`, or
  `RECORD_AGENT_FEEDBACK`. F7 governance also requires script access for
  `PROPOSE_MODEL_EVOLUTION` and `REVIEW_MODEL_EVOLUTION`; the pending queue is
  readable through `SEMANTIC_AGENT.MODEL_EVOLUTION_REVIEW_QUEUE`.

For structured compilation, plans, durable handles, explanations, and feedback,
use a semantic MCP adapter that maps tools to the database-resident scripts.
That adapter is an enhancement over the working official semantic SQL path,
not a prerequisite for conversational querying.

## MCP Hardening Checklist

For an MCP server without preprocessor tools, admins can improve the experience
without changing the server:

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

**Why there are three, and why each repeats a little.** Each managed schema and
each published schema holds exactly **one** physical table, and it is its
discovery index — everything else in those schemas is a view. With the official
MCP server's `views.enable` left at its default, that one table is the only
object a client can enumerate, so it has to carry the pointers to everything
else. The three are not copies:

| Table | Answers |
|---|---|
| `SEMANTIC_CATALOG.SEMANTIC_CATALOG_DISCOVERY` | which catalog views exist, and four ready-to-run introspection queries |
| `SEMANTIC_AGENT.SEMANTIC_AGENT_DISCOVERY` | which agent views exist, and seven agent-specific queries |
| `SEMANTIC_<MODEL>.SEMANTIC_DISCOVERY` | that model's objects, their descriptions, a `SELECT` example each, and the entrypoint |

The per-model table's object list looks redundant against
`SEMANTIC_CATALOG.SEMANTIC_OBJECTS`, and is not: the published semantic objects
are **views**, so for a client that cannot list views those rows are the only way
to learn that `SEMANTIC_<MODEL>.<OBJECT>` exists. It is written by
`PUBLISH_MODEL`, which is also what creates those views, so it is exactly as
fresh as what it describes.

The `MCP_GUIDANCE` and join-introspection rows appear in more than one table with
similar wording, deliberately. Grants are per schema — a caller given
`SELECT ON SCHEMA SEMANTIC_AGENT` cannot read `SEMANTIC_CATALOG` — so each table
must be self-sufficient. A row pointing at another table is useless to a caller
who cannot read it.

`tools/verify_catalog_introspection.py` asserts the one-table-per-schema shape and
**executes every `SELECT` these tables advertise**, because a query string naming
a column that does not exist fails nowhere except in the hands of the agent that
followed it. `METRIC_DEFINITIONS_QUERY` had been selecting `OBJECT_NAME` from
`SEMANTIC_CATALOG.METRICS`, which has no such column; it reads `METRIC_OVERVIEW`
now.

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

1. Install the extension:

   ```sh
   python3 tools/install.py
   ```

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

4. Re-run the installer:

   ```sh
   python3 tools/install.py --skip-package
   ```
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

### Schedule `CHECK_FROZEN_VIEWS`

A view created over a semantic object stores **compiled physical SQL**. That is
what makes it answer with no preprocessor, for anyone granted it — and it is
also why it keeps answering with the model as it was when the view was made,
after the model has moved on. It does not fail, it does not warn, and the number
it returns still looks right. A frozen view is silent by construction.

`VALIDATE_MODEL` now says they exist (`SEMANTIC_MODEL_067`), which is as much as
the catalog can know: nothing there records that a definition was edited. The
exact question needs the compiler, so run the check on a schedule and after every
model change:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS('sales');
-- STATUS is CURRENT, STALE or DROPPED, one row per recorded view
```

Put it wherever your model changes land — the same job that runs
`VALIDATE_MODEL` after a deployment, or a nightly task if models are edited by
hand. Act on `STALE` by re-creating the view from the current model, or dropping
it if nobody needs it; `DROPPED` means the record outlived the view and is safe
to leave. Treat a `STALE` view the way you would a report nobody owns: it is
still being read.

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

## What a tool can rely on

Two catalog views answer the questions an integrator has before they start,
so the boundary is not discovered by hitting it:

```sql
-- which SQL shapes are accepted, and what the layer says when one is not
SELECT SHAPE, SUPPORT, SQL_REFUSAL_CODE, REQUEST_REFUSAL_CODE, DETAIL
FROM SEMANTIC_CATALOG.QUERY_CAPABILITIES ORDER BY SUPPORT, SHAPE;

-- what a given model vouches for, in a sentence
SELECT MODEL_NAME, GOVERNANCE_MODE, VISIBLE_TO_CALLER, SUMMARY
FROM SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL;
```

And after a query has run, `EXPLAIN_COMPILED_SQL` carries a `GOVERNANCE` column
saying in prose what was in force when the SQL was produced — which principal
compiled it, the mode the model was in, and which relations the layer does or
does not vouch for. That is the answer to "why is my number different from my
colleague's" without reading generated SQL.
