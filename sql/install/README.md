# SQL Install Sources

Every file here is hand-written; edit them directly. They hold the SQL —
tables, views and grants — and no Lua. Each language has its own files:

| What | Where |
|---|---|
| tables, views, grants, and where each script installs | `sql/install/*.sql` |
| each script: its signature, documentation and body | `lua/semantic_layer/scripts/<script_name>.lua` |
| the runtime libraries the scripts import | `lua/semantic_layer/{shared,compiler,admin,agent}/` |

A script is one line in the source that installs it:

```sql
-- @lua lua/semantic_layer/scripts/create_model.lua
```

The file opens with an annotation block, from which the build writes the
`CREATE OR REPLACE SCRIPT` statement and the script's rows in
`SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS`; the format is in
[`lua/semantic_layer/scripts/PARAMETERS.md`](../../lua/semantic_layer/scripts/PARAMETERS.md):

```lua
--- Creates a DRAFT semantic model with its initial version 1 and sets it active; returns nothing.
-- @script SEMANTIC_ADMIN.CREATE_MODEL
-- @param MODEL_NAME
-- @param PUBLISHED_SCHEMA Schema that PUBLISH_MODEL will create views in; required identifier.
-- @returns nothing
```

A part that is generated rather than written is one line too:

```sql
-- @generated SEMANTIC_ADMIN.COMPILER_RUNTIME
```

`python3 tools/package_lua_scripts.py` fills both kinds and writes the complete
files to `build/install/`, which is not checked in. The installer builds before
it runs, so the usual command does both:

```sh
python3 tools/install.py
```

`--skip-package` installs `build/install/` as it stands. A release bundle ships
`build/install/` already built, for running the files without Python.

## Generated parts

| Placeholder | In | Built from |
|---|---|---|
| `SEMANTIC_ADMIN.<NAME>_RUNTIME` (six) | `003`, `006` | the `lua/` modules listed for it in `RUNTIMES` in `tools/package_lua_scripts.py` |
| `SEMANTIC_SOURCE_VIEWS` | `001b` | the `SEMANTIC_SOURCE.*` tables the compiler reads |
| `ADMIN_SCRIPT_PARAMETERS` | `002` | the annotated signature and descriptions of every script |

The build refuses a script file no source installs, a script defined twice, a
placeholder nothing fills, and an annotation block that is incomplete: no
summary, a parameter without a description, or one the body never reads.

## File order

```text
000_create_schemas.sql
001_create_semantic_catalog.sql
001b_create_semantic_source_views.sql
002_create_semantic_catalog_views.sql
003_create_semantic_admin_scripts.sql
004_create_semantic_preprocessor.sql
005_create_semantic_surface_helpers.sql
006_create_semantic_agent_views.sql
```

Run the built files from `build/install/` in this order; the installer also
migrates added columns between 001 and 001b.
