# Data Fusion And Semantic Fusion

This page is for readers who already know what a semantic layer is (an entity
graph over physical tables, metric definitions, a compiler that turns a
metric-shaped request into SQL) but haven't run into "data fusion" as a named
problem. It defines the term, explains why it comes up as soon as a semantic
layer sits in front of more than one physical source, and describes what
Exasol Semantic Views does about it.

## What Data Fusion Is

Data fusion is what happens *after* data federation. Federation guarantees
that overlapping data ends up reachable from one place. Fusion is the policy
layer that decides which of the overlapping records — and which of their
conflicting values — is the answer. Data fusion resolves conflicts from
multiple sources.

The industry vocabulary that has settled around this problem:

- **Golden record** — one canonical row per resolved real-world entity.
- **Authority** (or "system of record") — which source wins for a given
  attribute.
- **Reconciliation** — the running check that keeps sources aligned by keys,
  counts, or hashes.
- **Identity graph** — the resolved links between source-specific keys.
- **Temporal validity** — `valid_from`/`valid_to` on a fact or attribute.
- **Partition alignment** — matching hot/cold or overlapping-ledger windows
  so nothing is double-counted.
- **Fan-out safety** (aka *symmetric aggregates*) — semantic-layer-specific
  correction for join-induced row duplication.

Fusion sits next to but is distinct from data integration (ETL/ELT — moves
and shapes), virtualization/federation (unified surface, no policy), entity
resolution (which rows refer to the same real thing — a prerequisite), and
MDM (the governance program around all of the above for reference entities).

## Why A Semantic Layer Has To Solve It

Most existing semantic layers solve one fusion sub-problem well: **fan-out**. 
The other fusion sub-problems (authority, temporal partitioning, cross-system
identity, model evolution) are left to the modeller.

Once the model spans more than one physical source, that gap is where
correctness quietly leaks — a hand-rolled `UNION ALL` between hot and
cold tables double-counts a boundary day; a CRM extract silently strands
$953k of revenue in a `NULL`-loyalty-tier bucket because the authoritative
warehouse column is missing for new customers; a customer table keyed
`CUSTOMER_ID DECIMAL(18,0)` and another keyed
`ACCOUNT_ID VARCHAR('ACC-000001')` refuse to join at all.

## What Semantic Fusion Adds

Semantic fusion in this project means: the modeller declares metadata for
each of these situations (coverage predicates, authority, semantic
identity, mapping relations) and the compiler translates that metadata into
correct SQL — deterministically, at compile time, with a validator that
proves the metadata safe before publish.

Three properties are non-negotiable:

1. **Governance, not optimisation.** The compiler consumes *certified*
   fusion metadata. Agents may propose fusion structure; humans certify;
   the runtime is deterministic. Fuzzy matching never happens at query
   time.
2. **The validator proves before the compiler emits.** Uniqueness, mapping
   totality and bijection, coverage exhaustiveness, key-set equivalence
   — all discharged as bounded key probes under a session `QUERY_TIMEOUT`
   before a model is publishable.
3. **Fail closed with a specific rule code.** Every failure mode has a
   `SEMANTIC_MODEL_0xx` diagnostic that names the affected object. The
   inventory is in `docs/validation-rules.md`.

## Vocabulary

- **Entity** — logical grain-bearing node (customer, order).
- **Representation** — one physical relation (table or virtual schema) that
  can serve an entity. An entity has exactly one active `PRIMARY`
  representation and any number of `ALTERNATE`s.
- **Coverage predicate + validity interval** — half-open `[from, to)` a
  representation is authoritative for. Predicate must exactly encode the
  interval; a mismatch is `SEMANTIC_MODEL_042`.
- **Attribute binding** — per-representation source expression for a
  dimension or fact. Role hierarchy `PREFER > FALLBACK`.
- **Attribute fusion policy** — how per-attribute values combine when
  multiple representations contribute: `PREFER` (single source),
  `COALESCE` (null-fill, agreement required), `RECONCILE` (authority wins,
  warn on conflict).
- **Authority** — `AUTHORITATIVE` / `PREFER` / `SUPPLEMENTAL` per
  representation. `RECONCILE` requires exactly one `AUTHORITATIVE`.
- **Semantic identity** — model-global identity name for an entity; used
  when representations don't share a physical key.
- **Identity binding** — per-representation `DIRECT` (local column equals
  the semantic key) or `MAPPED` (through a certified two-column relation).
- **Mapping relation** — the `CERTIFIED` cross-reference table that maps a
  source-local key to the semantic key.

## The Fusion Levels

| Level | Problem It Solves | Runtime Shape |
| --- | --- | --- |
| **Equivalent Representations** | Same entity, multiple physically-equivalent sources (federation, migration, materialisation) | Single branch, deterministic source selection |
| **Temporal Partition Fusion** | One entity split across disjoint half-open time windows (hot/cold, current/archive) | Multi-branch `UNION ALL` of aggregate states |
| **Attribute Reconciliation** | Overlapping representations where different systems own different attributes of the same rows | Key-preserving `LEFT JOIN`s + `COALESCE` |
| **Semantic Identity** | Representations of one entity that use different scalar keys | Contributor joins routed through a certified mapping relation |
| **Identity Remap** | An alternate with a renamed/typed/quoted-differently key column, no separate mapping table needed | Single branch; join predicate uses the anchored `DIRECT` expression |
| **Governed Model Evolution** | Keeping agent inference outside the query path | No SQL emission; audit-only proposal/review record |

