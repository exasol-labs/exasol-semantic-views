# Semantic Compiler

The compiler has four installed SQL-facing entrypoints:

1. `SEMANTIC_ADMIN.COMPILE_REQUEST_JSON`, for structured agent requests.
2. `SEMANTIC_ADMIN.COMPILE_SQL`, for SQL users, tests, and BI/debug workflows.
3. `SEMANTIC_ADMIN.COMPILE_SQL_DEBUG`, for opt-in SQL compile logging to
   `SYS_SEMANTIC.QUERY_LOG`.
4. `SEMANTIC_ADMIN.SUGGEST_GRAIN_METADATA`, a read-only migration assistant
   for simple legacy key expressions and equality joins.

The compile entrypoints reuse the same binding, validation, planning, materialization
selection, metric expansion, and SQL generation core in
`SEMANTIC_ADMIN.COMPILER_RUNTIME`, packaged from
`lua/semantic_layer/compiler/request_json.lua`. JSON and Semantic SQL both
lower to the same versioned `QuerySpec`. Planning consumes a detached,
model-versioned `CatalogSnapshot`, including transitive private metric
dependencies that are not exposed as query fields.

Phase B introduced the typed single-branch boundary. Phase C1 added
multi-branch validation, Phase C2 added the typed physical state pipeline, and
Phase D2 adds complete leaf-source substitution. Fusion Phase F1 adds static
primary-representation binding and provenance. `PLAN_JSON.plan_version` is
`8` and
`PLAN_JSON.logical_plan` records:

- `LEGACY_JOIN` or `STRICT_GRAIN` proof mode
- leaf entity ids and typed metric stages
- relationship ids, unique-key ids, and mapping ordinals used by proofs
- deterministic candidate paths and rejected-edge reasons

`proof_mode` defaults to `LEGACY_JOIN`. `STRICT_GRAIN` is available for
proof-boundary testing and requires column mappings, a matching unique key on
the cardinality-preserving endpoint, a safe traversal direction, and no
many-to-many edge. Expression identity returns
`EXPRESSION_KEY_PROOF_UNSUPPORTED`.

For metrics whose normalized aggregate states span multiple fact entities, C1:

- treats structured metric inputs as authoritative and uses dependency rows
  only as a legacy fallback
- separates fact inputs, aggregate-state producers, and scalar finalizers
- binds global, metric-local, and `HAVING` filters before rendering
- proves every fact branch to every selected or globally filtered dimension
- assigns stable branch, requirement, proof, key, and rejection identifiers
- binds one physical branch per leaf with deterministic dimensions, state
  columns, typed placeholders, joins, and predicate placement
- renders and size-checks an internal `UNION ALL` merged-state pipeline
- finalizes state metrics and dependency-ordered scalar metrics after merging
- applies final `HAVING`, ordering, and limit against finalized metric columns
- returns executable multi-branch SQL and participates in the compile cache
- records a deterministic `source` contract with `source_kind = BASE`,
  `MATERIALIZATION`, or `REPRESENTATION_PARTITION` for each physical branch
  under physical-plan version 6; partition sources include representation,
  coverage, and validity provenance

`PLAN_JSON.selected_representations` lists the active representation selected
for every entity used by the request. Without F2 attribute bindings, F1 selects
the representation marked `PRIMARY` and records
`selection_reason = STATIC_PRIMARY`. With F2 bindings, binding role and priority
rank candidates first, then `PRIMARY` breaks otherwise-equal candidates before
representation priority and ID. Selection does not inspect freshness or cost.

F3 treats an entity as partitioned when every active representation has a
coverage predicate and a certified half-open validity interval. A partitioned
metric leaf enters the typed aggregate-state path even when it is the request's
only fact entity. The physical planner creates one branch per complete
representation binding, adds that representation's coverage predicate, and
merges `SUM`/`COUNT` states after `UNION ALL`.
`PLAN_JSON.logical_plan.physical_plan.fusion_plan` records every partition.
Non-mergeable metrics fail with `METRIC_STATE_UNSUPPORTED`. Partitioned entities
used only as joined dimensions fail with
`FUSION_PARTITION_DIMENSION_UNSUPPORTED`.
The public `_070`/`_074` diagnostics retain the metric, aggregate, entity,
dimension or filter usage from the typed failure and state the supported F3
remedy. `_080` names the first missing attribute and partition and points to
`ADD_ATTRIBUTE_BINDING`.

