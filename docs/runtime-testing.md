# Runtime Testing

Runtime verification is split into three lanes so failures are attributable and
fast feedback does not require a database.

## 1. Database-Free Lua Tests

```sh
sh tools/run_lua_tests.sh
```

This lane executes canonical Lua runtime sources directly. It covers:

- JSON parsing and encoding;
- canonical request normalization and cache-key stability;
- semantic SQL tokenization and expression helpers;
- validator expression inspection and graph-path behavior;
- semantic-definition and Databricks translation helpers;
- agent plan/JSON helpers;
- materialization eligibility, rejection, selection, and rollup decisions;
- deterministic property tests for request normalization.

All installed public Lua entry points are included as coverage roots, including
semantic-definition describe, explain, export, apply, import, and preprocessing
functions. The decision figure is deliberately reported as **named decision
outcome coverage**: it enforces both outcomes for explicitly registered
high-risk decisions, rather than claiming automatic coverage of every Lua
conditional.

It reports active-line coverage per runtime and named true/false decision
coverage. Enforced thresholds are in
`tests/lua/coverage_thresholds.lua`. Thresholds are intentionally independent:
high coverage of the smaller materialization runtime cannot conceal lower
compiler or validator coverage.

Lua 5.4 or newer is required. On macOS:

```sh
brew install lua
```

Set `LUA_BIN` when the interpreter is installed under another name.

## 2. Nano Integration Tests

```sh
sh tools/run_nano_smoke.sh
```

The smoke workflow starts with the database-free tests, packages the same Lua
sources into install SQL, performs a clean install, and exercises catalog DDL,
validation, compilation, preprocessing, execution, agent APIs,
materializations, Ossie/OSI, Databricks compatibility, compile caching, and
concurrent requests against Exasol.

It also runs the host-side OSI and SQL-splitter tests, the maintained SQL smoke
fixtures, the extended semantic-SQL phase suites, GROUP BY inference, and a
non-SYS security-principal test. The security test verifies model role
grant/revoke behavior, published discovery access, and denial of direct access
to the bundled physical source table.

The grain-aware compiler also has focused live verifiers for its stable
single-branch boundary and executable multi-branch finalization:

```sh
python3 tools/verify_grain_phase_b.py
python3 tools/verify_grain_phase_c3.py
python3 tools/verify_fusion_f3.py
python3 tools/verify_fusion_f4.py
python3 tools/verify_fusion_f5.py
python3 tools/verify_fusion_f51.py
python3 tools/verify_fusion_f7.py
python3 tools/verify_bug24_promotion_gate.py
python3 tools/verify_bug20_published_authoring_isolation.py
python3 tools/verify_bug25_published_mutation_protection.py
python3 tools/verify_bug26_published_f3_batch.py
python3 tools/verify_bug27_published_multistep_declarations.py
python3 tools/verify_bug28_composite_removal_and_recertification.py
```

The F3 verifier builds disjoint hot and cold representations, validates their
certified coverage, compiles the partitioned aggregate-state plan, and compares
the executed `UNION ALL` result with the expected cross-partition totals.
The F4 verifier proves null fallback with agreeing overlap, rejects conflicting
`COALESCE` values, and confirms `RECONCILE` authority in results and plan
provenance.
The F5 verifier uses different source-local customer keys, proves certified
mapping totality and bijection, executes mapped F4 reconciliation, and rejects
missing or many-to-one identity mappings. It then removes the mapping relation,
bindings, and semantic identity in dependency order and verifies catalog
cleanup.
The F5.1 verifier selects an alternate customer representation whose local key
needs a deterministic `DIRECT` cast, executes a relationship join with the
rewritten endpoint, and checks relationship-side provenance in the plan.
The BUG-25 verifier rejects invalid published representation, unique-key, and
attribute-binding mutations, checks restoration after each attempt, and proves
that the published query remains available. It also exercises unique-key
removal in dependency order.
The BUG-26 verifier starts from a published F1 model, demonstrates why the first
sequential F3 declaration is incomplete, then atomically applies the complete
coverage set and proves the published result remains stable.
The BUG-27 verifier registers a genuinely smaller hot partition together with
its complete F3 coverage, then adds a complete composite key to the same
published model without exposing either invalid intermediate state.
The BUG-28 verifier removes a complete key, tears F3 back down to one source,
checks immediate recertification across semantic-identity and binding add/remove
operations, and verifies stable malformed-coverage diagnostics.
The BUG-30 verifier proves that a complete identity and all representation
bindings can be added atomically to a published multi-representation entity,
while incomplete candidates leave no catalog or surface impact.
The BUG-31 verifier adds a representation whose physical key differs from the
published entity key together with its F5 binding, and proves candidate rollback
and continuous surface certification.
The F7 verifier proves proposal idempotency, human certification/rejection,
review auditability, and the absence of automatic catalog mutation.
The BUG-24 verifier rejects missing-column and expression-bound prospective
primaries before mutation, then reconstructs the historical trapped state and
proves recovery through a prior clean validation run marked `STALE`.
The BUG-20 verifier publishes an F3 surface, rejects invalid coverage with
rollback, and proves the published query returns the same result afterward.

The maintained D1/D2 verifier uses an isolated `grain_d1` model with three fact
branches. It compares JSON and Semantic SQL results with independently
aggregated reference SQL across all-base, hybrid, and fully materialized plans.
Coverage includes private state producers, complete-source fallback, rejected
filtered and finalized-only candidates, grand totals, global filters, `HAVING`,
equal labels, sparse branches, orphan/null keys, deterministic cache results,
and the rule that mutating one branch cannot alter another branch's state. It
also reports planner runtime and SQL size for one-, two-, and three-branch
shapes.

`tools/verify_concurrent_compile.py` enforces a configurable concurrency p95
limit. Defaults and overrides:

```sh
CONCURRENT_THREADS=6 \
CONCURRENT_ITERATIONS=8 \
CONCURRENT_P95_MAX_MS=5000 \
python3 tools/verify_concurrent_compile.py
```

## 3. Runtime Performance And Scale Probe

After installing and publishing at least one model:

```sh
python3 tools/verify_runtime_performance.py
```

The probe selects the largest role-visible semantic object and measures:

- first-call compile latency on the connection;
- warm compile mean, p50, p95, and maximum;
- a broad request containing all mutually compatible visible fields;
- execution time and observed result cardinality for every visible dimension.

The default thresholds allow the bundled sales fixture to run. A CI environment
with dedicated large/high-cardinality data should raise the minimums:

The canonical Nano smoke command pins the bundled fixture floor at nine visible
fields and cardinality three, preventing accidental shrinkage of that fixture.
The standalone probe retains one/one defaults so it can inspect newly created
models before a production-scale profile is selected.

```sh
PERF_MIN_MODEL_FIELDS=100 \
PERF_MIN_CARDINALITY=100000 \
PERF_COLD_MAX_MS=5000 \
PERF_WARM_P95_MAX_MS=1000 \
PERF_EXECUTION_MAX_MS=30000 \
PERF_OUTPUT_JSON=build/runtime-performance.json \
python3 tools/verify_runtime_performance.py
```

Performance thresholds should be calibrated per supported Exasol deployment
profile. Changes should not weaken a committed profile merely to pass CI.

## Coverage Scope

Database-free coverage measures Lua runtime logic. It does not claim coverage
of Exasol's `query()`, script import behavior, transaction semantics, optimizer,
privilege evaluation, or generated SQL execution. Those belong to the Nano
lane. Host-side Ossie/OSI behavior remains in `tests/test_osi_tool.py`, which is
also invoked by the canonical Nano smoke workflow.
