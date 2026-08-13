# Architecture

The system is a database-resident semantic layer with two equal priorities:

1. Give agents a constrained, inspectable interface for discovering and querying
   governed business concepts.
2. Preserve the relational behavior expected by classical data warehouses and BI
   clients while extending it to fuse equivalent data across heterogeneous
   physical sources.

Those priorities lead to a deliberate separation of responsibilities. Catalog
state describes meaning. Validation certifies that the meaning is executable and
grain-safe. The compiler turns a semantic request into deterministic SQL. Exasol
still performs authorization, optimization, and execution. Agents never invent a
hidden execution path, and the semantic layer never replaces the database engine.

## Architectural Thesis

A useful semantic layer is not a collection of friendly column names. It is an
executable contract connecting five kinds of information:

| Concern | Contract |
| --- | --- |
| Business meaning | Metrics, dimensions, facts, synonyms, instructions, and verified queries |
| Relational meaning | Entities, objects, keys, relationships, cardinalities, and grain proofs |
| Physical meaning | Representations, attribute bindings, source expressions, and materializations |
| Fusion meaning | Coverage, authority, reconciliation policy, and semantic identity |
| Governance | Validation runs, publication state, privileges, request history, feedback, and review |

The catalog stores these contracts separately because they change at different
rates. A business metric can remain stable while its source moves. Two source
systems can expose the same entity with different column names. A materialized
aggregate can be added without changing the metric definition. An agent-facing
synonym can evolve without changing generated SQL semantics.

Compilation reconnects these layers for one request. The compiler first resolves
business names, then proves the requested grains and relationships, then chooses
physical representations and optimizations, and only then renders SQL. This order
is the core correctness property: physical convenience cannot redefine business
meaning.

## What Agent-First Means

Agent-first does not mean putting a language model inside Exasol. The runtime
makes no LLM calls and does not depend on probabilistic inference. It means the
semantic layer is designed so an agent can operate safely without reverse
engineering arbitrary DDL or guessing SQL.

An agent-first system needs more than metadata:

- **A bounded discovery surface.** `SEMANTIC_AGENT` exposes role-visible models,
  objects, fields, valid combinations, instructions, glossary terms, verified
  queries, validation failures, and request history.
- **A closed request language.** `COMPILE_REQUEST_JSON` accepts a versioned schema
  of semantic names and operations. Unknown fields are rejected rather than
  ignored, so a typo cannot silently change a question.
- **Deterministic lowering.** The same canonical request against the same model
  version produces the same logical choices and SQL shape.
- **Actionable failure.** Unsupported combinations fail with stable issue codes,
  clarification details, and plan provenance instead of falling back to guessed
  joins or approximate metrics.
- **Executable examples.** Verified queries expose both natural-language intent
  and replayable `request_json`, not only prose.
- **Separation of compile and execute.** The semantic runtime returns generated
  SQL. The caller executes that SQL under ordinary Exasol privileges.
- **A governed learning loop.** Durable request handles connect explanations,
  feedback, suggestions, and human review without allowing an agent to mutate the
  semantic model automatically.

This design is stricter than an agent generating SQL directly. That strictness is
intentional. A fluent but invalid answer is more dangerous than a clear refusal,
especially for derived metrics, multi-fact questions, or fused sources where SQL
can execute successfully while producing the wrong grain.

The same constraints benefit non-agent clients. BI tools and human SQL users use
the same compiler and therefore receive the same metric definitions, relationship
proofs, source choices, and validation gates.

## System Topology

The deployed system has five database-facing layers and a shared Lua compiler:

```text
Authoring and administration
        |
        v
SEMANTIC_ADMIN scripts ------------------------------+
        |                                             |
        v                                             |
SYS_SEMANTIC authoritative catalog                    |
        |                                             |
        +--> SEMANTIC_CATALOG metadata views          |
        +--> SEMANTIC_AGENT role-scoped views         |
        +--> published SEMANTIC_<MODEL> views         |
                                                      |
Agent JSON request --> QuerySpec ---------------------+
Semantic SQL -------> QuerySpec --> compiler --> generated SQL
Published view SQL --> preprocessor ------------------+
                                            |
                                            v
                              Exasol optimizer/executor
                                            |
                                            v
                                   ordinary result set
```

### `SYS_SEMANTIC`

