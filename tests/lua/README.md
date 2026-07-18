# Lua Runtime Tests

The runtime has a database-free test lane in addition to the Exasol Nano
integration suite.

Run it with:

```sh
sh tools/run_lua_tests.sh
```

The runner uses plain Lua and has no LuaRocks dependencies. It loads the exact
canonical sources under `lua/semantic_layer`, supplies only Exasol's `null`
sentinel, and exercises pure parser, normalization, validation, expression,
agent, and materialization behavior. Tests that need catalog results replace
the Exasol `query()` global with an in-memory fixture.

## Coverage

`run.lua` uses Lua's debug line hook and each loaded function's active-line
metadata. It recursively follows closures from the installed public functions,
so the denominator covers runtime functions rather than counting comments or
blank lines.

Thresholds live in `coverage_thresholds.lua` and are enforced independently for
the compiler, validator, materialization selector, semantic-definition runtime,
and agent runtime. The suite also records named decision outcomes; each named
decision is expected to be observed both true and false.

Threshold policy:

- raise a module threshold when tests increase its coverage;
- never lower a threshold merely to make a change pass;
- add a regression test before fixing a runtime defect;
- keep Exasol-dependent behavior in the Nano suite.

The `ESV_*_TEST_API` tables are created only when `ESV_TEST_MODE` is true. That
flag is absent in Exasol, so they do not expand the installed public API.
