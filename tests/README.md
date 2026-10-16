# Tests

Each directory is one lane: one runtime requirement, one runner, one CI job.

| Directory | What it tests | Needs | Run with | CI |
|---|---|---|---|---|
| `unit/` | Python host tooling, install SQL structure, repository conventions | Python | `sh tools/run_python_tests.sh` | `runtime-tests` / database-free |
| `lua/` | the Lua runtimes, as Exasol assembles them | `lua5.4` | `sh tools/run_lua_tests.sh` | `runtime-tests` / database-free |
| `integration/` | the installed layer end to end | a database with the sales example installed | `sh tools/run_smoke.sh` | `smoke` |
| `integration/fresh_install/` | what the installer leaves behind | a database installed a moment ago | `sh tools/run_smoke.sh` (first) | `smoke` |
| `fuzz/` | compiler equivalence under random requests | an installed database, and minutes | `sh tools/run_release_gate.sh` | before a release |

`fixtures/` holds input data that more than one lane reads.

Static analysis is not a test lane here; `sh tools/run_static_checks.sh` runs it,
as does the `static-checks` CI job.

## Where a new test goes

- It needs no database: `unit/` for Python, `lua/` for the runtimes. Most
  behaviour of the compiler, validator and parsers belongs in `lua/`.
- It needs the installed layer: `integration/`, as a pytest `test_*.py` module
  using the fixtures in `integration/conftest.py`.
- It checks state only a fresh install has: `integration/fresh_install/`.

Each lane's own README says more: `lua/README.md`, and the docstring of
`integration/conftest.py`.