`SYS_SEMANTIC` is the authoritative internal catalog. Its tables are created in
[`001_create_semantic_catalog.sql`](../sql/install/001_create_semantic_catalog.sql).
Application code should not treat these tables as a public API. Their purpose is
to provide normalized, transactionally mutable state to the admin, validation,
compiler, and publication runtimes.

### `SEMANTIC_CATALOG`

`SEMANTIC_CATALOG` is the read-only administrative projection of catalog state.
It is suitable for humans, diagnostics, and tools that need complete model
metadata. Keeping it separate from `SYS_SEMANTIC` permits the storage schema to
evolve while preserving a supported inspection surface.

### `SEMANTIC_AGENT`

`SEMANTIC_AGENT` is a machine-oriented and role-scoped projection. It includes
views such as:

- `MODELS_FOR_AGENT`
- `OBJECTS_FOR_AGENT`
- `FIELDS_FOR_AGENT`
- `VALID_COMBINATIONS_FOR_AGENT`
- `VALIDATION_ERRORS_FOR_AGENT`
- `COMPILE_REQUEST_SCHEMA_FOR_AGENT`
- `MEASURE_GROUPS_FOR_AGENT`
- `VERIFIED_QUERIES_FOR_AGENT`
- `INSTRUCTIONS_FOR_AGENT`
- `BUSINESS_GLOSSARY_FOR_AGENT`
- `REQUEST_HISTORY_FOR_AGENT`
- `MODEL_EVOLUTION_REVIEW_QUEUE`

This is not merely a renamed catalog. It deliberately hides inaccessible objects
and shapes records for discovery and tool use. Request history is restricted to
the current user or privileged administrators.

### `SEMANTIC_ADMIN`

`SEMANTIC_ADMIN` contains the supported mutation and runtime procedures. It owns
model authoring, semantic-definition application, validation, publication,
compilation, explanation, feedback, and evolution review. These scripts are the
transaction and policy boundary around catalog writes.

The canonical implementation is under [`lua/semantic_layer`](../lua/semantic_layer).
[`package_lua_scripts.py`](../tools/package_lua_scripts.py) packages those modules
into installable Exasol Lua scripts. The generated SQL bundle is not a separate
implementation.

### Published schemas

Publishing a model creates a schema such as `SEMANTIC_SALES`. Its views expose
typed columns and comments so relational clients can discover a familiar table
surface. They are guarded semantic entry points, not ordinary views over a fixed
physical table.

When a SQL preprocessor is active, a query against a published view is lowered
through the semantic compiler. Without the preprocessor, the guard raises a clear
error rather than returning dummy data or accidentally bypassing semantic logic.
Clients that cannot use the preprocessor can call the explicit compile APIs.

## Catalog Model

The catalog is normalized around stable semantic identity rather than generated
SQL text. The principal domains are:

| Domain | Principal tables |
| --- | --- |
| Model lifecycle | `MODELS`, `MODEL_VERSIONS`, `MODEL_PUBLISH_HISTORY` |
| Logical graph | `ENTITIES`, `SEMANTIC_OBJECTS`, `RELATIONSHIPS`, `RELATIONSHIP_KEY_MAPPINGS` |
| Grain | `UNIQUE_KEYS`, `UNIQUE_KEY_COLUMNS` |
| Physical sources | `ENTITY_REPRESENTATIONS`, `ATTRIBUTE_BINDINGS` |
| Business fields | `DIMENSIONS`, `FACTS`, `METRICS`, `METRIC_INPUTS`, `METRIC_FILTERS`, `METRIC_DEPENDENCIES` |
| Fusion | `REPRESENTATION_AUTHORITIES`, `ATTRIBUTE_FUSION_POLICIES`, `SEMANTIC_IDENTITIES`, `IDENTITY_BINDINGS`, `IDENTITY_MAPPING_RELATIONS` |
| Language and guidance | `SYNONYMS`, `AGENT_INSTRUCTIONS`, `VERIFIED_QUERIES`, `CUSTOM_EXTENSIONS` |
| Optimization | `MATERIALIZATIONS`, `MATERIALIZATION_COLUMNS`, `COMPILE_CACHE` |
| Governance | `VALIDATION_RUNS`, `VALIDATION_RESULTS`, `METRIC_DIMENSION_MATRIX`, `OBJECT_PRIVILEGES`, `MODEL_ROLE_GRANTS` |
| Operations and evolution | `QUERY_LOG`, `AGENT_REQUEST_LOG`, `AGENT_FEEDBACK`, `AGENT_SUGGESTIONS`, `AGENT_SUGGESTION_TARGETS`, `AGENT_SUGGESTION_REVIEWS` |

