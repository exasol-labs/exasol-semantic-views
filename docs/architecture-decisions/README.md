# Implementation Decision Records

These records compare implementation choices with named alternatives. They are
the home for evidence, tradeoffs, and open questions about those choices. The
[architecture](../architecture.md) and component documentation describe the
current system; source comments retain only facts needed to maintain it.

| Choice | Record |
| --- | --- |
| SQL lexer and Exasol `sqlparsing` | [SQL tokenization](sql-tokenization.md) |
| JSON codec and Lua CJSON | [JSON codec](json-codec.md) |
| Lua packaging and `amalg` | [Lua packaging](lua-packaging.md) |
| Lua test runner and Busted/LuaCov, assuming `amalg` and `require()` | [Lua test runner](lua-test-runner.md) |

These are documentation reviews, not runtime comparisons. A cited API shows
that an approach may be possible; it does not prove equivalence on a supported
Exasol version. The SQL record documents a decision to retain the current
solution. The test-runner record evaluates an assumed module and packaging
migration; it does not describe the present build.
