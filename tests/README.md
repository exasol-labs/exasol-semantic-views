# Tests

Each directory is one lane: one runtime requirement, one runner, one CI job.

| Directory | What it tests | Needs | Run with | CI |
|---|---|---|---|---|
| `unit/` | Python host tooling, install SQL structure, repository conventions | Python | `sh tools/run_python_tests.sh` | `CI` / `database-free` |
| `lua/` | the Lua runtimes, as Exasol assembles them | `lua5.4` | `sh tools/run_lua_tests.sh` | `CI` / `database-free` |
| `integration/` | the installed layer end to end | a database with the sales example installed | `sh tools/run_system_tests.sh` | `CI` / `system-tests` |
| `integration/fresh_install/` | what the installer leaves behind | a database installed a moment ago | `sh tools/run_system_tests.sh` (first) | `CI` / `system-tests` |
| `fuzz/` | compiler equivalence, SQL contract, and independent sales references | Exasol for live campaigns; Lua for SQLGlot contract | `sh tools/run_release_gate.sh` or `python3 tests/fuzz/run_semantic_fuzz.py --generator sqlglot --oracle reference --cases 8` | CI / `fuzz-smoke` and `database-free`; release / `fuzz` |

`fixtures/` holds input data that more than one lane reads.

Static analysis is not a test lane here; `sh tools/run_static_checks.sh` runs it,
as does the `static-checks` CI job.
Run `sh tools/run_lua_typecheck.sh` for LuaLS type diagnostics. It requires
`curl` and `jq`, downloads a checksum-verified LuaLS release into ignored
`build/` on first use, and writes `build/luals-check.json`. The command exits
with status 1 for any diagnostic. The `static-checks` CI job runs it as a
required gate and uploads the report even when LuaLS finds diagnostics.

The CI `dependency-audit` job runs `pip-audit` on both requirements files and is
required by `ci-gate`; a separate scheduled workflow runs the same audit daily.

## Where a new test goes

- It needs no database: `unit/` for Python, `lua/` for the runtimes. Most
  behaviour of the compiler, validator and parsers belongs in `lua/`.
- It needs the installed layer: `integration/`, as a pytest `test_*.py` module
  using the fixtures in `integration/conftest.py`.
- It checks state only a fresh install has: `integration/fresh_install/`.

Each lane's own README says more: `lua/README.md`, and the docstring of
`integration/conftest.py`.