### Entity, object, and representation

These concepts are intentionally distinct:

- An **entity** is a logical relational node with a grain, such as customer,
  order, or order item.
- A **semantic object** is a query root presented to clients. It determines the
  starting context in which fields and metrics are resolved.
- A **representation** is a physical relation that can supply an entity. It may
  be a local table, view, or relation exposed through a Virtual Schema.

In a conventional warehouse an entity often has one representation, so the
distinction is unobtrusive. In a heterogeneous system the distinction is what
allows a stable customer concept to survive source migration, coexist with a
federated copy, or reconcile attributes from multiple systems.

Every active entity has exactly one active `PRIMARY` representation. Additional
`ALTERNATE` representations are explicit catalog objects, not implicit fallback
tables. Source aliases remain semantic aliases across representations; physical
column differences are handled by attribute bindings.

### Dimensions, facts, and metrics

A dimension or fact is a row-level semantic expression bound to an entity. A
metric is an aggregate or derived business calculation. The separation matters:

- Dimensions determine grouping and filtering domains.
- Facts provide row-level numeric or otherwise aggregatable inputs.
- Metrics define aggregation and derived calculation semantics.

Metric dependencies form a typed directed acyclic graph. Leaf metric inputs bind
to facts; aggregate-state producers compute mergeable states; scalar finalizers
combine those states after branch merging. This is what allows a derived metric
such as average order value to remain correct when revenue and order count come
from separate fact branches.

### Keys and relationships

Keys are not documentation hints. Ordered unique-key columns and ordered
relationship endpoint mappings are proof inputs. They let validation and
compilation determine whether traversing a relationship preserves or multiplies
the current grain.

The canonical graph logic lives in
[`grain_graph.lua`](../lua/semantic_layer/shared/grain_graph.lua) and is shared by
the validator and compiler. A model cannot be certified under one interpretation
of cardinality and compiled under another.

## Classical Warehouse Path

The simplest model is also a first-class design target:

```text
fact table entity
  +-- MANY_TO_ONE --> date dimension entity
  +-- MANY_TO_ONE --> product dimension entity
  +-- MANY_TO_ONE --> customer dimension entity
```

Each entity has one primary representation. Facts and dimensions bind directly to
columns or expressions. Relationships describe the star or snowflake graph.
Metrics aggregate facts. A semantic object supplies the query root.

For this shape, Semantic Views provides:

- Stable business names over physical columns.
- Reusable metric definitions rather than copied BI formulas.
- Explicit relationship and cardinality metadata.
- Strict key-based grain proofs where structured mappings are available.
- A compatibility join mode for legacy models that predate complete grain
  metadata.
- Published relational views for BI metadata discovery.
- JSON and Semantic SQL entry points backed by the same compiler.
- Optional aggregate materialization substitution below the semantic contract.

The fusion architecture does not impose distributed execution on this path. A
single-representation warehouse model remains a normal SQL compilation problem,
and Exasol remains responsible for join ordering, predicate execution, and
physical query optimization.

## Semantic Fusion Path

Semantic fusion handles the case where one logical entity is represented by more
than one physical source. These sources may differ in location, schema, coverage,
or authority. They are not assumed interchangeable merely because they have
similar columns.

The architecture separates four questions:

1. **Equivalence:** Do the representations describe the same entity grain and key
   population?
2. **Binding:** How is each semantic attribute computed in each representation?
3. **Composition:** Should a query choose one representation, partition work
   between them, or reconcile values from several?
4. **Identity:** How can rows be aligned when physical source keys differ?

Conflating these questions would make unsafe joins look like source selection.
Keeping them explicit makes every fusion decision certifiable and explainable.

### Representation equivalence

An alternate representation must expose the complete semantic and key interface
required by the entity. Validation proves unique grain and exact key-set equality
for equivalent alternates when multiple representations require data probes.

Remote probes are validation operations, not query-time business operations. They
are bounded by a query timeout so a slow or stalled federated source produces a
validation failure rather than hanging model certification indefinitely. Local
structural checks run before probes to avoid unnecessary network work on an
already invalid model.

Equivalence permits deterministic source choice; it does not by itself combine
values from both sources.

### Attribute binding

