# Architecture

This document is the implementation-facing architecture stub for the Exasol
Semantic Views project.

The full design is described in:

- [Design rationale](../plans/semantic_layer_design_rationale.md)
- [Implementation spec](../plans/semantic_layer_codex_spec.md)
- [Implementation plan](../plans/semantic_layer_implementation_plan.md)

## Layers

1. `SYS_SEMANTIC`: database-resident semantic catalog.
2. `SEMANTIC_ADMIN`: Lua admin, validation, compile, publish, and feedback
   scripts.
3. `SEMANTIC_CATALOG`: read-only human/tool metadata views.
4. Published semantic schemas such as `SEMANTIC_SALES`: BI-compatible guarded
   metadata views.
5. Lua SQL preprocessor: metric-column SQL rewrite for BI and human SQL users.
6. Lua semantic compiler: shared compiler core for agent requests and SQL.
7. `SEMANTIC_AGENT`: role-scoped machine-readable context views for agents.
8. Materialization registry: deterministic optimizer path after correctness is
   proven.
9. Optional Lua Virtual Schema adapter: later metadata/pushdown extension.

Grain-sensitive relationship traversal is implemented once in
`lua/semantic_layer/shared/grain_graph.lua` and packaged into both the validator
and compiler runtimes. See
[ADR 001](architecture-decisions/001-grain-aware-result-semantics.md) for the
result-domain and relationship-proof contract.

The compiler's Phase B boundary is split into four small modules:

- `query_spec.lua` canonicalizes both input languages
- `catalog_snapshot.lua` detaches the complete planner catalog
- `metric_plan.lua` builds the typed DAG and proof-rich logical plan
- `grain_sql.lua` renders supported single- and multi-branch physical plans

The legacy join proof remains the compatibility path. Strict grain proofs are
separate values and are the only proof type the multi-fact branch planner may
consume.

Phase C1 normalizes leaf fact inputs, binds filter scopes, and proves each leaf
branch to each required dimension before the legacy matrix or root join planner
runs. Phase C2 adds a separate typed physical planner and decision-free
multi-branch state renderer. Phase C3 finalizes states and derived metrics after
the merge, applies final query operations, and activates SQL generation and
caching through both compiler input lanes. Phase D1 identifies every branch's
base source explicitly and records planner runtime without making cached plans
nondeterministic. Phase D2 uses plan version 7 / physical-plan version 4 to
substitute at most one complete aggregate materialization per leaf without
changing the proven merge and finalization pipeline.

## Primary Flows

### Agent Request

```text
SEMANTIC_AGENT discovery views
  -> SEMANTIC_ADMIN.COMPILE_REQUEST_JSON
  -> generated Exasol SQL plus plan metadata
  -> client executes generated SQL under normal Exasol privileges
  -> optional SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK
```

### BI Or Human SQL

```text
SELECT ... FROM SEMANTIC_<MODEL>.<OBJECT>
  -> Lua SQL preprocessor
  -> semantic compiler
  -> generated Exasol SQL
  -> Exasol optimizer/executor
```

## Implemented State

Milestones 1 through 6 are implemented and Nano-verified. The runtime now has
catalog tables, admin scripts, validation, structured request compilation, SQL
compilation, guarded published views, a Lua SQL preprocessor, agent context
views, search/glossary/explanation scripts, verified-query registration, and a
governed feedback workflow. It also has a manual materialization registry with
shared compiler selection across agent, SQL, and preprocessor lanes. The
optional Virtual Schema adapter remains a later milestone.
