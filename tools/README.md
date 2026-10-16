# Tools

Operational tooling — what a user or an operator runs — at the top level:

| Tool | Purpose |
|---|---|
| `install.py` | package and install the layer, optionally with the sales example |
| `package_lua_scripts.py` | regenerate the install SQL from `lua/` (run after every Lua edit) |
| `run_sql_files.py` | run SQL files against the deployment, including slash-delimited script blocks |
| `semantic_client.py` | thin host-side helpers for calling the layer's scripts |
| `osi.py` | Ossie/OSI import and export |
| `import_databricks.py` | import a Databricks metric view YAML |
| `release_notes.py` | release notes from `CHANGELOG.md` |

The `run_*.sh` scripts are the entry points to the test lanes and static checks;
`tests/README.md` maps each to what it runs and needs.

`dev/` holds developer helpers that no user runs: `lint_embedded_lua.py` (used by
`run_static_checks.sh`), `measure_expansion_cost.py` (a live-database
measurement), and `user_studies/`, the simulated-user harness behind the
persona reports in `reports/`.