`ATTRIBUTE_BINDINGS` maps a logical dimension or fact to a physical expression in
each representation. This supports ordinary column renaming as well as
source-specific normalization, for example a timestamp column in one relation and
a cast expression in another.

Selection first requires a representation to have complete bindings for the
requested semantic interface. Eligible bindings then follow declared role and
priority rules. `PREFER` precedes `FALLBACK`; binding priority is considered;
`PRIMARY` is the deterministic tie-break before representation priority and ID.

This is policy-driven, not a cost-based adaptive optimizer. Current source choice
does not change with transient latency or freshness. The chosen representation,
bindings, and reasons are recorded in the plan so the answer is reproducible.

### Temporal partitioning

Coverage metadata can declare that representations own disjoint half-open time
intervals. Validation requires active coverage to be canonical, complete, and
contiguous. The compiler then expands one metric leaf into one branch per covered
representation:

```text
representation A [start, cutover)
        +
representation B [cutover, end)
        |
        v
aggregate each branch -> UNION ALL states -> merge -> finalize
```

Partitioning is useful for a local historical archive plus a federated current
source, or during a controlled source migration. It is currently supported for
metric leaves, where aggregate-state merging can preserve semantics. A joined
dimension is not silently partitioned, and only mergeable aggregate forms such as
`SUM` and `COUNT` may cross branches.

### Authority and reconciliation

Some representations overlap because different systems are authoritative for
different attributes. `REPRESENTATION_AUTHORITIES` and
`ATTRIBUTE_FUSION_POLICIES` make that choice explicit.

The supported policies have materially different semantics:

| Policy | Behavior |
| --- | --- |
| `PREFER` | Select one eligible source according to authority and binding rules |
| `COALESCE` | Align rows and require non-null values from contributors to agree |
| `RECONCILE` | Align rows and choose the authoritative value, recording conflict provenance |

`COALESCE` fails on contradictory non-null values. `RECONCILE` permits the
authoritative contributor to win and emits a warning. Both require a key-preserving
alignment through a shared physical key or a certified semantic identity.

Reconciled dimensions can participate inside each proven multi-fact branch.
Reconciled facts are rejected because joining overlapping fact sources can change
measure grain before aggregation. Fusion and partitioning are also mutually
exclusive for the same entity: one composes overlapping rows, while the other
asserts disjoint ownership.

### Semantic identity

Physical key equality is not always semantic identity. One source may identify a
customer by an ERP number and another by a CRM number. `SEMANTIC_IDENTITIES`
defines the stable entity-level identity contract; `IDENTITY_BINDINGS` describes
how each representation reaches it.

Two binding forms are supported:

- `DIRECT` computes the semantic key directly from a source-local expression.
- `MAPPED` uses a certified two-column mapping relation between a source key and
  the semantic key.

Validation checks totality, uniqueness, bijection where required, and exact key
sets. Identity is therefore a declared, testable mapping, not fuzzy entity
resolution. The runtime does not infer that similar names, emails, or JSON paths
refer to the same person.

Relationship-aware compilation can remap an endpoint through an alternate
`DIRECT` scalar identity binding when its key mapping matches a scalar unique key
and the primary identity is anchored. General mapped relationship remapping still
requires a canonical relation or view.

Current identity is deliberately scalar. Composite semantic identities and
arbitrary nested identity values are not yet compiler primitives. Nested data can
be projected by Exasol JSON Tables into relational scalar keys and mapping
relations before it enters this contract.

## Validation and Certification

The catalog can represent incomplete authoring state; it must not compile that
state as certified semantics. `VALIDATE_MODEL` is the boundary between declaration
and executable trust.

Validation covers:

- Catalog structure, names, references, and model lifecycle invariants.
- Source object and source column existence.
- SQL expression syntax and supported function policy.
- Entity unique-key declarations and data-level uniqueness.
- Relationship mappings, declared cardinality, and grain compatibility.
- Metric inputs, dependency cycles, aggregate semantics, and filter scopes.
- Representation roles, bindings, key-set equivalence, and bounded probes.
- Temporal coverage completeness and partition fusability.
- Attribute authority, reconciliation conflicts, and fusion compatibility.
- Semantic identity totality, uniqueness, and mapping relations.
- Agent instructions, verified queries, synonyms, and other governed metadata.

Each run writes `VALIDATION_RUNS` and `VALIDATION_RESULTS`. Successful validation
also derives compiler-facing artifacts such as dependency data and the
metric-dimension compatibility matrix. The latest successful run is tied to the
active model version. Compilation checks that certification instead of rerunning
source probes for every request.