F4 attribute policies run after complete F2 representation selection. `PREFER`
keeps the selected binding unchanged. `COALESCE` and `RECONCILE` emit
key-preserving joins to alternate representations and combine them in declared
authority order. A shared physical F1 key or complete F5 semantic identity
keeps each join key-preserving; validation rejects unsupported identity shapes
before compilation. For `MAPPED` F5 bindings, the compiler first resolves the
source-local expression through its certified two-column mapping relation and
joins on the resulting semantic key. The plan's selected-binding entries
include `fusion_strategy`, ordered `fusion_contributors`, and identity/binding/
mapping IDs, so source precedence and identity resolution remain explainable.
F4 bypasses aggregate materialization substitution and currently fails closed
for multi-fact branch plans rather than dropping reconciliation semantics.

F5.1 makes single-branch representation selection relationship-aware. Before
ranking candidates, the compiler resolves the safe relationship path and checks
each endpoint representation. A canonical physical endpoint remains unchanged.
If it is absent, the candidate is usable only when the endpoint mapping matches
a scalar unique key, the primary `DIRECT` identity binding is exactly that key,
and the candidate has a `DIRECT` identity binding. SQL rendering replaces only
that qualified endpoint reference. `relationship_identity_remaps` records the
relationship, side, representation, unique key, identity, and binding; rejected
candidates are recorded separately. Multi-fact branch planning remains outside
this first relationship-remapping increment.

The initial safeguards allow at most eight physical branches and at most
1,000,000 bytes of internally rendered SQL. Limit failures are reported in the
plan as `PLANNER_BRANCH_LIMIT_EXCEEDED` or
`PLANNER_SQL_SIZE_LIMIT_EXCEEDED`.

Planner runtime is stored in the existing `RUNTIME_MS` column for JSON agent
request logs and Semantic SQL debug query logs. Timing is deliberately excluded
from `PLAN_JSON`, so equivalent input lanes and cached results retain identical
plans. Cache hits record zero planner milliseconds.

An invalid strict proof returns `_074` with a path-specific `reason_code` and
blocking relationship. Physical binding, finalization, or safeguard failures
return `_075`. A successful multi-branch request returns the same `OK` envelope
as a single-branch request, including generated SQL and plan JSON.

Non-mergeable aggregate forms such as `COUNT DISTINCT` remain supported by the
legacy renderer for ordinary single-branch requests. They are rejected when an
explicit strict or multi-branch plan would require a mergeable state contract.

The initial state finalizers map missing `COUNT` state to zero with `COALESCE`.
Missing `SUM` state remains null. Derived arithmetic is emitted in ordered CTE
layers so every derived metric is computed once after state merging.

These entrypoints are Lua scripts. Call them with `EXECUTE SCRIPT`, not
`SELECT`:

```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('<request-json>');
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL('<semantic-sql>');
```

The explicit agent and SQL lanes are validation-gated:

- reuses the latest successful `VALIDATE_MODEL` run for the model's active
  version. Compiling does not re-run the validator: `PUBLISH_MODEL` (and the
  admin mutation workflows) own the writes to
  `VALIDATION_RUNS`, `METRIC_DEPENDENCIES`, and `METRIC_DIMENSION_MATRIX`.
  This eliminates the transaction collisions concurrent compile callers
  used to see, and roughly quarters the per-compile latency. A model that
  has never been validated returns `SEMANTIC_REQUEST_010`; run
  `EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL` or
  `SEMANTIC_ADMIN.PUBLISH_MODEL` first.
- rejects metric/dimension pairs through
  `SYS_SEMANTIC.METRIC_DIMENSION_MATRIX`
- reuses `SYS_SEMANTIC.METRIC_DEPENDENCIES` for dependency-aware planning
- returns a table-shaped response with status, error fields, generated SQL, plan
  JSON, clarification JSON, and validation run id
- records explicit agent compile calls in `SYS_SEMANTIC.AGENT_REQUEST_LOG`,
  with `CACHE_HIT` set to `TRUE` when the result came from the compile cache
- emits `SEMANTIC_REQUEST_100` / `SEMANTIC_QUERY_100` for transient
  transaction collisions after the runtime's own bounded retries are
  exhausted. These are safe to retry by the caller

### Compile cache

`SYS_SEMANTIC.COMPILE_CACHE` stores `GENERATED_SQL` + `PLAN_JSON` keyed by
`(MODEL_VERSION_ID, CACHE_KEY)`. `CACHE_KEY` is a 64-bit polynomial hash
(computed in Lua) of the canonical parsed request plus the logical-plan
version. The compiler is
deterministic per `(model_version_id, normalized request)`, so a cache hit
returns the stored result without re-running catalog load, matrix lookup,
join planning, materialization selection, or SQL emission.

