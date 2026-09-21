# Governance

What this layer enforces, what it only reports, and where it stops. The
distinction matters more than the feature list: a control that looks like a
control and is not is worse than having neither, because someone relies on it.

---

## The one rule everything else follows from

**The compiler runs with the caller's rights.** An Exasol scripting script has
the privileges of whoever called it, not of whoever wrote it. So a caller can
always go around the compiler and query the physical tables directly, if they
have been granted them.

That single fact decides the shape of everything here:

> **Row and column policy lives in SQL the database enforces — a predicate in a
> governed view, a grant. The semantic layer may _add_ policy, and does, but is
> never the only thing applying it.**

Everything below is either *that* — a database-enforced control — or defence in
depth over it, and each section says which.

---

## 1. Which models a caller can see — enforced

`SEMANTIC_SOURCE` is a schema of thin views, one per catalog table the layer
reads, each filtered to the models the caller is authorized for. **Callers are
granted `SEMANTIC_SOURCE`; nobody is granted `SYS_SEMANTIC`.**

`SEMANTIC_CATALOG` and `SEMANTIC_AGENT` are granted to callers too, and they are
scoped by *reading* `SEMANTIC_SOURCE` rather than the tables — so the human
introspection surface and the agent discovery surface show a caller the same
models the compiler will let it query, and a view added to either inherits the
scoping by construction. The one exception is deployment identity
(`PRODUCT_VERSION`), which is a property of the installation rather than of any
model. A view is
owner-rights while `CURRENT_USER` and `EXA_SESSION_ROLES` inside it resolve to
the caller, so the filter is applied by the database rather than by the compiler
agreeing to apply it.

Authorization is **opt-in per model**:

| grants on the model | who can see it |
|---|---|
| none | everyone — this is the default, and it is what every model did before |
| one or more | those roles, plus the model's `OWNER_ROLE`, plus `DBA` |

Granting the first role is what turns a model private. Worth stating plainly: a
newly created model is **not** private by default.

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('sales', 'REGIONAL_ANALYST');
```

Inherited roles count. A user granted `REGIONAL_ANALYST`, which itself holds
`SEMANTIC_READER`, is a `SEMANTIC_READER` here — Exasol reports the transitive
closure in `EXA_SESSION_ROLES` and this layer asks for it.

A model you cannot see resolves to *not found* rather than to a modelling error.

---

## 2. Which relations a model vouches for — reported, and enforced in `GOVERNED`

`VALIDATE_MODEL` derives a **trust class** for every physical relation the
planner may emit — representations *and* materializations, by one derivation:
resolve transitive base relations through `EXA_ALL_DEPENDENCIES`.

| class | meaning |
|---|---|
| `GOVERNED` | resolves through a view, which can carry row and column policy |
| `RAW` | reads a base table directly, so it carries none |
| `DIVERGENT` | a materialization reading relations none of the representations read |
| `UNKNOWN` | the dependencies cannot be resolved — a virtual-schema relation, say |

`DIVERGENT` is the one that has bitten. A rollup built over the raw mart
substitutes for a proven branch and **drops whatever row policy the
representations carry, silently and for every caller**: a restricted principal
saw one region before the rollup was registered and every region after it, with
no error, no warning and no plan diagnostic.

```sql
SELECT RELATION_KIND, RELATION_NAME, TRUST_CLASS
FROM SEMANTIC_CATALOG.SOURCE_TRUST_FOR_MODEL WHERE MODEL_NAME = 'sales';
```

### Two modes

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_GOVERNANCE_MODE('sales', 'GOVERNED');
```

- **`OPEN`** (default) — the layer reports. A `DIVERGENT` materialization is a
  warning; a `RAW` representation is not flagged at all, because a model whose
  representations read base tables has no policy to lose and warning about it
  would be noise.
