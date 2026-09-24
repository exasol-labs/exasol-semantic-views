# Semantic SQL Preprocessor

The installed Lua SQL preprocessor is
`SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR`.

Purpose:

1. Early-out for non-semantic SQL.
2. Detect references to published semantic schemas.
3. Parse the supported top-level semantic SQL subset.
4. Call the shared semantic compiler.
5. Replace metric-column SQL with valid physical Exasol SQL before normal query
   validation.

The preprocessor is not a security boundary.

## Activation

Enable semantic SQL for the current session:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();
```

Disable it:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL();
```

The install files explicitly clear `SQL_PREPROCESSOR_SCRIPT` before replacing
preprocessor-related scripts. `CREATE SCRIPT` statements are themselves parsed
while a session preprocessor is active, so extension installs should avoid
leaving an old preprocessor in the session.

Activation is session-scoped. BI sessions and SQL clients that want to run
semantic SQL directly must enable it on each connection. Agents and MCP
adapters should prefer `COMPILE_REQUEST_JSON` or `COMPILE_SQL` when they cannot
control session initialization.

The official Exasol MCP Server can control this state directly with its
`list_exasol_preprocessors` and `set_exasol_preprocessor` tools, which are
enabled by default. Agents should set and verify
`SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR`, then use `execute_exasol_query`. See
[Exasol MCP Server Integration](mcp-server-integration.md) for the exact
workflow and the current `row_limit` caveat.

For production BI environments, admins can also roll out the same preprocessor
as a system setting. See
[Admin setup for database-wide Semantic SQL](admin-db-wide-setup.md) for the
operator checklist, rollback, and upgrade flow.

## Published Surface

`SEMANTIC_ADMIN.PUBLISH_MODEL('sales')` validates the active model version,
creates the published schema if needed, and generates guarded typed views such
as `SEMANTIC_SALES.SALES`.

Those views are metadata surfaces only. Every column is a cast of
`SEMANTIC_ADMIN.SEMANTIC_GUARD()`, so direct execution without the preprocessor
raises `SEMANTIC_SURFACE_001`.

Published views include comments that point users and tools to
`ENABLE_SEMANTIC_SQL` and `COMPILE_REQUEST_JSON`.

## Supported SQL

The parser supports this BI-oriented subset:

```sql
SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES
WHERE order_status = 'COMPLETE'
GROUP BY customer_region
ORDER BY total_revenue DESC
LIMIT 10;
```

`SELECT` accepts semantic field names, `SELECT *`, and the Databricks-style
metric wrappers `MEASURE(metric)` and `agg(metric)`. `MEASURE()` / `agg()` may
only wrap metrics; wrapping a dimension returns `SEMANTIC_QUERY_006`.

Supported `WHERE` predicates are dimension predicates with `=`, `!=`, `<>`,
`<`, `<=`, `>`, `>=`, `LIKE`, `IN`, `BETWEEN`, `IS NULL`, and `IS NOT NULL`.
Text equality, inequality, `LIKE`, and `IN` predicates compile
case-insensitively. Null predicates are unary. Single-value comparison
predicates may use a literal or a SQL expression on the right side, which
allows date expressions such as
`ADD_MONTHS(TRUNC(CURRENT_DATE, 'MM'), -1)`. `IN` requires a literal list, and
`BETWEEN` requires literal lower and upper values.

Metric predicates belong in `HAVING` and support the same predicate operators.
For compatibility with SQL users, a metric predicate written in `WHERE` is
routed to `HAVING` during parsing, while dimension predicates remain in
`WHERE`.

`GROUP BY` is optional. When omitted, it is inferred from the selected
dimensions, so this compiles and runs just like the explicit form above:

```sql
SELECT customer_region, total_revenue
FROM SEMANTIC_SALES.SALES;          -- GROUP BY customer_region is inferred
```

If a `GROUP BY` *is* supplied, it must be `GROUP BY ALL` or exactly cover the
selected dimensions (no missing or extra fields), otherwise compilation fails
with `SEMANTIC_QUERY_008`. Explicit `GROUP BY` lists may use selected
dimension names or ordinals.

`ORDER BY` is limited to selected semantic output fields, output aliases, or
ordinals. Databricks-style `ORDER BY MEASURE(metric)` is accepted for selected
metrics. `SELECT *` expands to the visible semantic dimensions and metrics for
the published object.

## Statements that wrap a semantic object

The subset above is what the *whole-statement* path compiles: a `SELECT` whose
`FROM` is one published object. A BI tool almost never emits that. It emits the
object wrapped in something — a TopN wrapper, a CTE, a subquery, a union, a
window, arithmetic in the select list, `COUNT(*)`.

Those are accepted too, by a second path: **reference expansion** replaces the
reference rather than compiling the statement around it.