This distinction is important operationally:

- Validation may inspect source data and remote representations.
- Compilation is metadata-driven and deterministic.
- Query execution reads the selected business data under the caller's privileges.

Admin mutations invalidate affected compile-cache entries and stale validation.
For published models, mutation APIs protect the live surface prospectively: they
stage the candidate catalog change, validate the assembled state, and restore and
recertify the prior state if the candidate fails. Compound APIs are provided where
a valid declaration requires several catalog rows to change atomically. This
prevents a multi-step authoring operation from exposing an invalid intermediate
state to readers.

The system is not a general copy-on-write development branch manager. Model
versions and publication history provide lifecycle identity and auditability;
published-state protection is implemented by validated mutation transactions and
rollback around the active catalog state.

## Compiler Architecture

Both input languages lower to one internal request contract:

```text
JSON request --------+
                     +--> QuerySpec --> CatalogSnapshot --> MetricPlan
Semantic SQL --------+                                      |
                                                            v
                                                     PhysicalPlan
                                                            |
                                                            v
                                                       Exasol SQL
```

The public entry points are:

- `COMPILE_REQUEST_JSON`
- `COMPILE_SQL`
- `COMPILE_SQL_DEBUG`
- `SUGGEST_GRAIN_METADATA`

### Query normalization

[`query_spec.lua`](../lua/semantic_layer/compiler/query_spec.lua) defines the
canonical request boundary shared by JSON and Semantic SQL. It resolves syntax
differences before planning and preserves user-visible ordering where ordering is
semantically relevant.

The canonical request is also the cache identity. Logging-only metadata is
removed from cache keys, while semantic order is retained. This gives idempotent
planning without conflating requests that request different result ordering.

### Catalog snapshot

[`catalog_snapshot.lua`](../lua/semantic_layer/compiler/catalog_snapshot.lua)
loads a detached, model-versioned planner input. It includes transitive private
metric dependencies and all metadata needed for proof and physical binding.

Detaching the snapshot has three benefits:

- Planner modules do not issue ad hoc catalog queries while making decisions.
- A plan can name the exact model state from which it was derived.
- Tests can exercise planning against explicit fixtures rather than a live mutable
  catalog.

### Logical metric plan

[`metric_plan.lua`](../lua/semantic_layer/compiler/metric_plan.lua) builds a typed
metric dependency DAG and a proof-rich logical plan. It decides what must be
calculated, at which grain, and in which stage. It does not format final SQL.

The planner distinguishes fact leaves, aggregate-state producers, and derived
finalizers. It attaches relationship proofs to every required route and rejects a
request before physical planning if any branch cannot safely reach a requested
dimension.

### Physical plan

[`physical_plan.lua`](../lua/semantic_layer/compiler/physical_plan.lua) binds the
logical plan to representations, attribute expressions, fusion contributors,
partitions, and materializations. It produces a typed multi-branch aggregate-state
plan with stable decision and rejection reasons.

Safety limits bound generated complexity. The current planner permits at most
eight branches and one megabyte of generated SQL. A request that exceeds those
limits fails explicitly rather than producing an uncontrolled statement.

### SQL rendering

[`grain_sql.lua`](../lua/semantic_layer/compiler/grain_sql.lua) renders the proven
plan. Rendering is intentionally decision-free: it cannot choose a relationship,
switch a source, or reinterpret a metric. That keeps SQL formatting concerns from
becoming a second planner.

[`request_json.lua`](../lua/semantic_layer/compiler/request_json.lua) orchestrates
the public compile flow, cache lookup, plan serialization, request logging, and
response envelopes.

## Grain Safety and Multi-Fact Queries

SQL validity is weaker than semantic validity. A join can execute and still
duplicate a measure. Grain proofs are therefore explicit compiler values.

Two proof modes exist:

- `LEGACY_JOIN` preserves compatibility for models with older relationship
  metadata.
- `STRICT_GRAIN` requires ordered endpoint mappings, matching unique keys, and a
  cardinality direction that preserves the branch grain.

Strict proof rejects unsupported many-to-many traversal and expression-based key
mappings. The multi-fact planner consumes only strict proofs.

For a request involving several fact grains, the compiler does not create one
large join and aggregate afterward. It follows an aggregate-state strategy:

