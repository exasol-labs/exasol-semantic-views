# Changelog

All notable changes to Exasol Semantic Views are documented here.

---

## [Unreleased]

### Added

#### `ADD OR REPLACE FACT`

- Semantic SQL had `ADD OR REPLACE METRIC` but no fact equivalent, so adding
  one fact meant restating every fact in the object through `REPLACE FACTS`.
  Facts are the primitive metrics compose from, which made it the wrong
  operation to omit.
- `ALTER SEMANTIC VIEW <model>.<object> ADD OR REPLACE FACT <name> ON ENTITY
  <entity> AS <expr> RETURNS <type> ...` now upserts one fact and leaves the
  object's other facts in place.
- Fixed while validating: a statement carrying only `REPLACE FACTS` was
  rejected with `SEMANTIC_DDL_012` — whose message listed `REPLACE FACTS` as an
  accepted form. Fact-only statements now parse.
- The two single forms each consume the rest of the statement, so combining
  them with each other or with a `REPLACE` block is refused explicitly
  (`SEMANTIC_DDL_037`) instead of silently absorbing the tail.
- Fact *removal* still has no DDL form; that waits until dependent-metric
  rewrites are transactional, and the docs now say so where the forms are
  listed.

#### Build provenance in the catalog

- The database recorded nothing about the product build serving it: the only
  version-ish catalog objects described semantic model versions, and
  `install.py` never mentioned a version at all. Diagnosing "identical
  catalogs, different behaviour" meant comparing schemas by hand and guessing
  from install timestamps.
- `tools/install.py` now records one row per run in
  `SYS_SEMANTIC.PRODUCT_INSTALLATIONS`: version from `CHANGELOG.md`, release
  state (`RELEASED`/`DEVELOPMENT`), git commit and clean/dirty state, a
  SHA-256 over the install SQL as executed, and who installed it when.
- `SEMANTIC_CATALOG.PRODUCT_VERSION` answers "which build is this?" in one
  query, with `DISPLAY_VERSION` folding in the release state (`0.1+dev`).
  `SEMANTIC_CATALOG.PRODUCT_INSTALL_HISTORY` keeps every install recorded
  against the database, so a runtime upgrade stays visible afterwards.
- The installer prints the same line on completion.
- `RUNTIME_CHECKSUM` is the discriminator that survives a tarball, a vendored
  copy, or uncommitted edits, where git provenance does not. `verify_milestone1`
  asserts the recorded checksum matches the install SQL on disk.

#### `SET_RELATIONSHIP`

- Relationships were add-only. Re-adding was refused as a duplicate
  (`SEMANTIC_ADMIN_016`) and removing was refused while key mappings existed
  (`SEMANTIC_ADMIN_066`), so correcting a cardinality or a fanout policy meant
  a four-step sequence: remove the mappings in descending ordinal order, remove
  the relationship, add it back, re-add the mappings. That is the operation the
  fan-out reason codes push modelers toward.
- `SEMANTIC_ADMIN.SET_RELATIONSHIP(MODEL_NAME, RELATIONSHIP_NAME,
  JOIN_CONDITION, CARDINALITY, JOIN_TYPE, FANOUT_POLICY)` edits one
  relationship in place. Any argument left `NULL` keeps its stored value,
  `FANOUT_POLICY = 'NONE'` clears the column, and key mappings survive the
  edit.
- Endpoints are deliberately not editable: changing them makes it a different
  relationship whose key mappings no longer describe it.
- On a PUBLISHED model the change validates prospectively and is restored on
  error (`SEMANTIC_ADMIN_098`), matching `REMOVE_RELATIONSHIP`'s
  `SEMANTIC_ADMIN_094`. On a draft the change applies and validation runs go
  stale; compilation is gated on validation status, so nothing can query the
  model until it is revalidated.
- Regression: `tools/verify_set_relationship.py`, in the smoke suite.

### Fixed

#### The installer claimed a publish it never performed

- `install.py --example` printed "Sales model published at
  SEMANTIC_SALES.SALES" while leaving the model `DRAFT`. Loading a model does
  not create its published schema — `PUBLISH_MODEL` does — so `SEMANTIC_SALES`
  did not exist at all, and a BI client reading JDBC/ODBC metadata found
  nothing. Semantic SQL worked anyway, because the preprocessor rewrites from
  the catalog rather than from the view, which is what made the missing publish
  easy to miss.