**You do not choose between the two, and you cannot tell which one answered.**
Whatever the whole-statement path cannot compile is handed to expansion, so a
construct works, or does not, regardless of how the statement is shaped around
the object. This used to be untrue and the difference was invisible:

```sql
-- was refused: the whole-statement path would not order by an unselected field
SELECT CUSTOMER_REGION FROM SEMANTIC_SALES.SALES ORDER BY TOTAL_REVENUE DESC

-- worked, because the pointless subquery routed it to expansion instead
SELECT * FROM (
  SELECT CUSTOMER_REGION FROM SEMANTIC_SALES.SALES ORDER BY TOTAL_REVENUE DESC
) x
```

Both run now. A redundant subquery used to be the difference between a working
report and a refusal naming a construct SQL has had for forty years, and nothing
on any surface said so — the workaround could not be discovered, only stumbled
upon. `tools/verify_sql_lane_parity.py` holds the invariant: for each construct
it runs the bare and wrapped forms and requires the same rows, or the same
refusal code.

One consequence worth stating plainly: a refusal may now come from either path,
and the one with more to say wins. `SELECT bogus FROM obj` keeps `Unknown
semantic field: bogus. Did you mean: …?` rather than being re-described as a
statement whose columns could not be inferred.

```sql
-- you write
SELECT t0.CUSTOMER_REGION, RANK() OVER (ORDER BY t0.TOTAL_REVENUE DESC) r
FROM SEMANTIC_SALES.SALES t0

-- the preprocessor emits
SELECT t0.CUSTOMER_REGION, RANK() OVER (ORDER BY t0.TOTAL_REVENUE DESC) r
FROM (<compiled semantic SQL for CUSTOMER_REGION, TOTAL_REVENUE>) t0
```

Everything outside the parentheses stays ordinary SQL that Exasol handles
natively. A `CREATE VIEW` over a semantic object therefore stores *compiled*
SQL, so the view answers with no preprocessor at all.

**Which columns get compiled is inferred from the statement**: every
`alias.column` reference, unqualified names matching a published column, and
`*` — where a bare `*` counts only when it is selected from the same query block
as the reference, so the star in `SELECT * FROM (SELECT t0.A FROM obj t0) x`
means the subquery's columns and not the object's. When no column of the object
is referenced at all, the statement is refused with `SEMANTIC_QUERY_011` rather
than defaulting to every column: a wrong grain returns plausible totals, which is
the hardest kind of wrong to notice. If the statement's select list names
something that *looks* like a field but the object does not publish, the refusal
says which name and what it might have meant instead (`SEMANTIC_QUERY_020`).

### When a statement still fails, the position is yours

Expansion splices compiled SQL into your statement, so the text Exasol parses is
not the text you wrote. That used to show in the worst possible way: the compiled
SQL runs to eight or so lines, so everything after the reference moved down by
that many, and a one-line query that Exasol rejected was reported at *line 10*.
There is nothing at line 10 to look at.

The derived table is now emitted on a single line, so **line numbers survive the
rewrite** — the line Exasol names is a line you wrote. The *column* still counts
the spliced characters and can point past the end of that line, which inline
rewriting cannot avoid. Read the line; ignore the column.

A valid statement never fails this way at all: if the layer cannot compile one it
refuses with a `SEMANTIC_*` code, and `tools/verify_no_raw_parse_errors.py` holds
that over a corpus of statement shapes rather than over the three that were
reported.

### Grouping an object again is refused

A published object is already aggregated to the grain its fields imply, so a
`GROUP BY` or `HAVING` **in the same query block as the reference** groups a
grouped result:

```sql
-- refused: counts rows that are themselves groups
SELECT CUSTOMER_REGION, COUNT(*) FROM SEMANTIC_SALES.SALES GROUP BY CUSTOMER_REGION
```

Left to expansion that becomes `SELECT CUSTOMER_REGION, COUNT(*) FROM (<compiled>)
GROUP BY CUSTOMER_REGION` — valid SQL returning `1` per region, which is the
count of groups rather than of anything anyone asked about. It is refused with
`SEMANTIC_QUERY_015`, or with whichever of `SEMANTIC_QUERY_008`, `_010` or `_026`
has more to say about the particular statement — unless the model has opted into
ordinary-SQL semantics with `SET_MODEL_DERIVED_COMPOSITION`, which covers this
hazard and the join hazard together.

Aggregating in an *outer* block is the supported form, because there the caller
has named the grain:

```sql
SELECT COUNT(*) FROM (SELECT t0.CUSTOMER_REGION FROM SEMANTIC_SALES.SALES t0) z
```

### A view over a semantic object freezes its SQL

Because the stored text is compiled, the view answers forever, for anyone, with
no preprocessor — and with the model *as it was when the view was made*. Nothing
in the view says so, so ESV records it:

