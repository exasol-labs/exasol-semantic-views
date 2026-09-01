# Glossary

Every term this product uses, in the order you meet them. Read the first section
before your first model; the rest when you need them.

Definitions here are the authoritative ones. Where a doc explains a concept at
length it is linked, but nothing else should redefine a term.

---

## Grain — read this one first

**Grain** is *what one row of a relation represents.*

`MART.ORDER_LINES` has one row per line of an order, so its grain is
"order line". `MART.ORDERS` has one row per order, so its grain is "order".
Order grain is **coarser** than order-line grain: one order row corresponds to
several order-line rows.

Grain is the whole reason this product refuses things, because **joining from a
coarse grain to a finer one repeats the coarse rows.** Freight is charged once
per order. Join orders to their lines and a three-line order's freight appears
three times; sum it and you get a number that is simply wrong. That repetition is
called **fan-out**, and it is invisible in the result — the SQL succeeds and the
total is too big. The demo model shows it costing 149.00 against 105.25 actually
charged (see [Grain Safety You Can See](../README.md#grain-safety-you-can-see)).

So the layer tracks grain and refuses a combination that would fan out — at the
moment a metric is *defined*, not when someone queries it.

Two things declare grain, and they are not the same thing:

| | What it is | Who reads it |
|---|---|---|
| `UNIQUE_KEYS` (+ `UNIQUE_KEY_COLUMNS`) | the columns that make an entity's rows unique — `order_line_pk = (order_id, line_id)` | the validator and the compiler; **this is the machine-readable grain** |
| `ENTITIES.GRAIN_DESCRIPTION` | free prose — "one row per order line" | humans and agents reading the catalog |

Declare the keys. A relationship whose endpoint has no declared unique key still
compiles — legacy join checking remains available — but the compiler cannot use
it to *prove* grain, and `SEMANTIC_MODEL_031` warns that it is falling back.

### Three grains, kept distinct

"Grain" is used for three different things in a compiled query, and the compiler
keeps them separate on purpose:

| | What it is |
|---|---|
| **Entity grain** | the row identity of an entity, declared by `UNIQUE_KEYS` + ordered `UNIQUE_KEY_COLUMNS` |
| **Requested dimensionality** | the exact ordered dimensions a caller selected — the shape of the answer |
| **Merge identity** | internal keys the planner needs to join branches or prove a relationship, which never appear in the output grouping |

This is why a multi-fact request works at all. Each leaf metric is aggregated
independently, starting at its own base entity and going straight to the
requested dimensionality; compatible aggregate states are merged only *after*
that branch-local aggregation, and derived metrics are evaluated after the merge.
Joining the facts first would multiply rows and change the numbers.

The default result domain is the union of groups the selected metric branches
contribute. There is deliberately no dimension spine: picking a dimension table
to anchor the result would drop facts with no matching dimension row and invent
groups with no facts.

Related terms you will meet in refusals:

- **Fan-out** — one row repeated by a join to a finer grain. The spelling is
  `fanout` in column names (`FANOUT_POLICY`) and *fan-out* in prose.
- **Base entity** — the entity whose grain a metric aggregates at.
- **Object root** — the entity a semantic object is anchored to, which decides
  the grain its aggregates are *evaluated* at. A metric coarser than its
  object's root is refused with `SEMANTIC_MODEL_059`. See
  [Metric grain versus object root](validation-rules.md#metric-grain-versus-object-root).
- **Proof mode** — `LEGACY_JOIN` (default) or `STRICT_GRAIN`, how hard the
  compiler insists on structured key evidence before traversing a relationship.

---

## The nouns a first model needs

- **Model** — a named, versioned semantic model. `CREATE_MODEL` makes one;
  `PUBLISH_MODEL` exposes its active version as views in a schema of its own
  (`SEMANTIC_<MODEL>`).
- **Entity** — a logical, grain-bearing node such as `order_line`, `order`,
  `customer`. An entity is *not* a table: it is backed by one or more
  [representations](#the-nouns-fusion-adds), of which the simplest model has
  exactly one.
- **Semantic object** — the published view a user queries, anchored at one
  **root entity** and exposing a chosen set of dimensions and metrics. The
  demo model has two: `SALES` (rooted at `order_line`) and `ORDER_HEADER`
  (rooted at `order`). Two objects exist precisely because their metrics live at
  different grains.
- **Dimension** — an expression on an entity that you group, filter or explain
  by: `customer_region = c.region`. Queryable.
- **Fact** — a reusable *row-level* expression at an entity's grain:
  `net_revenue = ol.quantity * ol.net_unit_price`. **Not queryable.** A fact is
  an ingredient; you never select one.
- **Metric** — an aggregate over facts and other metrics, and the number a user
  actually asks for: `total_revenue = SUM(net_revenue)`. Queryable.
- **Relationship** — a declared join between two entities, carrying a
  cardinality (`MANY_TO_ONE`, `ONE_TO_MANY`, …) that tells the compiler whether
  traversing it preserves grain.
- **Unique key** — the ordered columns that make an entity's rows unique. This
  is how grain becomes machine-checkable; see [Grain](#grain--read-this-one-first).
- **Materialization** — a registered physical aggregate table the compiler may
  substitute for the full join when it provably answers the request. Pure
  acceleration: registering or losing one never changes an answer.

### Fact or metric?

The distinction trips everyone once. If you can point at a single row of the
source and read the value off it, it is a **fact**. If you have to aggregate
rows to get it, it is a **metric**. `net_revenue` is a fact; `total_revenue` is
a metric. `SEMANTIC_AGENT.FIELDS_FOR_AGENT` lists only dimensions and metrics,
because those are the only two things a query can name.

---

## The collective nouns

Three words group these three things, and **no two of them cover the same set.**
This is worth learning once rather than inferring per surface.

| Word | Covers | Where you meet it |
|---|---|---|
| **Field** | dimension, metric | the query surfaces — `FIELDS_FOR_AGENT`, the `field` key in a request, `FIELD_KIND` |
| **Attribute** | dimension, fact | the *binding* surfaces — `ATTRIBUTE_TYPE`, `ADD_ATTRIBUTE_BINDING`, `ATTRIBUTE_FUSION_POLICIES` |
| **Column** | dimension, fact, metric | `OBJECT_COLUMNS.COLUMN_KIND`, the projection of a published object |

The split is not arbitrary. A **field** is something a caller can *name in a
query*, so it excludes facts. An **attribute** is something that has to be
*bound to a physical expression per source*, so it excludes metrics — a metric is
computed from other model objects and never read from a column. **Column** is the
union, used where the surface is literally the list of output columns.

`measure` is a fourth word, and it is not a synonym for any of these: it appears
in `MEASURE_GROUPS_FOR_AGENT` (a labelled grouping of metrics), in
`METRICS.MEASURE_EXPR`, and as `MEASURE(...)` in the Databricks-compatible query
syntax.

---

## The nouns fusion adds

Read [docs/data-fusion.md](data-fusion.md) for what these are *for*; this is what
they *are*.

- **Representation** — one physical relation (table or virtual schema) that can
  serve an entity. Every entity has exactly one active `PRIMARY` representation
  and any number of `ALTERNATE`s. In a model that has never used fusion, the
  primary representation is created for you by `ADD_ENTITY` and carries the same
  source you passed it.
- **Coverage predicate + validity interval** — the half-open `[from, to)` window
  a representation is authoritative for. The predicate must exactly encode the
  interval; a mismatch is `SEMANTIC_MODEL_042`.
- **Attribute binding** — the per-representation source expression for one
  dimension or fact. Role hierarchy `PREFER > FALLBACK`.
- **Attribute fusion policy** — how values combine when several representations
  contribute the same attribute: `PREFER` (single source), `COALESCE` (null-fill,
  agreement required), `RECONCILE` (authority wins, warn on conflict).
- **Authority** — `AUTHORITATIVE` / `PREFER` / `SUPPLEMENTAL`, per
  representation. `RECONCILE` requires exactly one `AUTHORITATIVE`.
- **Semantic identity** — a model-global identity name for an entity, used when
  its representations do not share a physical key.
- **Identity binding** — how one representation reaches that identity: `DIRECT`
  (a local column *is* the semantic key) or `MAPPED` (through a certified
  two-column relation).
- **Mapping relation** — the `CERTIFIED` cross-reference table mapping a
  source-local key to the semantic key.

### The fusion levels, and what `F3` means in a refusal

Refusal messages use short numeric labels — *"F5 semantic identity cannot be
combined with F3 representation coverage on the same entity"*. This is what they
mean; the section names are from [semantic-catalog.md](semantic-catalog.md),
which is where each is specified.

| Label | Name | The problem it solves |
|---|---|---|
| `F0` | Compatibility representation | the single source `ADD_ENTITY` creates for you, conventionally named `primary` |
| `F1` | Equivalent representations | one entity, several interchangeable sources; requires key-set equality |
| `F2` | Attribute bindings and source selection | per-representation expressions, and how the compiler picks one complete representation |
| `F3` | Temporal partition fusion | one entity split across disjoint time windows (hot/cold, current/archive) |
| `F4` | Authority and reconciliation | different systems own — or disagree about — different attributes of the same rows |
| `F5` | Identity graph | representations that key the same entity differently. `F5.1` is the remap case, where an alternate simply names the key column differently |

[data-fusion.md](data-fusion.md) presents the same ground as six *named* levels
and groups them slightly differently — it treats the identity remap as a level of
its own and adds governed model evolution, which carries no `F` number. Read it
for what each is *for*; use the table above to decode a refusal.

---

## Governance, agents and operations

- **Validation run** — one execution of `VALIDATE_MODEL`, recording every issue
  with a `SEVERITY` (`ERROR`, `PRECONDITION`, `WARNING`) and a `RULE_CODE`.
  `ERROR` and `PRECONDITION` block a publish; `WARNING` does not.
- **Synonym** — an alternate name for a dimension or metric, so a caller asking
  for "revenue" reaches `total_revenue`.
- **Verified query** — a request that has been compiled and blessed, kept as a
  worked example for agents.
- **Agent instruction** — governed prose attached to a model, object, entity,
  dimension, fact or metric, surfaced to agents through the glossary.
- **Model evolution** — an agent's *proposal* to change the model, recorded for
  human review and never applied automatically. Stored in the
  `AGENT_SUGGESTION*` tables and read through the `MODEL_EVOLUTION_*` views.
- **Custom extension** — vendor metadata carried through OSI import and export
  without the layer interpreting it.

---

## Reading the catalog

Two conventions to know before you write a query against `SEMANTIC_CATALOG`.

### `STATUS` does not mean one thing

On most tables it is lifecycle
(`ACTIVE` / `INACTIVE`) and `WHERE STATUS = 'ACTIVE'` is what you want. On others
it is a run result (`OK` / `ERROR` / `WARNING` / `STALE`), a publication state
(`DRAFT` / `PUBLISHED`) or an apply outcome. Check
`SEMANTIC_CATALOG.CATALOG_COLUMNS` for the surface you are querying, and note
that the catalog views do **not** filter for you — they show every row, including
inactive ones and every model installed.

### An `*_ID` column is not always a foreign key

Six columns are *discriminated*: their target table is chosen by a sibling
column, so joining on the id alone silently mixes rows of different kinds.

| Id column | Discriminator | On |
|---|---|---|
| `OBJECT_ID` | `OBJECT_TYPE` | `SYNONYMS`, `MATERIALIZATION_COLUMNS`, `OBJECT_PRIVILEGES`, `AGENT_SUGGESTIONS` |
| `SCOPE_ID` | `SCOPE_TYPE` | `AGENT_INSTRUCTIONS`, `CUSTOM_EXTENSIONS` |
| `ATTRIBUTE_ID` | `ATTRIBUTE_TYPE` | `ATTRIBUTE_BINDINGS`, `ATTRIBUTE_FUSION_POLICIES` |
| `INPUT_OBJECT_ID` | `INPUT_OBJECT_TYPE` | `METRIC_INPUTS` |
| `OBJECT_REF_ID` | `COLUMN_KIND` | `OBJECT_COLUMNS` |
| `DEPENDS_ON_OBJECT_ID` | `DEPENDS_ON_OBJECT_TYPE` | `METRIC_DEPENDENCIES` |

`OBJECT_ID` on `OBJECT_COLUMNS` and `VERIFIED_QUERIES` is an ordinary foreign key
to `SEMANTIC_OBJECTS` — same name, different rule. Rather than remember any of
this, ask the catalog:

```sql
SELECT RELATIONSHIP_KIND, CHILD_COLUMN, PARENT_SURFACE, JOIN_TEMPLATE
FROM SEMANTIC_CATALOG.CATALOG_RELATIONSHIPS
WHERE CHILD_SURFACE = 'METRIC_INPUTS';
```

See [docs/semantic-catalog.md](semantic-catalog.md).

---

## Where to go next

| You want to | Read |
|---|---|
| Define your first metric | [creating-metrics.md](creating-metrics.md) |
| Understand a refusal | [validation-rules.md](validation-rules.md) |
| Query the model | [semantic-compiler.md](semantic-compiler.md#which-query-lane) |
| Combine several sources | [data-fusion.md](data-fusion.md) |
| Build an agent against it | [agent-contract.md](agent-contract.md) |
| Browse the catalog | [semantic-catalog.md](semantic-catalog.md) |
