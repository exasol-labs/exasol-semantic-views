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