- **`GOVERNED`** — the layer refuses. Every representation must resolve through a
  view, a divergent materialization is an error, and **a compile is refused**
  (`SEMANTIC_REQUEST_028` / `SEMANTIC_QUERY_028`) when the SQL it produced would
  read such a relation. That covers freezing too: a `CREATE VIEW` over a semantic
  object has to compile the object first, and SQL that will not compile cannot be
  frozen.

  `RAW` is not refused. A materialization built *from* the governed views is a
  table, so it classifies `RAW` rather than `GOVERNED` while carrying their
  policy perfectly well; refusing it would make the mode unusable with any
  pre-aggregate. What is refused is what the model cannot vouch for: `DIVERGENT`,
  `UNKNOWN`, and a relation set no derivation has run against since it last
  changed.

A model is never moved to `GOVERNED` silently: you set it, then validate, and the
validation tells you what it costs.

---

## 3. Fields the model withholds — defence in depth

| column | on | effect |
|---|---|---|
| `IS_PRIVATE` | metrics | removed from discovery **and refused wherever named**, filters included |
| `IS_HIDDEN` | dimensions | the same |
| `DISPLAY_POLICY = 'MASK'` | either | the value is **not returned**; filtering on it still works |
| `SENSITIVITY_LABEL` | either | **a label.** Free text, surfaced, enforced by nothing |

Filters are included deliberately: a field removed from discovery but usable in a
`WHERE` is a field whose values you can binary-search.

`MASK` refuses the projection rather than returning a redacted value. ESV groups
by every selected dimension, so masking a dimension's *output* would either
collapse every row into one group or put a column of identical placeholders
beside real counts — and both silently change what the number means.

Only `MASK` has an effect; validation reports any other value in
`DISPLAY_POLICY` as a policy nobody applies (`SEMANTIC_MODEL_069`).

### How to set them

Two surfaces, split by what each column says about a field.

`IS_PRIVATE` and `IS_HIDDEN` say what the field **is** — an invisible one — so
they live with its definition, as the `PRIVATE` keyword in the semantic DDL:

```sql
ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE DIMENSION cost_centre
  ON ENTITY order AS o.cost_centre RETURNS VARCHAR(40) PRIVATE;
```

`PRIVATE` on a `DIMENSION` writes `IS_HIDDEN`, which is how `DIMENSIONS` spells
what `METRICS` and `FACTS` call `IS_PRIVATE`. The full DDL grammar is in
[the preprocessor page](semantic-sql-preprocessor.md).

`DISPLAY_POLICY` and `SENSITIVITY_LABEL` say how a **visible** field must be
handled. That is a decision made about a model that already exists, usually by
someone who did not write it, so it is a script — the field-level member of the
same family as `SET_MODEL_GOVERNANCE_MODE`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_FIELD_POLICY(
  'sales', 'SALES', 'customer_email', 'MASK', 'pii');

-- and NULL clears one; it is a value, not a no-op
EXECUTE SCRIPT SEMANTIC_ADMIN.SET_FIELD_POLICY(
  'sales', 'SALES', 'customer_email', NULL, NULL);
```

It refuses a name that is a fact, because neither column has a reader for one —
a fact is never returned to a caller, and the policy belongs on the metric built
from it. The value itself is not judged at write time: `VALIDATE_MODEL` owns the
`DISPLAY_POLICY` vocabulary and reports `SEMANTIC_MODEL_069` against it, so run
it before relying on what you set. Setting a policy clears the model's compile
cache, or a statement compiled under the old policy would go on being served
under the new one.

Until this release these two columns had no writer a steward could reach: the
only thing in the product that wrote either was a private helper inside the OSI
document importer, so the documented route to `MASK` was a direct `UPDATE` on
`SYS_SEMANTIC` — which this page tells you never to do, and which callers are no
longer granted.

**This is defence in depth, not a control.** A caller with rights on the physical
source reads the column regardless. Put the real control in the source.

---

## 4. Composition — refused by default

A published object can be joined to another table, and the join can repeat the
semantic result's rows so that re-aggregation double-counts: **7270 where the
model says 3635.** Refused with `SEMANTIC_QUERY_012` unless a model opts in with
`SET_MODEL_DERIVED_COMPOSITION`. See [BI tools](bi-tools.md#4-the-one-thing-that-is-refused).

---

## 5. Frozen views

`CREATE VIEW` over a semantic object stores *compiled* SQL. The view then answers
forever, for anyone, with no preprocessor — and with the model as it was when the
view was made. Nothing in the view says so.

The hazard this combines with: a view frozen while a `DIVERGENT` rollup was
active bakes that rollup in. The view reads the pre-aggregate and never touches
the governed sources again, so the row filter is gone permanently, in an object
that looks like an ordinary view.

So:

```sql
-- what is frozen, and whether the view still exists
SELECT VIEW_SCHEMA, VIEW_NAME, PRESENCE, FROZEN_RELATIONS
FROM SEMANTIC_CATALOG.FROZEN_VIEWS;

