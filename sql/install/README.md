# SQL Install Files

These seven files must be run in order. The easiest way is the installer:

```sh
python3 tools/install.py
```

The installer packages the Lua runtime into `003_create_semantic_admin_scripts.sql`
before executing the files. Pass `--skip-package` if you have already packaged
the Lua sources in a prior step.

## File order

```text
000_create_schemas.sql
001_create_semantic_catalog.sql
002_create_semantic_catalog_views.sql
003_create_semantic_admin_scripts.sql
004_create_semantic_preprocessor.sql
005_create_semantic_surface_helpers.sql
006_create_semantic_agent_views.sql
```

`003_create_semantic_admin_scripts.sql` is generated — do not edit it directly.
Edit the Lua sources under `lua/semantic_layer/` and re-run
`python3 tools/package_lua_scripts.py` (or just `python3 tools/install.py`).