- The summary now says what actually happened: `loaded (DRAFT — no published
  schema yet)` with the one command to publish, or `published at
  SEMANTIC_SALES.SALES (typed views, BI-discoverable)`.
- New `--publish` flag (implies `--example`) validates and publishes the demo,
  so a BI-discoverable install is one command:
  `python3 tools/install.py --example --publish`.
- Left opt-in rather than publishing the demo by default: a published model is
  a governed contract, where authoring requires compound declarations and every
  candidate state is validated prospectively. That is correct for production and
  friction for a model people poke at while learning — including this repo's own
  validation suite, which works by deliberately breaking the demo model.
- README gains a **What BI Tools See** section: discovery through
  `EXA_ALL_COLUMNS` is adapter-free once published, the governance layer lives
  in `SEMANTIC_CATALOG`/`SEMANTIC_AGENT` rather than in JDBC metadata, and
  querying still needs a session that can activate the preprocessor. The
  headline claim now says so instead of "BI tools can discover typed views".

#### `FANOUT_POLICY` was undocumented free text

- The column accepted any string (`'banana'` was stored verbatim and validated
  clean). It is now a closed set — `REFERENCE_ONLY`, `DEDUPLICATE`, `ALLOCATE`
  — matched case-insensitively and stored upper-case.
- `ADD_RELATIONSHIP` refuses an unrecognized value on write with
  `SEMANTIC_ADMIN_003`, the same way it already refused an unrecognized
  cardinality or join type. Semantic DDL and OSI import write through that
  script, so they inherit the check; importing a legacy model whose policy is
  outside the set now fails loudly there.
- New `SEMANTIC_MODEL_053` (**warning**, not error, so stored models keep
  validating) fires for a value that predates the write-path check, and for a
  policy declared on a cardinality where it has no meaning.
- Documented in `docs/validation-rules.md#fanout-policy`: what the column is,
  how to set it, what each value means, and that **no value authorizes
  traversal** — the values record intent for a technique a planner may one day
  prove. `docs/creating-metrics.md` no longer tells readers to "check the
  fanout policy" when a metric/dimension pair is rejected.

#### Fan-out refusals named a remedy that does not exist

- The reverse of a `MANY_TO_ONE` (and the forward direction of a
  `ONE_TO_MANY`) was reported as `FANOUT_REQUIRES_POLICY`, but
  `FANOUT_POLICY` was never consulted for those directions: declaring one
  changed nothing, so the message sent modelers after a remedy that could not
  work. Verified against a `MANY_TO_ONE` carrying `FANOUT_POLICY = 'ALLOCATE'`,
  which was still refused with the same "requires policy" reason.
- Those edges now report `ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED`, the code the
  strict lane already used for the identical situation, so both lanes share one
  vocabulary and no reason code names a remedy. With many-to-many traversal
  also refused, no reason code implies a policy would help — because none
  would.
- `SEMANTIC_MODEL_030` now states the remedy that does exist for a fanning
  pair: expose the metric only alongside dimensions reachable from its base
  entity without fan-out, or drop one of the two from the object.
- Callers reading `REASON_CODE` from `METRIC_DIMENSION_MATRIX` or
  `VALID_COMBINATIONS_FOR_AGENT` see the new value; there is no compatibility
  alias, since the old one was actively misleading.

#### Many-to-many traversal silently double counted

