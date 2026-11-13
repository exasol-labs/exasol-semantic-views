# Tools

Operational tooling — what a user or an operator runs — at the top level:

| Tool | Purpose |
|---|---|
| `install.py` | package and install the layer, optionally with the sales example |
| `package_lua_scripts.py` | build the install SQL into `build/install/` from `sql/install/` and `lua/` (the installer runs it) |
| `run_sql_files.py` | run SQL files against the deployment, including slash-delimited script blocks |
| `semantic_client.py` | thin host-side helpers for calling the layer's scripts |
| `osi.py` | Ossie/OSI import and export |
| `import_databricks.py` | import a Databricks metric view YAML |
| `release_notes.py` | release notes from `CHANGELOG.md` |
| `run_lua_typecheck.sh` | run LuaLS on hand-written Lua sources and write `build/luals-check.json` |

The `run_*.sh` scripts are the entry points to the test lanes and static checks;
`tests/README.md` maps each to what it runs and needs.
`run_lua_typecheck.sh` installs a pinned LuaLS release on first use, requires
`jq`, and exits with status 1 when it reports diagnostics. CI requires this
check to pass and uploads the JSON report when it fails.

The [Lua packaging decision record](../docs/architecture-decisions/lua-packaging.md)
compares the packager's bundling job with `amalg`.

`dev/` holds developer helpers that no user runs: `lint_script_bodies.py` (used by
`run_static_checks.sh`), `wait_for_exasol.py` (shared CI database readiness check),
`measure_expansion_cost.py` (a live-database
measurement), and `user_studies/`, the simulated-user harness behind the
persona reports in `reports/`.