```sql
SELECT VIEW_SCHEMA, VIEW_NAME, PRESENCE, FROZEN_RELATIONS
FROM SEMANTIC_CATALOG.FROZEN_VIEWS;

EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS('sales');
-- VIEW_SCHEMA VIEW_NAME  STATUS   DETAIL
-- MART        V_BI       STALE    The model now compiles different SQL ...
```

`CHECK_FROZEN_VIEWS` recompiles the columns the view froze and compares. That is
the exact test, and it is a script rather than a `VALIDATE_MODEL` rule because
answering it needs the compiler. There is deliberately no version comparison:
ESV creates one model version per model and authoring mutates it in place, so a
version check could never fire.

`VALIDATE_MODEL` reports the part the catalog *can* settle, which is also the
dangerous part — `SEMANTIC_MODEL_068`, a frozen view reading a relation the model
no longer vouches for, because a rollup was retired or has diverged from the
representations it stands in for. That view has already stopped inheriting
whatever row policy those representations carry. It is an error in a model
running in `GOVERNED` mode, a warning otherwise.

A `GOVERNED` model refuses to freeze at all unless it can vouch for everything
the compiled SQL reads — the refusal comes from the compile behind the
`CREATE VIEW` (`SEMANTIC_QUERY_028`), because SQL that will not compile cannot be
frozen.

### Composition is refused by default

A derived table can be joined, and a join can repeat the semantic result's rows:

```sql
SELECT t0.CUSTOMER_REGION, SUM(t0.TOTAL_REVENUE)
FROM SEMANTIC_SALES.SALES t0 JOIN MART.CUSTOMERS c ON c.REGION = t0.CUSTOMER_REGION
GROUP BY 1
-- North 7270, where the model says 3635
```

The semantic layer stops supervising at the edge of the derived table, so this
is refused with `SEMANTIC_QUERY_012`. Unlike the same hazard under a Virtual
Schema, the boundary is visible in the author's own SQL — they wrote the join —
which makes it explainable, not safe.

