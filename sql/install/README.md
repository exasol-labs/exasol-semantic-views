# SQL Install Order

Planned install order:

```text
000_create_schemas.sql
001_create_semantic_catalog.sql
002_create_semantic_catalog_views.sql
003_create_semantic_admin_scripts.sql
004_create_semantic_preprocessor.sql
005_create_semantic_surface_helpers.sql
006_create_semantic_agent_views.sql
```

Milestones 1 through 3 implement files `000` through `003`. The validator and
structured request compiler are installed from
`003_create_semantic_admin_scripts.sql` as Lua `CREATE SCRIPT` programs. Files
`004` through `006` are placeholders for later milestones.

Run `tools/package_lua_scripts.py` before installing when Lua source files under
`lua/semantic_layer/` change. The Nano smoke script runs this packaging step
automatically.