Normalization rules for the cache key:

- top-level object keys are sorted, so JSON key order in the request does
  not affect the cache key
- `client`, `purpose`, and `natural_language_text` are stripped before
  hashing - they are logging metadata, not compile inputs
- arrays (`metrics`, `dimensions`, `filters`, `having`, `order_by`) keep
  the caller's order, since that order can affect the generated SQL

Invalidation: cache entries are dropped on any event that can change compile
output for a model version: `PUBLISH_MODEL`, `VALIDATE_MODEL` (and therefore
every admin DDL script that re-validates), `REGISTER_MATERIALIZATION`,
`ADD_MATERIALIZATION_COLUMN`, `SET_MATERIALIZATION_STATUS`,
`ADD_UNIQUE_KEY`, `ADD_UNIQUE_KEY_COLUMN`, and
`ADD_RELATIONSHIP_KEY_MAPPING`. Proof-metadata helpers also mark earlier
successful validation runs `STALE`, so compilation requires a new
`VALIDATE_MODEL` run after a key or mapping change. Cache writes
on miss are best-effort: a PK collision from a concurrent identical compile
is swallowed, since the caller already has the correct result. Only
`STATUS = OK` results are cached - errors and clarifications are never
stored, so a user fixing an invalid request and retrying is not blocked by
a stale cache row.

The structured compiler supports:

1. **A closed top-level request contract.** The accepted keys are `model`,
   `object`, `metrics`, `dimensions`, `filters`, `having`, `order_by`, `limit`,
   `client`, `purpose`, `natural_language_text`, and `proof_mode`. Any other
   key returns `SEMANTIC_REQUEST_004` with the unknown and allowed keys rather
   than silently changing the request's meaning.
2. **Dimension-only discovery requests.** A request with `dimensions` set
   and `metrics` empty compiles to `SELECT dim1, dim2, ... FROM <root>
   [JOIN ...] [WHERE filters] GROUP BY dim1, dim2, ...`. This is the
   intended shape for populating facet filters or any other distinct-values
   discovery flow. `HAVING` requires a metric (returns
   `SEMANTIC_REQUEST_026` if supplied alongside zero metrics) and
   aggregate materializations are skipped, since they exist to serve
   aggregations.
3. Metrics and dimensions by canonical names or visible synonyms.
4. Dimension filters with `=`, `!=`, `<>`, `<`, `<=`, `>`, `>=`, `LIKE`,
   `IN`, `BETWEEN`, `IS NULL`, and `IS NOT NULL`. Text `=`, `!=`, `<>`, `LIKE`,
   and `IN` filters compile case-insensitively. Null predicates are unary and
   omit `value` and `value_sql`. Structured request filters accept `field`,
   `dimension`, `column`, or `name` for the field key, and `op` or `operator`
   for the operator key.
5. `ORDER BY` over selected output fields.
6. `LIMIT` up to the configured maximum.
7. Additive metrics, filtered metrics using `CASE`, and derived metrics as
   arithmetic over expanded aggregate expressions.
8. Relationship planning from the semantic object root to required entities.
9. Optional materialized aggregate selection when registered catalog metadata
   fully covers the selected metrics, selected dimensions, filter dimensions,
   and rollup policy requirements.
10. Stable structured errors for malformed JSON, unknown fields, invalid limits,
   invalid metric/dimension pairs, and missing relationship paths.

The typed planner explicitly rejects distinct, non-additive, and window
aggregate states until their state and finalization contracts are implemented.
This prevents the legacy expression renderer from accidentally giving an
advanced metric unsupported semantics.

### Optional hierarchical JSON output

