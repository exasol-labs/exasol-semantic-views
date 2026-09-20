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

See [Admin setup for database-wide Semantic SQL](admin-db-wide-setup.md) for the
rollout and rollback procedure, and for what the preprocessor costs on statements
that have nothing to do with this layer (a few milliseconds; it decides what a
statement could possibly be before importing anything).

Then grant the tool's role the model:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('sales', 'BI_READERS');
```

That one call grants the published schema, the `SEMANTIC_USER` baseline the
compiler needs, and records the authorization the catalog reads. It does **not**
grant the physical source tables — those are your data and your grant to make,
and they are where row-level security actually lives.

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

```sql
CREATE VIEW MART.V_REGIONAL_SALES AS
SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES t0;
```

The stored text is compiled physical SQL, so this view answers for anyone, with
no preprocessor at all. It is also **frozen**: it keeps answering after the model
changes, with the model as it was when the view was made. ESV records that and
can tell you — see [Governance](governance.md#5-frozen-views).

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
SELECT SHAPE, SUPPORT, REFUSAL_CODE, DETAIL
FROM SEMANTIC_CATALOG.QUERY_CAPABILITIES
ORDER BY SUPPORT, SHAPE;

-- what a model vouches for, in a sentence
SELECT MODEL_NAME, GOVERNANCE_MODE, VISIBLE_TO_CALLER, SUMMARY
FROM SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL;
```

Every refusal code in `QUERY_CAPABILITIES` is one the compiler actually emits —
that is asserted by a test, so the published contract cannot drift from the code.

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

For "why is my number different from my colleague's", `EXPLAIN_COMPILED_SQL`
carries a `GOVERNANCE` column that says in prose what was in force when the SQL
was produced — which principal compiled it, the mode the model was in, and which
relations the layer does and does not vouch for.

---

## 7. MCP and agent clients

An MCP client reaches the same surface. See
[Exasol MCP Server integration](mcp-server-integration.md); for the structured
compile, explain and feedback contracts an agent should prefer over raw SQL, see
the [agent contract](agent-contract.md).
