# Lua runtime tests after `amalg`: custom runner or Busted and LuaCov

**Evaluation assumption:** Lua packaging has already moved to `amalg`, and
runtime modules import one another through `require()`. This is the baseline for
this decision record, not a claim about the present checkout.

**Status:** Busted is a plausible replacement for test execution under that
assumption. Retaining the entire custom runner has no established necessity;
coverage and decision-outcome gates still need a representative comparison.

## Required behavior under the assumed design

Tests must exercise `require()`-based modules and the bundled runtime that
Exasol installs, use strict script-body fixtures, isolate test state, shuffle
with a replayable seed, and keep per-module and per-script active-line
thresholds plus named true/false decision outcomes. The current
[`run.lua`](../../tests/lua/run.lua), [test README](../../tests/lua/README.md),
and [runtime testing guide](../runtime-testing.md) document these existing gates.
The assumed migration changes module loading, not the need to verify them.

## Documented alternative

Busted documents filtering, setup and teardown hooks, seeded file and test
shuffling, and per-file environment insulation. With `require()`-based modules,
specs could load modules through their public imports; a separate integration
check could load the `amalg` bundle to catch packaging and export mistakes.
The old objection that every source must share one global test environment
does not apply under this assumption. Whether package-cache reset and script
fixtures provide the required isolation still needs verification.
[Source: Busted](https://github.com/lunarmodules/busted).

Busted's `--coverage` option uses LuaCov. LuaCov documents include/exclude
rules and custom reporters, so per-module threshold reporting may be possible.
The published APIs do not establish an identical active-line denominator for
uncalled nested functions or a built-in named decision-outcome gate. Those
checks could remain small extensions even if Busted runs the tests.
[Sources: Busted CLI](https://github.com/lunarmodules/busted/blob/master/busted/modules/cli.lua),
[LuaCov](https://github.com/lunarmodules/luacov).

Database-free CI would need Busted and LuaCov installed and versioned in
addition to Lua 5.4 and its compiler.

## Evidence still needed

No representative Busted run against the assumed `require()` modules and
`amalg` bundle is recorded. Compare module tests, bundle integration, strict
script-body fixtures, cache and global isolation, seeded order, active-line
denominators, threshold enforcement, and named decision outcomes before
deciding which parts of the custom runner to retire.
