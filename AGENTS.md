# Repository instructions

This repository implements a database-native semantic layer for Exasol. Runtime logic runs in Exasol as Lua scripts and SQL. Start with [the glossary](docs/glossary.md) for project terminology.

## Core invariants

- Never write directly to `SYS_SEMANTIC`; use admin scripts. Callers receive principal-scoped `SEMANTIC_SOURCE` views, not access to the authoritative catalog.
- Keep install SQL generated from the hand-written sources: Lua lives in `lua/semantic_layer/scripts/`; SQL placeholders use `-- @generated NAME` and `-- @lua path`. Run `python3 tools/package_lua_scripts.py` to inspect generated output; do not hand-edit generated files under `build/install/`.
- Compiler catalog reads must have corresponding `SEMANTIC_SOURCE` views. The package builder derives this surface and fails on uncovered reads.
- Keep each routine in one place. Shared Lua belongs in `lua/semantic_layer/shared/` and must be included in each relevant runtime. Script bodies should import common helpers from `SEMANTIC_ADMIN.SCRIPT_SUPPORT_RUNTIME`.
- Use one validation code per condition; severity belongs in the result channel, not the code spelling. Update `docs/validation-rules.md` when rules change.
- Name verifiers for the invariant they protect. Integration tests belong in pytest `tests/integration/test_*.py`, use shared fixtures and `verify_support.py`, and should cover one property each. Convert legacy `verify_*.py` scripts when touching them.
- In Python exception tests, construct fixtures and arguments before `assertRaises` or `assertRaisesRegex`. Put only the call expected to raise inside the assertion block; nest `subTest` outside it.
- Derive introspection surfaces from Exasol metadata where possible; declare unavoidable polymorphic relationships once and reuse that declaration.
- Read `docs/governance.md` before adding a security control: the compiler runs with caller rights, so compiler-only policy is defense in depth.

## Verification commands

- `sh tools/run_static_checks.sh` — Ruff, mypy, Luacheck, ShellCheck, LuaLS, zizmor.
- `sh tools/run_python_tests.sh` — Python unit/property tests and coverage thresholds.
- `sh tools/run_lua_tests.sh` — database-free Lua runtime tests and coverage.
- `sh tools/run_system_tests.sh` — full live Exasol system suite; requires a reachable deployment. See [tests/README.md](tests/README.md).
- `sh tools/run_release_gate.sh` — system suite plus multi-seed differential fuzzing; use before major releases.
- `python3 tests/integration/verify_runtime_performance.py` — live cold/warm and scale probe.

For local Exasol Personal setup and connection defaults, see [the setup guide](docs/development.md). For the install pipeline and runtime map, see [architecture](docs/architecture.md). For commands and test lane details, see [tests](tests/README.md).

## Tool instruction loading

Start Codex and Claude Code from the repository root in a fresh session. Codex discovers this root `AGENTS.md`; Claude Code imports it through root `CLAUDE.md`'s `@AGENTS.md`. Confirm the active guidance by asking the tool to summarize its repository instructions, including the core invariants above. See [docs/development.md](docs/development.md) for details.