```text
fact leaf A -> prove dimensions -> aggregate SUM/COUNT state --+
                                                            +--> UNION ALL
fact leaf B -> prove dimensions -> aggregate SUM/COUNT state --+       |
                                                                    merge states
                                                                         |
                                                               finalize derived metric
```

Predicates are placed according to their semantic stage: source-local filters,
branch filters, global dimension filters, and final aggregate filters are not
interchangeable. Derived metrics are finalized only after their input states have
been merged.

Empty-state behavior is explicit: an empty `COUNT` state becomes zero, while an
empty `SUM` state remains null. Distinct aggregates, window functions, and other
non-additive calculations are not treated as mergeable. If such a calculation
would require multi-branch merging, compilation fails closed.

## Materialization Architecture

Materializations are an optimization registry, not alternate semantic models.
They are considered only after the request's logical meaning and grain have been
proven.

[`materializations.lua`](../lua/semantic_layer/compiler/materializations.lua)
checks whether a candidate provides complete field, aggregate-state, filter, and
grouping coverage and whether any rollup is safe. In a multi-fact plan each leaf
branch is considered independently, and a selected materialization must replace a
complete branch source rather than a convenient subset.

Rejected candidates and their reasons remain in plan provenance. If no candidate
is safe, the compiler uses base relations. It never accepts an approximately
matching aggregate to avoid a slower query.

Runtime timing is deliberately excluded from deterministic plan JSON. The current
registry is policy-driven and manually declared, not an adaptive optimizer that
changes plans based on transient measurements.

## Publication and SQL Integration

Publication is a certification event, not just DDL generation. `PUBLISH_MODEL`
validates the active model, records publication history, and creates the guarded
relational facade.

There are three equivalent runtime lanes:

### Agent lane

```text
SEMANTIC_AGENT discovery
  -> SEMANTIC_ADMIN.COMPILE_REQUEST_JSON
  -> generated SQL + plan + request handle
  -> caller executes SQL
  -> optional explanation or feedback
```

### Semantic SQL lane

```text
semantic SQL text
  -> SEMANTIC_ADMIN.COMPILE_SQL
  -> QuerySpec and shared compiler
  -> generated SQL
  -> caller executes SQL
```

### Published-view lane

```text
SELECT from SEMANTIC_<MODEL>.<OBJECT>
  -> session SQL preprocessor
  -> shared compiler
  -> generated SQL
  -> Exasol execution
```

The preprocessor is session-scoped by default. It recognizes semantic statements
and published surfaces, delegates planning, and returns ordinary Exasol SQL. This
allows BI-oriented relational syntax without maintaining a separate BI compiler.

## Security Model

The semantic compiler is not an authorization bypass.

- Generated SQL executes with ordinary Exasol source privileges.
- `SEMANTIC_AGENT` discovery is filtered by semantic object privileges and model
  role grants.
- Published objects are guarded against direct execution without semantic
  rewriting.
- Request history is scoped to its user except for privileged administration.
- Dynamic SQL uses validated types and quoted identifiers and literals.
- Internal `SYS_SEMANTIC` storage is separated from supported read and mutation
  APIs.

Semantic visibility and physical source access are both required. Granting an
agent permission to discover a metric does not implicitly grant access to its
underlying tables, and source-table access alone does not expose hidden semantic
objects through the agent views.

## Explainability and Operational State

The compile response is an operational artifact, not only SQL text. Depending on
the entry point it includes generated SQL, plan JSON, stable diagnostics,
clarification details, validation identity, and a durable request handle.

Plan provenance records decisions such as:

- Metric dependency and finalization stages.
- Relationship routes and grain proofs.
- Selected representations and attribute bindings.
- Partition and fusion contributors.
- Materialization selection and rejected candidates.
- Warnings produced by reconciliation or compatibility behavior.

`QUERY_LOG`, `AGENT_REQUEST_LOG`, and `COMPILE_CACHE` serve different purposes.
The cache avoids repeat planning for a canonical request and certified model
version. Logs provide durable operational history. Feedback references request
handles so reviewers can reconstruct the semantic request and plan that produced
an answer.

Suggestions are typed, versioned, idempotent proposals. They enter a review queue
and can be accepted or rejected by governed workflows. Agent feedback therefore
improves the model through explicit review; it does not silently rewrite metrics,
relationships, or source policy.

## Failure Model

The architecture prefers a diagnosable refusal over a plausible wrong answer.
Important fail-closed boundaries include:

