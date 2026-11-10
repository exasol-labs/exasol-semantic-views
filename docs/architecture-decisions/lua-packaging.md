# Lua packaging: self-contained `amalg` bundles

**Decision:** Package each callable Exasol script with its required Lua modules
as a self-contained, non-debug `amalg` bundle. Modules communicate through
`require()` and returned values, without application-level exported globals or
Exasol `import()`. Generate the `package.searchers` compatibility shim at build
time. Duplication of modules across installed scripts is acceptable. This is
the target design; the current generator still implements the old design.

## Current contract

[`package_lua_scripts.py`](../../tools/package_lua_scripts.py) concatenates an
ordered source list into each runtime `CREATE SCRIPT`, embeds annotated script
bodies into install SQL, derives script signatures and catalog views, stamps
compiler sources, and checks generated SQL and Lua local-variable headroom.
The [packager tests](../../tests/unit/test_install.py) and
[convention tests](../../tests/unit/test_conventions.py) cover those jobs. The
Lua files communicate through globals in a shared script chunk, rather than
`require`-based modules. `amalg` could only take over the bundling job; the
other generation and validation jobs would still need a generator.

The current generator produced `CREATE SCRIPT` statements of **245,735 bytes**
for `SEMANTIC_DEFINITION_RUNTIME` and **554,483 bytes** for
`COMPILER_RUNTIME`. These are UTF-8 byte counts of the individual generated
statements, not database limits. The experiment compared body bytes separately.

## Documented alternative and limits

`amalg` bundles Lua modules located through `package.path`, can embed a main
script, and has a debug mode intended to preserve original file and line
information. Its documentation says it does not statically discover `require`
dependencies. The current global-sharing sources therefore need conversion
to modules with explicit `require()` dependencies and returned API tables.
Each installed script will bundle its entry code and transitive dependencies.
The experiment tested an intermediate adaptation for two runtimes; it
preserved the existing globals to compare behavior rather than implementing
the target module API.
[Source: `amalg` README](https://github.com/siffiejoe/lua-amalg).

Exasol documents a **maximum of 200 local variables** in a Lua function. Since
the current generated runtime is one chunk, this applies to concurrently active
top-level locals across concatenated files; the generator measures that peak.
This is a Lua compilation constraint, **not a maximum script size in bytes**.
[Source: Exasol scripting language](https://docs.exasol.com/db/latest/database_concepts/scripting/general_script_language.htm).

`EXA_ALL_SCRIPTS.SCRIPT_TEXT` contains the complete script creation text and
is `VARCHAR(2000000)`. Exasol defines `VARCHAR` length in characters, not
bytes. The largest tested `amalg` body, the debug compiler bundle at
575,478 UTF-8 bytes, is therefore well within that column's capacity even
after adding the short `CREATE SCRIPT` header. Both trial bundles also
installed successfully. A separate boundary test on the local Exasol database
on 2026-11-09 found a stricter limit: a disposable script with stored
`SCRIPT_TEXT` length **1,999,000 characters** installed, while one character
more failed with code `42000`, `script text too long, maximum allowed
characters: 1999000`. The tested `CREATE OR REPLACE SCRIPT` statements were
1,999,016 and 1,999,017 ASCII characters respectively; the stored text was
16 characters shorter. Repeating the boundary with `é` instead of ASCII
produced the same result: 1,999,000 stored characters installed and 1,999,001
was rejected, although the accepted SQL statement occupied 3,997,960 UTF-8
bytes. Thus the observed limit counts characters, not UTF-8 bytes, and the
`VARCHAR(2000000)` column size is not the effective `CREATE SCRIPT` text limit
on that database. These tests do not establish the limit for every Exasol
version. Separate imported scripts are another documented packaging option,
but are outside the chosen self-contained design.
[Sources: `EXA_ALL_SCRIPTS`](https://docs.exasol.com/db/latest/sql_references/system_tables/metadata/exa_all_scripts.htm),
[`VARCHAR` data type](https://docs.exasol.com/db/latest/sql_references/data_types/datatypedetails.htm),
[`CREATE SCRIPT`](https://docs.exasol.com/db/latest/sql/create_script.htm),
[script imports](https://docs.exasol.com/db/latest/database_concepts/scripting/db_interaction.htm).

## Live experiment on two runtimes

The 2026-11-06 trial used Lua 5.4.8, LuaRocks `amalg` 0.8-1, and Exasol
2026.2.0-nano.8. It copied sources for `SEMANTIC_DEFINITION_RUNTIME` and
`COMPILER_RUNTIME` into an isolated experiment area, appended `return true`
to make them explicit modules, and preserved their `RUNTIMES` source order
and all exported globals, including `ESV_JSON` and `ESV_SQL_TEXT`.
`amalg.lua -d -o <bundle> -s <main> <explicit modules>` built each debug
bundle twice from clean inputs at the same path with identical SHA-256 hashes.
`luac -p` accepted both, and the packager's Lua 5.4 active-local probe
measured zero locals in their main chunks. The embedded functions still have
their own 200-local limit.

| Runtime | Baseline body | Debug body | Plain body | Baseline local peak |
| --- | ---: | ---: | ---: | ---: |
| Definition | 245,540 B | 256,858 B (+4.61%) | 247,236 B | 109 |
| Compiler | 554,321 B | 575,478 B (+3.82%) | 557,286 B | 182 |

Both debug bundles installed under distinct names in a disposable schema,
but first use failed with Exasol code `43000`, `attempt to call a nil value`
at runtime line 1. That line invokes `(loadstring or load)`; an installed
probe showed both functions are `nil` in this Exasol Lua environment. A
deliberate error in a separate experiment-only copy was traced to
`trial_00.lua:347` under local Lua, so local debug line mapping worked, but
the debug bundle never reached its parser on Exasol. Debug mode is not a
requirement for the chosen design.

Without debug mode, Exasol's `require` did not find the modules that `amalg`
placed in `package.preload`. A `package.searchers` shim from another Exasol
project resolved that lookup. The installed non-debug trial bundles then
passed **10/10** direct comparisons with the unchanged runtimes: quoted and
nested Semantic DDL preprocessing, JSON escaped text/null identity and
deterministic encoding, a successful definition dry run on a disposable
model, four SQL compile cases, and three JSON request compile cases. The
controls and trials matched on status, error code, generated SQL, plan JSON,
and clarification JSON after excluding generated IDs and audit timestamps.
The compiler retained its import of the current
`SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME`.

## Implementation work

Convert the shared and compiler/admin sources to modules with explicit
`require()` dependencies and returned API tables. Bundle each callable script
with its transitive modules, insert the Exasol `package.searchers` shim during
the build, and replace every Exasol `import()` call. The generator must still
handle script signatures, install-SQL placement, catalog views, build stamps,
and validation. Add a generated-script character-count check against the
measured 1,999,000-character limit, then test every callable script, permission
context, and supported Exasol version. The existing two-runtime comparison
does not cover this per-script design.

The tested bundles installed and are far below the measured script-text limit
on the local database. Keeping each source as a separate module chunk also
avoids adding its top-level locals to one shared chunk; individual Lua
functions still have the documented 200-local ceiling.