-- whether it still matches what the model compiles today
EXECUTE SCRIPT SEMANTIC_ADMIN.CHECK_FROZEN_VIEWS('sales');
```

`CHECK_FROZEN_VIEWS` recompiles the columns the view froze and compares. It is a
script rather than a validation rule because answering exactly needs the
compiler. There is deliberately **no version comparison**: ESV creates one model
version per model and authoring mutates it in place, so a version check could
never fire.

`VALIDATE_MODEL` reports the part the catalog can settle, which is the dangerous
part — `SEMANTIC_MODEL_068`, a frozen view reading a relation the model no longer
vouches for. In `GOVERNED` mode the view cannot be created in the first place,
because the compile behind it is refused.

---

## 6. The compile cache is checked, not trusted

`SYS_SEMANTIC.COMPILE_CACHE` is an ordinary table, and whoever can `UPDATE` it
chooses text that a published view then executes with the view owner's rights,
for every caller, with no compile in between.

A cached statement is therefore checked before it is served: it may read only
relations the model declares, and it must read at least one — `SELECT 'PWNED'`
reads none. A rejected entry is treated as a miss and dropped.

This is defence in depth. Until callers lose write access to the catalog, the
principal who can rewrite a cache row can also declare a relation. What it
removes is the far easier half.

---

## 7. Finding out what is in force

```sql
-- one row per model, with a sentence
SELECT MODEL_NAME, GOVERNANCE_MODE, VISIBLE_TO_CALLER, SUMMARY
FROM SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL;
```

> Open: the layer reports on its sources but enforces nothing about them. 4 read
> base tables directly and 1 substitutes for a representation without carrying
> its policy. Row and column policy has to live in the sources themselves.

After a query has run, `EXPLAIN_COMPILED_SQL` carries a `GOVERNANCE` column
saying the same thing about that statement — who compiled it, the mode in force,
and every relation it read with its trust class. `PLAN_JSON` carries the same as
a `governance` block for anything that wants to read it programmatically.

This works for statements from every lane, including the preprocessor, whose
rows land in `SEMANTIC_SOURCE.MY_QUERY_LOG`. Where a compile was served from the
cache the prose names the principal who *ran* the statement as well as the one
who compiled the plan: the generated SQL is identical, and what decided the rows
returned is the runner's own rights.

---

## 8. What this does not do

Stated plainly, because the value of the sections above depends on it.

- **It is not a replacement for database privileges.** The compiler runs as the
  caller. Everything in §3 and §6 is additional to source policy.
- **A caller with rights on the physical sources can bypass all of it** by
  querying them. That is not a defect; it is why §2 pushes policy into governed
  views, where the database enforces it for every client.
- **Callers still hold write access to the compile cache and the two logs**,
  because the compiler writes them as the caller. That is what makes §6
  necessary rather than redundant.
- **Trust classes are derived from `EXA_ALL_DEPENDENCIES`.** A view whose
  dependencies Exasol does not record classifies `UNKNOWN`, and `UNKNOWN` is
  treated as unvouched-for rather than assumed safe.
- **It proves a view stands between the caller and the base tables. It cannot
  prove the view's predicate is the right policy.** Claiming otherwise would
  repeat the mistake the `SENSITIVITY_LABEL` column used to make.