### Equivalent Representations

Source plurality becomes a compile-time property. The validator proves
that two representations describe the same grain and key population;
the compiler picks one based on policy (`PREFER` before `FALLBACK`, then
priority, then `PRIMARY`). This is what lets a modeller materialise a hot
copy of an entity for a 20-minute experiment and swap it back without
editing semantics.

### Temporal Partition Fusion

This level exists because a hand-written `UNION ALL` on a date boundary
is one of the most common quiet-correctness footguns. Each partition
declares `coverage_predicate` + `valid_from`/`valid_to`; the compiler
clones every grain-proven leaf branch into one partition-branch per
representation and merges typed aggregate states across them. Only
mergeable aggregate states may cross partitions; `AVG(...)` alone is
rejected — at definition time, by `SEMANTIC_MODEL_057` — but `SUM/COUNT`
with an outer ratio survives. Temporal partition fusion is **mutually
exclusive** with Attribute Reconciliation on the same entity.

**Declaring a partition set: register and cover in one step.** A partition
is not a valid representation on its own. Until coverage exists, the
alternate is validated as an *equivalent* representation (F1), and hot/cold
key sets are disjoint by construction, so the candidate fails on key
cardinality (`SEMANTIC_MODEL_038`). Two orders work, and mixing them does
not:

- **Preferred, and the only one that is never invalid in between:**
  `ADD_ENTITY_REPRESENTATION_WITH_COVERAGE`, which validates the new
  representation and every coverage declaration as one candidate and seeds
  compatibility bindings. It works on a draft and on a published model, and
  it does not care whether the object already has dimensions, facts, or
  metrics.
- **If registering separately on a draft:** `ADD_ENTITY_REPRESENTATION`
  followed *immediately* by `SET_REPRESENTATION_COVERAGE_BATCH`, before any
  dimension or fact is added to the entity. Anything authored in between
  fails on the incomplete representation rather than on itself, and the
  bindings will not be seeded to the new partition.

Sequential single-representation coverage calls cannot initialize a
partition set; the batch call is what validates the set as a whole.

### Attribute Reconciliation

This is where fusion starts *changing the answer* rather than just the
plan. When authority is declared and the fusion policy is `COALESCE` or
`RECONCILE`, the compiler attaches key-preserving `LEFT JOIN`s to
contributor representations and rewrites the attribute expression as
`COALESCE(authoritative_expr, supplemental_expr, ...)`. Reconciled
dimensions replicate their joins inside every proven fact branch;
reconciled facts are not permitted (`SEMANTIC_REQUEST_074`).

### What An F4 Alternate Must Carry

Two rules decide whether a supplemental source can be registered at all, and
between them they make F4 look impossible when it is not:

1. **The alternate must be key-complete.** Its key set must match the primary's,
   because an alternate is validated as an *equivalent* representation
   (`SEMANTIC_MODEL_038` compares key cardinality). A CRM extract covering 67 of
   120 customers fails this. The fix is a key-completing view — a `LEFT JOIN`
   from the primary key set — which is a one-statement change and leaves the
   uncovered rows `NULL`.
2. **Every dimension of the entity must resolve on every representation**
   (`SEMANTIC_MODEL_017`), which reads like a contradiction of F4's purpose:
   different systems own different attributes. It is not, because of the escape
   hatch below.

**Modelling an attribute a representation does not carry.** Bind it explicitly
to a null cast. This is the supported way to say "this source has no opinion
about this attribute", and it validates and compiles:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION_WITH_BINDINGS(
  'sales', 'SALES', 'customer', 'customer_region', 'c.region', 'VARCHAR(20)',
  'Customer Region', 'Commercial region', NULL, TRUE,
  '[{"representation_name":"crm",
     "source_expression":"CAST(NULL AS VARCHAR(20))",
     "binding_role":"FALLBACK","binding_priority":2}]');