The compiler deliberately returns flat relational SQL. For JSON-format nested
results, an integration can compile and execute one or more governed semantic
queries at the required grains, materialize those result sets with stable
parent keys, and pass them to
[Exasol JSON Tables structured results](https://github.com/exasol-labs/exasol-json-tables/blob/main/docs/structured-results.md).
Its `structured_shape` contract describes root, object, and array branches; the
wrapped result can then be emitted recursively with `TO_JSON(*)`. This is an
optional post-processing layer, not part of `COMPILE_REQUEST_JSON`, and
`TO_JSON` over an ordinary unwrapped result remains flat. The approach is
analogous to [Malloy nested views](https://docs.malloydata.dev/documentation/language/nesting),
which attach per-row subtables to a query result.

Materialization selection is an optimization below both `COMPILE_REQUEST_JSON`
and `COMPILE_SQL`. The compiler validates the semantic request first, then
selects an active same-version aggregate materialization only when every
selected or filtered dimension and every selected metric is mapped. Unsafe
rollups, missing columns, unsupported freshness policies, inactive
materializations, and non-additive rollup attempts fall back to base-source SQL.
The selected materialization and rejected-candidate diagnostics are recorded in
`PLAN_JSON`; SQL debug logging also stores the selected name in
`SYS_SEMANTIC.QUERY_LOG.MATERIALIZATION_USED`.

For a multi-branch plan, selection happens independently per proven leaf but is
atomic within that leaf. A candidate must contain every selected or globally
filtered dimension and every unfiltered aggregate-state producer owned by the
branch. Its state-column rollup policy must match the state's merge operator;
the initial `SUM` and `COUNT` states both require `SUM`. Eligible candidates are
ranked by least excess dimensionality and stable materialization ID. Private
producer metrics are valid mappings, while derived/finalized-only or partial
candidates cannot satisfy a branch. Metric-local filtered materializations wait
for an explicit semantic filter-identity contract and currently cause
whole-leaf base fallback. Branch decisions and rejection reasons are exposed in
`materialization_decision` and each physical branch's `source`; all selected
names are also listed in `selected_materializations`.

`COMPILE_SQL` parses a deliberately small semantic SQL subset and translates it
into the same request shape before invoking the shared compiler core. Its errors
use the `SEMANTIC_QUERY_*` namespace. It supports semantic `SELECT *`
expansion; optional `GROUP BY` inference from selected dimensions; `GROUP BY ALL`;
`HAVING` metric predicates; metric predicates in `WHERE` auto-routed to `HAVING`;
`BETWEEN`; and SQL expressions on the right side of dimension predicates, such
as `order_month = ADD_MONTHS(TRUNC(CURRENT_DATE, 'MM'), -1)`. `ORDER BY` can
refer to selected semantic fields, output aliases, or ordinals. For Databricks
compatibility, `MEASURE(metric)` and `agg(metric)` wrappers are accepted in
`SELECT`, `HAVING`, and `ORDER BY`.

`COMPILE_SQL_DEBUG` has the same compile behavior as `COMPILE_SQL`, but records
the original SQL, generated SQL, plan JSON, requested dimensions, requested
metrics, status, and error fields in `SYS_SEMANTIC.QUERY_LOG`. This is
intentionally separate from the preprocessor path.

The preprocessor lane calls `compile_sql_for_preprocessor` inside the runtime.
That lane:

1. Returns non-semantic SQL unchanged.
2. Parses only a supported top-level semantic `SELECT`.
3. Uses the latest successful validation run instead of running validation per
   query.
4. Avoids hot-path DML logging.
5. Fails closed if validation is missing or stale.
6. Uses the same materialization decision path as explicit agent and SQL
   compilation.

### Published Authoring Availability

The current catalog has one mutable `ACTIVE_VERSION_ID` per model. Although
`MODEL_VERSIONS` and publish history record version metadata, publication does
not create an immutable catalog snapshot or a separate draft. Admin authoring
therefore edits the same version used by the published preprocessor surface.
Any operation that leaves validation stale makes that surface return
`SEMANTIC_QUERY_010` until the active version validates successfully again.
Published `SET_REPRESENTATION_COVERAGE` changes are prospective and atomic: an
invalid candidate is restored and revalidated before the script returns
`SEMANTIC_ADMIN_059`, so it does not decertify the existing surface.

This fail-closed behavior is intentional: reusing an earlier successful
validation would certify newly mutated catalog rows that were never validated.
It is not draft isolation. Perform multi-step F2/F3/F4/F5 changes in a maintenance
window, validate immediately after the final step, and do not promise continuous
published availability while editing. True zero-downtime authoring requires
copy-on-write draft versions plus an atomic publish pointer switch; version
metadata alone is insufficient.

Compilation accepts the latest completed validation run with zero errors.
Warnings, including legacy relationships that do not yet have structured key
mappings, do not block the existing single-branch compiler path.

`tools/package_lua_scripts.py` embeds the compiler runtime, materialization
runtime, and wrappers into `sql/install/003_create_semantic_admin_scripts.sql`.
The embedded compiler runtime includes `query_spec.lua`,
`catalog_snapshot.lua`, `metric_plan.lua`, and `grain_sql.lua` before the
entrypoint module.