A deployment that would rather have ordinary-SQL semantics than a refusal opts
in per model:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('sales', 'TRUE');
```

Unsupported semantic SQL fails closed with `SEMANTIC_QUERY_*` errors. Ordinary
SQL against non-semantic schemas is returned unchanged.

Every name position accepts a double-quoted identifier for names that collide
with SQL keywords (`ON ENTITY "order"`); the quoted text must still be a valid
identifier.

`ALTER SEMANTIC VIEW` supports `REPLACE DIMENSIONS`, `REPLACE FACTS`, `REPLACE
METRICS`, single `ADD OR REPLACE DIMENSION`, `ADD OR REPLACE FACT`, `ADD OR
REPLACE METRIC`, `DROP METRIC`, and `RENAME METRIC ... TO ...`. Any `REPLACE`
block is a valid statement on its own, and the blocks compose — one statement may
carry dimensions, facts and metrics together, validated once and rolled back as a
unit. The three single forms each take the rest of the statement as one clause,
so none can be combined with another change (`SEMANTIC_DDL_037` for a fact,
`SEMANTIC_DDL_038` for a dimension).

**Each entry kind accepts a fixed set of clauses, and anything else is refused
by name.** A clause is recognised by its keyword and its value runs to the next
keyword, so an unrecognised word would otherwise become part of the previous
clause's value: `RETURNS DECIMAL(18,2) UNIT 'kg'` used to store the type
`DECIMAL(18,2) UNIT 'kg'`. The parser now refuses three things:
- a word that is no clause at all (`SEMANTIC_DDL_039`, which names the word and
  lists the accepted clauses);
- a clause that belongs to another kind, such as `WINDOW` on a dimension
  (`SEMANTIC_DDL_043`);
- a clause given twice (`SEMANTIC_DDL_044`).

| Kind | Clauses |
|---|---|
| `FACT` | `ON ENTITY`, `AS`, `RETURNS`, `DISPLAY`, `COMMENT`, `ADDITIVE`, `SEMI_ADDITIVE`, `NON ADDITIVE BY`, `PUBLIC`, `PRIVATE`, `CERTIFIED` |
| `DIMENSION` | `ON ENTITY`, `AS`, `RETURNS`, `FORMAT`, `DISPLAY`, `COMMENT`, `PUBLIC`, `PRIVATE`, `CERTIFIED` |
| `METRIC` | `AS`, `ON ENTITY`, `RETURNS`, `FILTER`, `FORMAT`, `UNIT`, `DISPLAY`, `COMMENT`, `SYNONYMS`, `DISTINCT_KEY`, `NON ADDITIVE BY`, `WINDOW`, `ADDITIVE`, `DERIVED`, `RATIO`, `DISTINCT`, `SEMI_ADDITIVE`, `PUBLIC`, `PRIVATE`, `CERTIFIED` |

`UNIT 'kg'` sets the metric's `UNIT_HINT`, which is what `SEMANTIC_MODEL_022`
asks a public numeric metric for, alongside `FORMAT`. Expression-valued clauses
(`AS`, `FILTER`, `DISTINCT_KEY`, `NON ADDITIVE BY`) hold SQL, so they are
checked only for a trailing `WORD 'literal'` pair. An unknown bare word after
an expression cannot be told apart from SQL (`SUM(x) WOMBAT` is valid alias
syntax), so it is caught later by validation, not by the parser.

A dimension takes the clauses of a fact that are not about aggregation — `ON
ENTITY`, `AS`, `RETURNS`, and optionally `DISPLAY`, `COMMENT`, `CERTIFIED`,
`PRIVATE` — plus `FORMAT`:

```sql
ALTER SEMANTIC VIEW sales.SALES
REPLACE DIMENSIONS (
  DIMENSION ship_mode
    ON ENTITY "order"
    AS o.ship_mode
    RETURNS VARCHAR(20)
    DISPLAY 'Ship Mode'
    COMMENT 'How the order shipped'
    CERTIFIED
);
```

`PRIVATE` maps to the catalog's `IS_HIDDEN`, which is how `DIMENSIONS` spells
what `FACTS` calls `IS_PRIVATE`. What it *means* — that the field is refused
wherever it is named, filters included — is on the
[governance page](governance.md), beside the other three policy columns and the
scripts that set them; this page describes only the grammar. `AS` requires `SEMANTIC_DDL_026` and `RETURNS`
requires `SEMANTIC_DDL_027`, mirroring a fact's `_021`/`_022`.

**Column order is a side effect of block order.** Each `REPLACE` block deletes
its kind's `OBJECT_COLUMNS` rows first, and the apply then re-adds dimensions,
facts and metrics in that order, each taking `MAX(ORDINAL_POSITION) + 1`. So one
statement carrying all three blocks renumbers the object from 1, in that order —
which is the order `sales_model_seed.sql` produces by calling `ADD_DIMENSION`
before applying its fact and metric blocks. Two separate statements interleave
instead: replacing dimensions on their own lands them *after* the surviving facts
and metrics. That matters beyond cosmetics, because OSI export carries these
ordinals into the imported model, so it is a published column order.

Fact and dimension *removal* have no single DDL form: they wait until
dependent-metric rewrites are transactional. A `REPLACE` block does remove — it
decides the object's membership, so anything left out of the block leaves the
object. Unsupported authoring forms fail during preprocessing instead of
returning a result row that callers might ignore. `SEMANTIC_ADMIN.ADD_DIMENSION`
and `SEMANTIC_ADMIN.ADD_OR_REPLACE_DIMENSION` remain available and are the way to
remove a single dimension (`REMOVE_DIMENSION`) or to add one outside a `REPLACE`
block's set semantics.

## Introspection Commands

After activation, modelers can use SQL-native introspection commands:

```sql
SHOW SEMANTIC VIEWS;
SHOW SEMANTIC VIEW sales.SALES;
SHOW SEMANTIC METRICS IN sales.SALES;
DESCRIBE SEMANTIC METRIC sales.SALES.total_revenue;
EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct;
EXPORT SEMANTIC MODEL sales;
```

## Hot Path

The preprocessor lane does not call `VALIDATE_MODEL` and does not write request
logs. It uses the latest successful validation run for the model version and
fails if no valid snapshot exists. Explicit agent calls through
`COMPILE_REQUEST_JSON` use the same validation gate and additionally write an
agent request log; they do not rerun validation during compilation.

Three properties keep that lane cheap, and each is load-bearing rather than
incidental:

1. **Nothing is imported until it can apply.** The script decides from the
   statement text, plus one small read of `SYS_SEMANTIC.MODELS`, whether the
   semantic-definition runtime, the compiler runtime, or neither could act.
   Importing both unconditionally cost about 21 ms on every statement in the
   session — including statements that never touch a semantic schema.
2. **The compile cache is consulted before the catalog is loaded.** A repeat
   query is answered from `SYS_SEMANTIC.COMPILE_CACHE` keyed on the token
   stream, so it never pays the catalog load that resolving field names would
   need. The key is insensitive to whitespace and comments and sensitive to
   everything else, including the case of string literals, which are filter
   values rather than identifiers.
3. **The catalog is loaded at most once.** Parsing hands its catalog context to
   the planner instead of letting it load the same object again.

Because a cache hit returns before the request has been built, this shortcut is
confined to the lane that writes no log. `COMPILE_SQL` and `COMPILE_SQL_DEBUG`
always parse, so `QUERY_LOG` keeps its requested dimensions and metrics.

An active preprocessor also taxes every *other* script in the session, because a
script's internal queries are statements too. See
[Admin setup for database-wide Semantic SQL](admin-db-wide-setup.md) for what
that costs and when to turn it off.
