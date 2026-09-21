# BI Tools and Generic SQL Interfaces

This page is for connecting Tableau, Power BI, a JDBC/ODBC client, a notebook, or
anything else that speaks ordinary SQL to a published semantic model.

The short version: **turn the preprocessor on database-wide, point the tool at
the published schema, and query it like a table.** Everything below is the detail
behind that sentence — what the tool may write, what it may not, and how to find
out which without guessing.

---

## 1. One-time setup

A BI tool opens its own connections and pools them. It gives you nowhere to run a
per-session statement, so `ENABLE_SEMANTIC_SQL()` — the right default for a
person exploring — is not something a Tableau or Power BI deployment can use at
all. Set the preprocessor at the system level instead:

```sql
ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR;
```

This runs the preprocessor for **every** statement in the database, as the
caller — so the script must be executable by everyone, or the setting denies
service to principals who have nothing to do with this layer. The installer
grants that; see
[Admin setup for database-wide Semantic SQL](admin-db-wide-setup.md#what-every-principal-needs-before-you-do-that)
for how to confirm it before switching a production system over, along with the
rollback procedure and what the preprocessor costs on unrelated statements (a few
milliseconds; it decides what a statement could possibly be before importing
anything).

Then grant the tool's role the model:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('sales', 'BI_READERS');
```

That one call grants the published schema, the `SEMANTIC_USER` baseline the
compiler needs, and records the authorization the catalog reads. It does **not**
grant the physical source tables — those are your data and your grant to make,
and they are where row-level security actually lives.

### Who needs what

Measured by granting one privilege at a time and seeing what starts working.
`CREATE SESSION` is assumed throughout.

| to do this | they need | notes |
|---|---|---|
| set the preprocessor for their own session | nothing extra | `ALTER SESSION` is allowed to everyone; it is running the script that needs the grant |
| list the models they may use, browse the catalog, read `QUERY_CAPABILITIES`, read their own `MY_QUERY_LOG`, call `COMPILE_SQL` | `GRANT_MODEL_ROLE(model, role)` | one call; carries the `SEMANTIC_USER` baseline |
| **run a semantic query and get rows** | that **plus `SELECT` on the physical sources** | without it: `SEMANTIC_QUERY_080` if the statement has not been compiled before, a plain privilege error if a cached compile is served |
| read the physical tables directly | `SELECT` on them | the semantic layer neither adds nor removes this |
| `CREATE VIEW` over a semantic object, in a schema they own | `CREATE VIEW` | **not a BI privilege** — see below |
| `CREATE VIEW` over a semantic object, in a shared schema | `CREATE ANY VIEW` | |
| let others read that view | grantable `SELECT` on every relation its compiled SQL reads | an author with plain `SELECT` cannot grant it on |
| read someone else's frozen view | `SELECT` on the view alone | **no rights on the sources, no preprocessor** |

**The row that matters most is the third.** The compiler runs as the caller, so
the SQL it generates reads your `MART` tables with the caller's rights. A BI role
granted the model but not the sources can browse every field, compile every
query, and retrieve nothing. That is the design — it is what makes row-level
security in the sources the real control — but it surprises people who expect
the model grant to be sufficient.

It used to surprise them badly: with a cold cache the compiler could not see the
source metadata either, concluded that no representation could traverse a
relationship, and reported an authorization outcome as `SEMANTIC_QUERY_080`, a
modelling defect. That message now names the other possibility, so the reader is
not sent looking for a bug that is not there.

**`CREATE VIEW` over a semantic object is not a BI capability.** It appears in §3
below as a statement that *compiles*, and it does, but it needs a privilege a
reporting role does not have, and the last two rows are why it is a governance
act rather than a convenience: the stored text is compiled physical SQL, the view
runs with its owner's rights, and a reader with no access to `MART` and no
preprocessor gets rows from it. That is a durable grant of data through a view
that keeps answering after the model moves on. Treat it as a deployment step
with an owner, not something an analyst does — see
[Governance](governance.md#5-frozen-views).

---

## 2. What the tool sees

A published model is a schema of ordinary-looking views:

```sql
SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES;
```

Metrics are aggregated correctly for whatever dimensions you selected. There is
no `GROUP BY` to write — it is inferred — and adding one that disagrees with the
select list is refused rather than silently answered.

Column names in results match what the published view advertises, so a tool that
binds by name or by position gets what it expects.

---

## 3. What a BI tool actually emits, and what happens to it

A BI tool almost never emits a bare `SELECT … FROM …`. It wraps the object. All
of these work:

| the tool emits | notes |
|---|---|
| `SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES t0` | aliased and qualified |
| `SELECT SUM(t0.TOTAL_REVENUE) FROM … t0` | aggregate over the object |
| `SELECT … FROM (SELECT t0.A, t0.B FROM … t0) x` | subquery wrapper |
| `WITH q AS (SELECT t0.A FROM … t0) SELECT … FROM q` | CTE |
| `SELECT a.A FROM … a UNION SELECT b.A FROM … b` | union of two references |
| `SELECT t0.A, RANK() OVER (ORDER BY t0.B DESC) FROM … t0` | window function |
| `… ORDER BY 2 DESC LIMIT 10` | TopN wrapper |
| `SELECT CAST(t0.B AS VARCHAR(50)), t0.B / 1000 FROM … t0` | casts and arithmetic |
| `SELECT COUNT(*) FROM (SELECT t0.A FROM … t0) z` | count over the result |
| `SELECT … WHERE 1 = 0` and `LIMIT 0` | the driver's metadata probes |

They work because the preprocessor replaces the **reference** — the
`SEMANTIC_SALES.SALES t0` part — with the compiled SQL as a derived table, and
leaves everything around it to Exasol. Joins, unions, windows and arbitrary
expressions are ordinary SQL from that point on.

**Which columns get compiled is inferred from how the statement uses the
object**: every `t0.column` reference, unqualified names matching a published
column, and `*`. A bare `*` counts only in the reference's own query block, so
the star in `SELECT * FROM (SELECT t0.A FROM obj t0) x` means the subquery's
columns rather than the object's.

If no column of the object is referenced at all, the statement is **refused**
(`SEMANTIC_QUERY_011`) rather than defaulting to every column. A wrong grain
returns plausible totals, which is the hardest kind of wrong to notice.

### Creating views on top

**This is not something the BI tool does.** It needs `CREATE VIEW` — or
`CREATE ANY VIEW` for a schema the author does not own — which a reporting role
should not hold, and the result is readable by anyone granted the view, with no
rights on the sources and no preprocessor. See
[Who needs what](#who-needs-what) above. It is here because it is a useful
deployment step, not because a dashboard can do it.

```sql
CREATE VIEW MART.V_REGIONAL_SALES AS
SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES t0;
```

The stored text is compiled physical SQL, so this view answers for anyone, with
no preprocessor at all. It is also **frozen**: it keeps answering after the model
changes, with the model as it was when the view was made. ESV records that and
can tell you — see [Governance](governance.md#5-frozen-views).

### What the shapes cost

Wrapping is not free, and how much it costs depends on the shape. Measured
interleaved, 25 rounds, all cache-warm, on Exasol `2026.2.0-dev.0` (Exasol
Personal, single node) on an Apple M3 Pro / 36 GB / macOS 26.6.1 — so read the
*differences*, not the absolute numbers, which do not travel between machines:

| shape | median | vs bare |
|---|---|---|
| bare `SELECT a, b FROM obj` | 104.2 ms | — |
| aliased, and TopN over it | 103–104 ms | about the same |
| subquery wrapper | 131.6 ms | +28 ms |
| CTE | 131.3 ms | +27 ms |
| arithmetic in the select list, or `ORDER BY` a non-selected field, **written bare** | 341–357 ms | +237 to +253 ms |

`tools/measure_expansion_cost.py` regenerates this table on your own hardware.

The last row is the one to know about. Those constructs work bare, and that is
recent — but the layer reaches them by trying the whole-statement path first and
falling through when it cannot compile them, and that failed attempt has already
read the catalog. Nothing caches the outcome, so it is paid on every execution.
**Writing the same query with the object aliased, or wrapped in a subquery, is
several times faster**, because the whole-statement path then declines
immediately instead of failing late. A BI tool emits the aliased and wrapped
forms anyway; this matters to someone hand-writing the bare form in a dashboard's
custom SQL box.

---

## 4. The one thing that is refused

**Joining a published object to another table** is refused by default:

```sql
SELECT t0.CUSTOMER_REGION, SUM(t0.TOTAL_REVENUE)
FROM SEMANTIC_SALES.SALES t0
JOIN MART.CUSTOMERS c ON c.REGION = t0.CUSTOMER_REGION
GROUP BY 1;
-- SEMANTIC_QUERY_012
```

Not because it cannot be compiled, but because of what it returns. The join
repeats the semantic result's rows once per matching customer, and the outer
`SUM` then counts them again:

```
North 7270      <- what that query returns
North 3635      <- what the model says
```

The semantic layer stops supervising at the edge of the derived table. Unlike the
same hazard under a Virtual Schema, the boundary is visible in your own SQL — you
wrote the join — which makes it explainable, not safe.

If your deployment would rather have ordinary-SQL semantics than a refusal, opt
in per model:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('sales', 'TRUE');
```

Do that knowing the number above is what you are accepting.

---

## 5. Finding the boundary without hitting it

Two catalog views answer the integrator's questions up front:

```sql
-- which SQL shapes are accepted, and the code you get when one is not
SELECT SHAPE, SUPPORT, SQL_REFUSAL_CODE, DETAIL
FROM SEMANTIC_CATALOG.QUERY_CAPABILITIES
ORDER BY SUPPORT, SHAPE;

-- what a model vouches for, in a sentence
SELECT MODEL_NAME, GOVERNANCE_MODE, VISIBLE_TO_CALLER, SUMMARY
FROM SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL;
```

**The codes are per lane.** The same condition has two spellings: SQL through the
preprocessor gets `SEMANTIC_QUERY_027`, the structured request lane gets
`SEMANTIC_REQUEST_027`. Match on `SQL_REFUSAL_CODE` if you send SQL. The view
used to publish only the request-lane spelling, so a BI integrator matching the
published code never matched.

Every row is asserted by running it: `tools/verify_query_capabilities_contract.py`
executes a statement for each published shape, in the lane the row names, and
fails if the code that comes back is not the one published. A row nobody
demonstrates fails too, so the contract cannot grow claims it does not keep.

---

## 6. When a query is refused or a number looks wrong

Refusals are `SEMANTIC_QUERY_*` and `SEMANTIC_REQUEST_*` codes with a message
that names the cause and, where there is one, the remedy. The common ones:

| code | meaning |
|---|---|
| `SEMANTIC_QUERY_011` | no column of the object is referenced, so which to compile cannot be inferred |
| `SEMANTIC_QUERY_012` | the object is joined to another relation; see §4 |
| `SEMANTIC_QUERY_010` | `COUNT(*)` directly over the object — its answer depends on a grain you did not name; wrap it in a subquery |
| `SEMANTIC_REQUEST_027` | the field is withheld by the model (`IS_PRIVATE` / `IS_HIDDEN`) |
| `SEMANTIC_REQUEST_024` | the field carries `DISPLAY_POLICY = 'MASK'`; you can still filter on it |
| `SEMANTIC_REQUEST_011` | the model does not exist, or is not granted to you |
| `SEMANTIC_QUERY_015` | the statement groups the object in its own query block, which groups an already-grouped result; aggregate over a subquery instead |
| `SEMANTIC_QUERY_020` | a name in the select list is not a field of the object; the message says what it might have meant |

**The shape of your statement is not the reason.** A construct is accepted or
refused the same way whether you reference the object bare or wrap it in a
subquery, so wrapping a refused statement is not a workaround — it was, once,
and the difference was invisible from every surface. If a refusal names a
construct, it is the construct.

One boundary the table cannot cover: a statement the layer rewrites but Exasol
then rejects — a syntax error, `DISTINCT ON`, `LIMIT -1` — comes back with
Exasol's own message rather than a `SEMANTIC_*` code. The message names the
problem; it just is not one of these. **Read the line it gives you and ignore the
column**: the line is one of yours, but the column counts the compiled SQL that
was spliced into your statement. A *valid* statement never fails this way — if
the layer cannot compile it, you get a code.

For "why is my number different from my colleague's", start from your own log:

```sql
-- your queries, newest first; nobody else's
SELECT QUERY_LOG_ID, CLIENT_NAME, STATUS, ORIGINAL_SQL
FROM SEMANTIC_SOURCE.MY_QUERY_LOG ORDER BY QUERY_LOG_ID DESC;

-- then ask what was in force for one of them
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL('QUERY_LOG', <id>);
```

Every statement the preprocessor rewrites is recorded there, including ones
served from the compile cache. `CLIENT_NAME` says which path produced the SQL —
`PREPROCESSOR` for a statement compiled whole, `PREPROCESSOR:EXPANSION` for one
where the object was expanded into a derived table.

`EXPLAIN_COMPILED_SQL` carries a `GOVERNANCE` column that says in prose what was
in force — the mode the model was in, and which relations the layer does and
does not vouch for. When the plan came from the cache it names both principals:
the one who ran the statement and the one whose compile it reused. The SQL is the
same either way, and **the rows you saw were still resolved with your rights** —
which is usually the answer to the question.

You can only explain your own queries. A handle belonging to someone else
reports as not found.

---

## 7. MCP and agent clients

An MCP client reaches the same surface. See
[Exasol MCP Server integration](mcp-server-integration.md); for the structured
compile, explain and feedback contracts an agent should prefer over raw SQL, see
the [agent contract](agent-contract.md).
