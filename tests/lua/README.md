# Lua Runtime Tests

The runtime has a database-free test lane in addition to the live-DB
integration suite (`tools/run_smoke.sh` — see `docs/runtime-testing.md`).

```sh
sh tools/run_lua_tests.sh                 # everything, with the coverage gates
sh tools/run_lua_tests.sh "reference expansion"   # tests whose name contains it
ESV_TEST_SEED=1234 sh tools/run_lua_tests.sh      # reproduce a shuffled order
```

A filtered run skips the coverage gates, which only mean something for the
whole suite.

## What the runner provides

`run.lua` is plain Lua with no LuaRocks dependencies. It loads the canonical
sources under `lua/semantic_layer` into one global environment — the way
`import()` exposes a runtime's top-level globals inside Exasol — then runs every
`*_unit_test.lua` listed in `specs`. Plain Lua cannot list a directory, so
`tests/test_conventions.py` checks that the list names every such file.

| Global | Purpose |
|---|---|
| `test(name, fn)` | declare a test |
| `assert_equal`, `assert_true`, `assert_contains`, `assert_error` | assertions; failures name the expected and actual values |
| `assert_branch(name, actual, expected)` | assert *and* record a decision outcome for the decision-coverage gate |
| `each(cases, fn)` | a table-driven test: `fn(case, index)` per case, and a failure names the case — `case 3 of 7 (<case>): …` |
| `with_query(mock, fn)` | replace Exasol's `query()` with a fixture while `fn` runs; restored even if it fails |
| `defer(fn)` | cleanup to run after the current test, even if it fails, latest first |

Exasol supplies some globals to every script; the runner supplies stand-ins:

| Exasol global | In the tests |
|---|---|
| `null` | a sentinel table whose `tostring` is `"null"` — truthy, like the userdata it stands for |
| `query(sql, params)` | absent; a test that reaches the catalog installs a fixture with `with_query` |
| `pquery`, `exit`, `import`, `exa`, `sqlparsing` | absent; code that needs them is covered by the live suite |

`ESV_TEST_MODE = true` makes each runtime publish an `ESV_*_TEST_API` table of
its internals. The flag is absent in Exasol, so those tables never become part
of the installed API.

## Isolation

Tests run in a shuffled order by default; the seed is printed, and
`ESV_TEST_SEED=<n>` reproduces it (`none` keeps file order). After each test the
runner compares the global environment with what it was before: a test that
leaves a mock installed, or sets a global and does not clear it, fails by name
— and the state is restored, so it cannot change what later tests see. Use
`with_query` or `defer` rather than restoring by hand.

## Coverage

`run.lua` uses Lua's debug line hook and each loaded function's active-line
metadata. It recursively follows closures from the installed public functions,
so the denominator covers runtime functions rather than counting comments or
blank lines.

Thresholds live in `coverage_thresholds.lua` and are enforced per module. The
suite also records named decision outcomes; each decision passed to
`assert_branch` is expected to be observed both true and false.

Threshold policy:

- raise a module threshold when tests increase its coverage;
- never lower a threshold merely to make a change pass;
- add a regression test before fixing a runtime defect;
- keep Exasol-dependent behavior in the live-DB smoke suite.

## Why not busted

busted was considered (2026-10) and not adopted. Its coverage is luacov, which
counts lines differently — every ratcheted threshold above would reset — and
has no equivalent of the decision-outcome gate. Its per-file insulation works
against loading every runtime into one environment, which is what makes these
tests exercise the runtime as Exasol assembles it. And it brings a LuaRocks
dependency chain to a job that needs only `lua5.4`. What it would have added —
selection by name, table-driven cases that name the failing case, per-test
cleanup, isolation and shuffled order — the runner now does itself.