- An uncertified or stale model cannot compile as valid.
- An unknown request property cannot be silently discarded.
- An ambiguous or grain-changing relationship cannot satisfy a strict proof.
- An incomplete physical binding cannot be selected.
- An unbounded or invalid remote probe cannot certify an alternate source.
- Overlapping temporal partitions cannot be unioned as disjoint data.
- Reconciliation cannot align contributors without certified identity.
- A non-mergeable aggregate cannot cross multi-fact or partition branches.
- A partial materialization cannot replace a complete semantic branch.
- A published facade cannot execute without semantic rewriting.

Stable error codes are part of this contract. They let agents distinguish a
request that needs clarification from a model defect, unsupported feature, source
failure, or authorization failure without parsing arbitrary prose.

## Code Map

The main implementation boundaries are:

| Path | Responsibility |
| --- | --- |
| [`sql/install/001_create_semantic_catalog.sql`](../sql/install/001_create_semantic_catalog.sql) | Authoritative catalog tables and storage invariants |
| [`lua/semantic_layer/admin`](../lua/semantic_layer/admin) | Authoring, semantic DDL, validation, publication, and lifecycle policy |
| [`lua/semantic_layer/shared/grain_graph.lua`](../lua/semantic_layer/shared/grain_graph.lua) | Shared relationship graph and grain proof logic |
| [`lua/semantic_layer/compiler/query_spec.lua`](../lua/semantic_layer/compiler/query_spec.lua) | Canonical request language |
| [`lua/semantic_layer/compiler/catalog_snapshot.lua`](../lua/semantic_layer/compiler/catalog_snapshot.lua) | Detached model-versioned planner input |
| [`lua/semantic_layer/compiler/metric_plan.lua`](../lua/semantic_layer/compiler/metric_plan.lua) | Metric DAG, grain proof, and logical planning |
| [`lua/semantic_layer/compiler/physical_plan.lua`](../lua/semantic_layer/compiler/physical_plan.lua) | Representation, fusion, branch, and aggregate-state planning |
| [`lua/semantic_layer/compiler/grain_sql.lua`](../lua/semantic_layer/compiler/grain_sql.lua) | Decision-free SQL rendering |
| [`lua/semantic_layer/compiler/materializations.lua`](../lua/semantic_layer/compiler/materializations.lua) | Safe materialization matching and rejection provenance |
| [`lua/semantic_layer/compiler/request_json.lua`](../lua/semantic_layer/compiler/request_json.lua) | Public compile orchestration, caching, and logging |
| [`lua/semantic_layer/agent/runtime.lua`](../lua/semantic_layer/agent/runtime.lua) | Agent discovery helpers, explanation, feedback, and evolution workflow |
| [`tools/package_lua_scripts.py`](../tools/package_lua_scripts.py) | Packaging canonical Lua into install SQL |

Install SQL is ordered because later surfaces depend on earlier schemas, tables,
views, and scripts. The source Lua files are the maintainable implementation; the
packaged install files are deployment artifacts and must remain synchronized.

## Extension Boundaries

The architecture leaves clear seams for future capability without implying that
those capabilities already exist:

- Representation selection is deterministic policy, not runtime cost- or
  freshness-based optimization.
- Temporal partitioning supports metric leaves, not arbitrary joined dimensions.
- Reconciled facts are blocked because their grain-preservation proof is not yet
  implemented.
- Semantic identity is scalar; composite identity and general mapped
  relationship remapping are not supported.
- Identity matching is exact and declared. Probabilistic record linkage belongs
  upstream of certification.
- Result sets are relational and flat. Nested JSON results can be constructed by
  a downstream projection layer such as Exasol JSON Tables.
- Physical sources may be local relations or Virtual Schema relations, but this
  repository does not implement a general-purpose Virtual Schema adapter.

These limits follow the same design rule as the implemented features: introduce a
new semantic behavior only when it can be represented in the catalog, validated
independently, planned deterministically, and explained after compilation.

## Related Documentation

- [Semantic compiler](semantic-compiler.md) describes request compilation and
  multi-fact planning in more detail.
- [Semantic catalog](semantic-catalog.md) documents catalog objects and supported
  administration surfaces.
- [Runtime testing](runtime-testing.md) explains database-backed verification.
- [ADR 001](architecture-decisions/001-grain-aware-result-semantics.md) defines
  the grain-aware result contract.