```

Plain `ADD_DIMENSION` is refused in that situation, because it would leave the
dimension unresolvable on the alternate. Use
`ADD_DIMENSION_WITH_BINDINGS`/`ADD_FACT_WITH_BINDINGS` whenever a representation
either computes the attribute differently *or* does not carry it at all.

### Semantic Identity

Unlocks Attribute Reconciliation — and cross-source joins in general —
for representations whose keys don't match. The validator probes local
uniqueness, mapping totality, bijection, and canonical semantic-key set
equality. Certification is the boundary: the compiler consumes the
mapping relation once it is `CERTIFIED`, and nothing before.

### Identity Remap

The escape hatch for the common case where an alternate has the right
key content but the wrong column name, type, or quoting — a `CAST` or
renamed identifier is all that's between it and the primary. No new
mapping relation is required; the compiler derives an anchored `DIRECT`
remap from the existing binding.

### Governed Model Evolution

Deliberately not part of the query path. Agents write proposals into
`MODEL_EVOLUTION_SUGGESTIONS`; humans certify or reject via
`REVIEW_MODEL_EVOLUTION`; the compiler ignores both tables entirely.
The audit record is one-way — certification doesn't activate anything,
it just records the decision.

## Seeing What Fusion Is Doing

Fusion changes the answer, so every declaration is discoverable as data rather
than only as catalog trivia:

```sql
SELECT ENTITY_NAME, FUSION_ASPECT, REPRESENTATION_NAME, ATTRIBUTE_NAME, STRATEGY
FROM SEMANTIC_AGENT.FUSION_FOR_AGENT
WHERE MODEL_NAME = 'sales'
ORDER BY ENTITY_NAME, FUSION_ASPECT;
```

`FUSION_ASPECT` separates the four kinds of declaration: `REPRESENTATION` and
`PARTITION` (with the coverage predicate and interval), `AUTHORITY`,
`ATTRIBUTE_POLICY`, and `IDENTITY` (with its certification status).

`OBJECTS_FOR_AGENT` and `FIELDS_FOR_AGENT` carry a summary of the same thing:

| Column | Meaning |
|---|---|
| `SOURCE_COUNT` | active representations of the entity behind the object or field |
| `FUSION_STRATEGY` | `UNION` for an F3 partition set, `COALESCE`/`RECONCILE` for a fused attribute, `NONE` for a single-source column |

Published columns carry the same fact in their comment, so a BI user who never
reads the catalog still sees it — for example *"Resolved customer name. Fused
across 2 sources (RECONCILE)."*

## Cost Model And Safeguards

Fusion multiplies branch count. `lua/semantic_layer/compiler/physical_plan.lua`
enforces two limits, both reported on `plan_json.safeguards`:

- `DEFAULT_MAX_BRANCHES = 8` — a plan that would produce more branches
  than this fails with `PLANNER_BRANCH_LIMIT_EXCEEDED`. Temporal Partition
  Fusion multiplies branch count by the number of covered representations
  per partitioned leaf; Attribute Reconciliation does not add branches
  (it adds `LEFT JOIN`s inside the existing branch).
- `DEFAULT_MAX_SQL_BYTES = 1000000` — the rendered SQL is measured
  against this and rejected with `PLANNER_SQL_SIZE_LIMIT_EXCEEDED` if
  exceeded.

Both are overridable per-request via `options.max_branches` and
`options.max_bytes`. When either fires, the plan JSON carries the actual
count, the limit, and the leaves that caused the multiplication — so the
diagnostic is actionable rather than opaque.

Materialization substitution is disabled for temporally-partitioned and
attribute-reconciled leaves — the substitution logic assumes a single
base source per leaf, which is exactly what fusion breaks. If you need
pre-aggregated speedups on a fused entity, declare the aggregate as a
fact in the semantic layer rather than as a compile-time materialization.

## Anti-Patterns

- **Don't hand-write `UNION ALL` on a date boundary.** It's easy to
  publish a model that looks clean but silently double-counts or drops
  boundary-day rows when the predicate and the interval disagree.
  Temporal Partition Fusion generates the predicate from the declared
  interval so they cannot diverge.
- **Don't `PREFER` when the authoritative source has holes.** You strand
  values in a `NULL` bucket. Use `COALESCE` with declared authority.
- **Don't route through a partial-coverage source as if it were
  complete.** Equivalent Representations refuses non-equivalent
  alternates by design.
- **Don't build cross-key identity by promoting a fuzzy match at
  runtime.** The compiler only consumes `CERTIFIED` mapping relations.
  Agents propose; humans certify; runtime stays deterministic.
- **Don't overload `RELATIONSHIPS` to mean source equivalence.** A join
  between business entities and equivalence between representations are
  different concepts with different validation.
- **Watch the Identity Remap blast radius.** One awkward endpoint (e.g.,
  a Parquet clickstream that stores `CUSTOMER_ID` as a string joined
  with a `CAST`) can disqualify the entity from fusing an unrelated pair,
  because the remap applies per-representation to every relationship on
  the entity.

## Where To Go Next

- `docs/semantic-catalog.md` — the physical catalog tables that back all
  of the vocabulary above.
- `docs/semantic-compiler.md` — how fusion metadata affects the plan.
- `docs/validation-rules.md` — the full rule inventory
  (`SEMANTIC_MODEL_034` through `_052` are fusion-specific).
- Live-DB worked examples, one per level:
  - `tools/verify_fusion_f3.py` — Temporal Partition Fusion
  - `tools/verify_fusion_f4.py` — Attribute Reconciliation
  - `tools/verify_fusion_f5.py` — Semantic Identity
  - `tools/verify_fusion_f51.py` — Identity Remap
  - `tools/verify_fusion_f7.py` — Governed Model Evolution

