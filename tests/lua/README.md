# Lua Runtime Tests

The runtime has a database-free test lane in addition to the live-DB
integration suite (`tools/run_system_tests.sh` — see `docs/runtime-testing.md`).

```sh
sh tools/run_lua_tests.sh                 # everything, with the coverage gates
sh tools/run_lua_tests.sh 'ADD_CUSTOM_EXTENSION: stores empty object without rewriting'
                                           # one test with this full name
sh tools/run_lua_tests.sh --file tests/lua/scripts/add_custom_extension_test.lua
                                           # every test defined in this file
ESV_TEST_SEED=1234 sh tools/run_lua_tests.sh      # reproduce a shuffled order
```

Run these commands from the repository root. The argument is a case-sensitive,
literal substring of the test name printed after `PASS` or `FAIL`; use the full
name to select one test. `--file` takes a repository-relative test file path and
runs every test registered by that file, regardless of its test names. It works
for both `tests/lua/scripts/*_test.lua` and `tests/lua/*_unit_test.lua`.
Filtered runs skip the coverage gates, which only mean something for the whole
suite. The summary reports how many tests matched, so check that it says
`1 tests matching` when running a single test.

## What the runner provides

`run.lua` is plain Lua with no LuaRocks dependencies. It loads the canonical
runtime sources under `lua/semantic_layer` into one global environment — the way
`import()` exposes a runtime's top-level globals inside Exasol — then runs every
`*_unit_test.lua` listed in `specs`. Every installed script body has one test
file in `tests/lua/scripts/` and runs in a fresh environment
through the shared `harness.lua`. Plain Lua cannot list a directory, so
`tests/unit/test_conventions.py` checks that the spec list is complete and the
installed-script manifest matches the packager registry, test files and thresholds.

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
| `pquery` | absent; code that needs it is covered by the live suite |
| `exit`, `import`, `exa.import`, `sqlparsing` | strict per-script fixtures in `tests/lua/scripts/harness.lua`; absent from runtime tests |

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

The installed script bodies have a separate per-script coverage report and floors.
The runner derives their active lines from Lua 5.5 compiler listings, including
nested local functions that a test never invokes. `tools/run_lua_tests.sh`
selects the Lua interpreter and compiler; set `LUA_BIN` and `LUAC_BIN` if needed.

`semantic_fuzz_driver.lua` is a separate JSON-lines compiler driver used by the
database-free SQLGlot fuzz campaign. It shares the sales catalog fixture with
`compiler_unit_test.lua`; it is not part of the coverage runner.

## Script-body test conventions

- Keep one file per installed script in `tests/lua/scripts/<name>_test.lua`.
  Share Exasol stand-ins and fixture helpers through `harness.lua`.
- Bind the script name once per file with
  `local run, test_script = H.for_script("<name>")`. Register each case as
  `test_script("behavior", function() ... end)`; the log then starts with the
  installed script name, such as `ADD_ENTITY: rejects reserved alias`.
- Call the bound `run` exactly once per case. Put success, refusal, and other
  scenarios in separate cases so each failure identifies one behavior.
- Supply only the expected imports and SQL steps. The harness gives each run a
  fresh environment, rejects unexpected calls, and checks that every expected
  SQL step was consumed. Assert rows, result columns, bindings, and call order
  where they define the behavior.

To add another body, add its name to `tests/lua/scripts/manifest.lua`, add its
test file following these conventions, and add a measured floor to
`coverage_thresholds.lua`. The convention tests check the complete inventory,
per-file binding, and one-run-per-case rule.

Threshold policy:

- raise a module threshold when tests increase its coverage;
- never lower a threshold merely to make a change pass;
- add a regression test before fixing a runtime defect;
- keep Exasol-dependent behavior in the live-DB smoke suite.

## Busted and LuaCov comparison

[The decision record](../../docs/architecture-decisions/lua-test-runner.md)
compares their documented capabilities with this runner's requirements under
the assumption that packaging has moved to `amalg` and imports use `require()`.
