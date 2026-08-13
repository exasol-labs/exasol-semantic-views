# ADR 001: Grain-Aware Result Semantics

Status: accepted and implemented

Date: 2026-07-25

## Context

A semantic object may expose metrics whose leaf aggregates originate on
different fact entities. Joining those facts before aggregation can multiply
rows and change metric values. Choosing a common dimension table as a result
spine avoids some multiplication but changes the result domain: orphan facts
can disappear and dimension members without facts can appear.

The compiler therefore uses a semantic contract for every multi-fact SQL
strategy.

## Decision

Each leaf aggregate metric starts at its declared base entity and is aggregated
independently to the requested output dimensionality. Compatible aggregate
states are combined only after branch-local aggregation. Derived metrics are
evaluated after that merge.

The default result domain is the union of groups contributed by selected metric
branches. A dimension spine would be a separate, explicit operation and is not
implemented.

Three grains remain distinct:

- entity grain: the row identity declared by a structured primary or unique key;
- requested dimensionality: the exact ordered semantic dimensions selected by
  the caller;
- merge identity: internal keys needed to join or prove relationships without
  changing the displayed grouping.

The canonical entity-key representation is
`UNIQUE_KEYS` plus ordered `UNIQUE_KEY_COLUMNS`. `PRIMARY_KEY_EXPR` remains a
legacy convenience field and does not prove complex grain by itself.

A relationship can support a grain proof only when it has ordered structured
endpoint mappings and the cardinality-preserving endpoint matches a declared
unique key. `JOIN_CONDITION` remains the SQL-emission source but is not itself a
uniqueness proof.

Safe dimensional attribution may traverse:

- either direction of `ONE_TO_ONE`;
- `MANY_TO_ONE` from the many side to the one side;
- `ONE_TO_MANY` from the many side to the one side.

Ambiguous safe paths are rejected. `PATH_PRIORITY` makes legacy traversal
deterministic but cannot choose between semantic roles such as billing and
shipping customer.

## Filter and empty-state semantics

- Global dimension filters apply inside every contributing branch and must be
  reachable by the same safe relationship rules.
- Metric-local filters affect only their metric state.
- Final metric filters (`HAVING`) run after state merge and derived-metric
  finalization.
- Cross-branch cohort or semi-join filters are unsupported.
- A missing `COUNT` state finalizes to zero.
- A missing `SUM` state remains `NULL`.
- Grand totals use the same state merge without a grouping list.

## Supported and rejected query matrix

| Query shape | Initial decision | Reason |
| --- | --- | --- |
| One fact branch, existing supported metrics | Supported | Legacy behavior remains compatible. |
| Multiple branches with `SUM`/`COUNT` states | Supported | States are independently mergeable. |
| Dimension reachable from every branch through safe paths | Supported | Attribution is cardinality-preserving and conformed. |
| No selected dimensions | Supported | Each branch produces one state row. |
| Arithmetic or ratio over finalized branch metrics | Supported | Evaluation occurs after state merge. |
| Dimension reachable from only some branches | Rejected | It has no common meaning for the result. |
| Traversal from one side to many side | Rejected | It attributes one fact to multiple dimension rows. |
| Many-to-many traversal | Rejected | A fanout policy is not an allocation proof. |
| Missing structured relationship mapping | Rejected by grain planner | Opaque SQL cannot prove endpoint identity. |
| Mapping not backed by required unique key | Rejected | Declared cardinality is not structurally proven. |
| Multiple safe paths without role binding | Rejected | Path priority cannot resolve semantic role. |
| Cross-branch cohort filter | Rejected | It changes branch membership rather than row predicates. |
| Exact distinct across branches | Rejected | Scalar partial distinct counts are not mergeable. |
| Snapshot/semi-additive metric | Rejected | It requires time-aware rollup semantics. |
| Window metric | Rejected | It requires an explicit evaluation stage and grain. |
| Query-input CTE/subquery propagation | Rejected | Input grain is not modeled. |

## Compatibility

Existing models without structured relationship mappings continue to validate
with `SEMANTIC_MODEL_031` warnings and retain the legacy single-branch compiler
path. The grain-aware multi-fact path requires complete proofs and does not fall
back to raw joined aggregation after a failed proof.

Validator and compiler use the same packaged pure-Lua graph implementation.
Path order is deterministic, while multiple shortest semantic paths are
reported as ambiguity rather than silently selected.

## Consequences

The feature is intentionally narrower than general multi-fact SQL, but
its results are compositional: adding a metric branch cannot change the values
of existing branches. Later distinct, snapshot, cohort, allocation, and nested
query features can extend aggregate states and proof types without replacing
the result-domain contract.
