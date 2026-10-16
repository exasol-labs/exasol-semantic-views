# SQL Install Sources

Every file here is hand-written; edit them directly. They hold the SQL — tables,
views, grants, and the signature of every script — and no Lua. Each language
has its own files:

| What | Where |
|---|---|
| tables, views, grants, script signatures | `sql/install/*.sql` |
| the body of each script | `lua/semantic_layer/scripts/<script_name>.lua` |
| the runtime libraries the scripts import | `lua/semantic_layer/{shared,compiler,admin,agent}/` |

A script's body is one line in its source, naming the file:

```sql
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL(
  MODEL_NAME, PUBLISHED_SCHEMA, DESCRIPTION, OWNER_ROLE
) AS
-- @lua lua/semantic_layer/scripts/create_model.lua
/
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
| `ADMIN_SCRIPT_PARAMETERS` | `002` | the signature of every script in the build |

The build refuses a body file no script names, a script defined twice, and a
placeholder nothing fills.

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