- A `MANY_TO_MANY` relationship with any non-empty `FANOUT_POLICY` was treated
  as a safe edge by the legacy join lane and compiled to a flat join with no
  de-duplication, so a measure whose row matched several partners was counted
  once per partner. `plans/architecture-decisions/001-grain-aware-result-semantics.md`
  had always specified the opposite ("a fanout policy is not an allocation
  proof"), and `STRICT_GRAIN` already refused it.
- The shared grain graph now marks many-to-many edges unsafe in both
  directions with reason `MANY_TO_MANY_UNSUPPORTED`, so validation rejects a
  visible metric/dimension pair that needs one (`SEMANTIC_MODEL_030`) and the
  compiler refuses the request (`SEMANTIC_REQUEST_042`).
- `SEMANTIC_REQUEST_042` now names the blocking relationship and reason instead
  of only reporting that no safe path exists. Path rejection text moved from
  the validator into the shared graph so both runtimes phrase it identically.
- A declared `FANOUT_POLICY` still satisfies `SEMANTIC_MODEL_010`; the rule
  message now says a policy declares intent and does not authorize traversal.
- Regression: `tools/verify_many_to_many_refusal.py`, in the smoke suite.
- **Upgrade note:** a model that relied on many-to-many traversal changes from
  returning inflated numbers to failing validation on its next `VALIDATE_MODEL`
  (`SEMANTIC_MODEL_030`), which gates every compile for that model. Remove the
  offending metric or dimension from the object, or root a separate semantic
  object on the other side of the bridge.

### Changed

#### The sales demo model is multi-grain, so fan-out protection is demonstrable

- `MART.ORDERS` gained `FREIGHT_AMOUNT` and `SHIP_MODE`; `MART.CUSTOMERS` gained
  `SEGMENT`.
- A second semantic object, `ORDER_HEADER` (rooted at `order`), exposes
  `total_freight` over `ship_mode` and `customer_segment`. Every fact in the
  previous demo sat at the `order_line` leaf and every relationship pointed
  outward from it, so fan-out was structurally impossible and the model's
  central safety property could not be observed from the shipped example.
- `tools/verify_fanout_guardrails.py` walks through and asserts the guarantee:
  safe traversals match hand-written SQL, the same order-grain metric is
  refused in the line-grain `SALES` object with `SEMANTIC_MODEL_030` /
  `ONE_TO_MANY_ATTRIBUTION_UNSUPPORTED` and a rolled-back catalog, and the
  overstated number the refusal prevents is printed. It runs as part of
  `tools/run_smoke.sh`.

## [0.1] - 2026-08-19

### Added

#### Fusion Phase F3: temporal partition unions

- Representations can declare certified coverage predicates and half-open
  validity intervals through `SET_REPRESENTATION_COVERAGE`.
- The compiler expands partitioned metric leaves into representation-specific
  aggregate-state branches, combines them with `UNION ALL`, and records source,
  coverage, validity, and binding provenance in `PLAN_JSON`.
- Validation requires complete, contiguous, non-overlapping, open-ended
  coverage and proves key uniqueness per partition without requiring disjoint
  partitions to contain identical key sets.
- F3 supports mergeable `SUM` and `COUNT` states. Partitioned joined dimensions
  and materialization substitution remain fail-closed for later phases.

### Fixed

#### Unusable F3 partition declarations

- Once a model has active metrics, `VALIDATE_MODEL` now rejects coverage on an
  entity that is the base of none of them, because F3 cannot fuse an entity used
  only as a joined dimension. Empty-model authoring remains repairable while
  its first metric is created.
- `SEMANTIC_MODEL_043` names the entity and blocks publication before existing
  dimension queries can regress to `SEMANTIC_QUERY_074`.

#### F3 fail-closed diagnostics

- F3 typed-planning errors now name the unsupported metric and aggregate, the
  partitioned entity, or the joined dimension/filter that caused refusal.
- Incomplete partition bindings now name the missing attribute and partition
  and prescribe `ADD_ATTRIBUTE_BINDING` instead of reporting only the entity.

#### F3 coverage predicate certification

- `VALIDATE_MODEL` now requires every F3 runtime predicate to exactly encode
  its declared half-open validity interval over one qualified temporal column.
- Mismatched, overlapping, gapped, or free-form predicates fail
  `SEMANTIC_MODEL_042` before publication instead of invalidating the interval
  proof and silently changing `UNION ALL` results.

#### Multi-representation probe timeout

- `VALIDATE_MODEL` now refuses every multi-representation F1/F3 key probe unless
  the caller configured session `QUERY_TIMEOUT` between 1 and 60 seconds.
- The guard no longer classifies source schemas, so declared `RELATION` sources,
  normalization views over Virtual Schemas, and deeper dependency chains cannot
  bypass it.
- The bounded timeout applies to the complete Exasol script, turning an
  intermittently stuck federated probe into a database timeout instead of an
  unbounded validation session.

#### Primary representation selection

- F2 complete-candidate ranking now prefers the representation currently marked
  `PRIMARY` before representation priority and ID, so promotion is effective
  when retained defaults and explicit bindings otherwise rank equally.
- Binding role and binding priority remain authoritative ahead of the primary
  tie-breaker, preserving intentional attribute fallback.

#### Remote representation validation cost

- `VALIDATE_MODEL` now defers F1 source probes until local catalog validation is
  clean, so invalid authoring states do not scan federated representations.
- Each representation's distinct-key cardinality is probed once per declared
  key instead of rescanning the primary for every alternate; exact
  bidirectional key-set proofs remain unchanged.

#### Attribute-binding repair ordering

- `ADD_ATTRIBUTE_BINDING` now compares validation before and after the
  candidate mutation, allowing bindings to repair multi-column representation
  mismatches sequentially while still rolling back newly introduced errors.
- Intermediate representation errors continue to block publication until all
  required bindings are present and validation succeeds.

#### Representation identity scope diagnostics

- The modeler workflow now requires exact preflight checks for physical key and
  join-column names before registering an alternate representation.
- Identity-related validation errors now explain that F2 binds dimensions and
  facts only, recommend a canonicalizing source view, and identify native
  representation identity binding as a Phase F5 capability.

#### Representation promotion binding safety

- `SET_PRIMARY_REPRESENTATION` no longer moves a compatibility default onto an
  incoming representation that already has an explicit binding for the same
  attribute.
- Promotion detects and repairs stale default/explicit collisions created by
  older F2 installs before enforcing the clean-validation gate, restoring a
  supported rollback route for affected models.

#### Unary null predicates

- Structured filters and `having`, plus Semantic SQL `WHERE` and `HAVING`, now
  support unary `IS NULL` and `IS NOT NULL` predicates without a value.
- The machine-readable agent contract now exposes explicit entries for both
  operators, matching the runtime compiler.

#### Strict structured-request keys

- `COMPILE_REQUEST_JSON` now rejects unknown top-level keys with
  `SEMANTIC_REQUEST_004` instead of silently dropping them during `QuerySpec`
  normalization.
- `COMPILE_REQUEST_SCHEMA_FOR_AGENT` exposes all 12 accepted top-level keys so
  autonomous callers can validate capability assumptions before compiling.
- Regression coverage includes nested-output requests, deterministic unknown-key
  diagnostics, request logging, and the live database contract.

### Added

#### Semantic fusion Phase F2

- Dimensions and facts now support representation-specific expressions through
  governed `ATTRIBUTE_BINDINGS` with deterministic `PREFER` and `FALLBACK`
  source selection.
- The compiler selects one complete representation per entity, records binding
  provenance in plan version 9, and fails with `SEMANTIC_REQUEST_080` rather
  than combining partial sources.
- Legacy attributes receive compatibility-default bindings automatically;
  primary representation promotion moves only those defaults and leaves
  explicit F2 bindings unchanged.
- Added binding lifecycle scripts, catalog visibility, validation rules
  `SEMANTIC_MODEL_039`/`040`, cache invalidation, rollback coverage, and
  modeler-skill guidance.

#### Official Exasol MCP Server integration

- Added a user and autonomous-agent workflow for discovering, activating, and
  verifying `SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR` through the official MCP
  server before executing governed semantic SQL.
- Documented server settings, reconnect behavior, view-discovery fallbacks, and
  the requirement to put `LIMIT` in semantic SQL instead of using MCP
  `row_limit`.
- Published MCP guidance with each semantic model and updated the semantic
  analyst skill to distinguish the direct MCP path from the optional structured
  semantic adapter.

#### Grain-aware aggregation Phase D2

- Plan version 7 / physical-plan version 4 can replace one complete proven
  multi-fact leaf with an aggregate materialization while leaving other leaves
  on their base sources.
- Branch candidates must provide every required dimension and mergeable state
  with a matching `SUM` rollup policy. Selection prefers the least excess
  dimensionality and then the stable materialization ID.
- Private aggregate-state producers are eligible without becoming public
  object columns. Partial, filtered-state, finalized-only, inactive, and unsafe
  candidates produce deterministic diagnostics and whole-leaf base fallback.
- The maintained live lane compares all-base, hybrid, and fully materialized
  results, including sparse states, ratios, filters, `HAVING`, grand totals,
  cache determinism, and metamorphic branch isolation.

#### Grain-aware aggregation Phase D1

- Multi-branch physical plans now identify every branch's physical source as a
  deterministic base-source contract and expose measured branch-count and SQL
  size safeguards under plan version 6 / physical-plan version 3.
- Successful compiler calls record planner runtime in the existing
  `AGENT_REQUEST_LOG.RUNTIME_MS` and `QUERY_LOG.RUNTIME_MS` fields without
  putting nondeterministic timing into cached plan JSON.
- The maintained live multi-fact lane now covers differential and metamorphic
  correctness before materialized branch substitution is introduced.
- Leaf-local metric predicates no longer create a false conformance proof
  requirement, while legacy single-branch non-mergeable aggregates retain
  their compatibility renderer and strict or multi-branch plans reject them.

#### Grain-aware aggregation Phase C3

- Plan-version 5 multi-fact requests now finalize mergeable states after the
  cross-branch rollup, compute derived metrics in dependency-ordered CTEs, and
  return executable SQL through both structured JSON and Semantic SQL.
- Final `COUNT` states use zero for groups supplied only by another branch;
  `SUM` states retain SQL nullability. `HAVING`, output ordering, and limits are
  applied only after scalar finalization.
- Successful multi-branch compiles now use the normal versioned compile cache.
  Existing single-branch SQL continues to use the legacy-compatible renderer.
- Private metrics now remain hidden in semantic-object column metadata. They can
  therefore serve as transitive state dependencies without expanding the
  object's public compatibility surface.

#### Grain-aware aggregation Phase C2

- Plan-version 4 multi-fact requests now include a typed
  `PhysicalMultiBranchPlan` with one base-source branch per leaf entity,
  deterministic state columns, conditional metric-local aggregates, proven
  joins, typed sparse-state placeholders, and a `UNION ALL` merged-state
  pipeline.
- The multi-branch renderer is protected by fixed branch-count and
  generated-SQL-size safeguards.
- Physical binding failures return `_075` with a stable plan-level reason.

#### Grain-aware aggregation Phase C1

- Multi-fact additive requests lower to a `MULTI_BRANCH`
  logical plan with normalized fact/state/finalizer nodes, bound filter scopes,
  strict branch-to-dimension proofs, and stable requirement/proof/rejection
  identifiers. C1 initially kept valid plans behind `_073`; path-specific proof
  failures return `_074`.
- Single-branch SQL generation remains on the existing renderer.

#### Databricks Unity Catalog Metric View compatibility

- **Databricks UCMV import** — added
  `SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW`, which translates a supported
  Databricks metric-view YAML subset into native semantic catalog metadata and
  can optionally apply, validate, and publish the model. Unsupported constructs
  return `DBX_IMPORT_*` diagnostics.
- **Databricks SQL surface compatibility** — semantic SQL now accepts
  `MEASURE(metric)`, the `agg(metric)` synonym, and `GROUP BY ALL` against
  published semantic objects. The wrappers are supported in `SELECT`, `HAVING`,
  and `ORDER BY`; `MEASURE()` of a dimension returns `SEMANTIC_QUERY_006`.
- `tools/import_databricks.py`, `tools/verify_databricks_import.py`,
  `tools/verify_databricks_sql_compat.py`, and
  `sql/examples/sales_databricks_metric_view.yaml` cover host-side file import,
  end-to-end import verification, SQL-surface verification, and a runnable demo
  fixture.

#### Semantic SQL: optional GROUP BY

- **GROUP BY is now optional** — a semantic SQL query that selects dimensions without a `GROUP BY` clause (e.g. `SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES`) now compiles by inferring `GROUP BY` from the selected dimensions, instead of returning `SEMANTIC_QUERY_007`. The emitted SQL is identical to the explicit-`GROUP BY` form (`build_sql` already builds `GROUP BY` from the selected dimensions). When a `GROUP BY` *is* supplied it must still exactly cover the selected dimensions, otherwise `SEMANTIC_QUERY_008` is returned. `SELECT *` and metric-only queries are unaffected. Backward-compatible: previously valid queries still compile unchanged.
- `tools/verify_group_by_inference.py` — focused integration test covering inference, inferred-equals-explicit results, multi-dimension inference, rejection of a non-covering `GROUP BY`, and composition with WHERE/ORDER BY/LIMIT.

#### Semantic SQL: Phase 2 subset improvements

- **HAVING clause** — `HAVING total_revenue > 1000`, `HAVING total_revenue BETWEEN 100 AND 1600`, and multi-predicate `HAVING p1 AND p2` forms are now accepted in semantic SQL. The HAVING clause enforces metric-only predicates; dimension fields in HAVING return `SEMANTIC_QUERY_040`. BETWEEN in HAVING reuses the same `after_between` flag logic as WHERE.
- **`WHERE metric > N` auto-routing** — metric predicates written in the WHERE clause (e.g. `WHERE total_revenue > 0`) are silently routed to HAVING at parse time. Dimension predicates remain in WHERE. Mixed `WHERE dim_filter AND metric_filter` clauses are split correctly.
- **`having` key in `COMPILE_REQUEST_JSON`** — the structured request model now accepts an optional `having` array with the same filter-object shape as `filters`. Each entry must reference a metric field. `COMPILE_REQUEST_SCHEMA_FOR_AGENT` documents the new key.
- **Materialization bypass** — queries with any HAVING predicate skip materialization selection and always use the full physical SQL path (required because materialized column names cannot be referenced in HAVING expressions).
- `tools/verify_semantic_sql_phase2.py` — 93-assertion integration test script covering HAVING, auto-routing, `COMPILE_REQUEST_JSON having`, materialization bypass, preprocessor path, and Phase 1+2 regressions.

#### Semantic SQL: Phase 1 subset improvements

- **ORDER BY ordinals** — `ORDER BY 1 DESC`, `ORDER BY 2, 1 ASC`, and mixed ordinal/name forms are now accepted in semantic SQL. Resolves ordinals against the SELECT list exactly as GROUP BY already did. Out-of-range ordinals return `SEMANTIC_QUERY_060`.
- **BETWEEN in WHERE** — `WHERE order_month BETWEEN '2026-01-01' AND '2026-03-31'` now compiles correctly. The AND-splitting loop in `parse_where_filters` uses an `after_between` flag to distinguish the BETWEEN value separator from a conjunction boundary. Works in any position within a multi-predicate WHERE clause including between other AND-joined predicates. New error codes: `SEMANTIC_QUERY_034` (missing AND separator), `SEMANTIC_QUERY_035` (non-literal values).
- `tools/verify_semantic_sql_phase1.py` — 67-assertion integration test script covering both new features and full regressions.

### Changed

- Databricks UCMV nested join path resolution now registers both absolute and
  relative snowflake paths and binds expressions to the deepest matching join
  entity, so fields such as `customer.nation.n_name` resolve to the nested
  `nation` entity instead of the parent join.
- `lua/semantic_layer/compiler/request_json.lua` — `parse_semantic_sql` no longer requires a `GROUP BY` clause when dimensions are selected; the `GROUP BY` coverage validation now runs only when a `GROUP BY` is supplied (`SEMANTIC_QUERY_007` removed). `tools/verify_milestone4.py` updated to assert the inferred-GROUP BY query now succeeds.
- `lua/semantic_layer/compiler/request_json.lua` — `find_top_level_clauses`, `clause_end`, `build_sql`, `compile_request_table`, and `parse_semantic_sql` updated for Phase 2; `parse_having_filters` added (~95 lines total). `parse_where_filters` and `parse_order_by` updated for Phase 1. Source file is the canonical implementation; `sql/install/003_create_semantic_admin_scripts.sql` is generated by `python3 tools/package_lua_scripts.py`.
- `sql/install/006_create_semantic_agent_views.sql` — `COMPILE_REQUEST_SCHEMA_FOR_AGENT` view updated with `HAVING_KEYS` documentation row.

### Removed

- `skills/exasol-semantic-views-agent/` — replaced by the two focused skills above.

---

## Notes on versioning

Version 0.1 is the first tagged release. Items above are tracked against the
development baseline established by the user-study simulations run on
2026-05-13. Phase 1 and Phase 2 are complete. The next planned milestone is
Phase 3 (subqueries/CTE rewriting and CAST in SELECT — deferred pending demand).
