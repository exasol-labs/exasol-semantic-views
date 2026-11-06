# SQL tokenization: custom lexer or Exasol `sqlparsing`

**Decision:** Keep the shared SQL lexer and the Semantic SQL and Semantic DDL
parsers. Do not replace the lexer with an Exasol `sqlparsing` adapter. This is a
maintenance and testability decision, not a claim that `sqlparsing` cannot
tokenize Semantic SQL or `ALTER SEMANTIC VIEW`.

## Current contract

[`shared/sql_text.lua`](../../lua/semantic_layer/shared/sql_text.lua) produces
tokens with `text`, `kind`, and, where applicable, `value` and `upper`. Each has
one-based inclusive byte positions `start_pos` and `end_pos`, and parenthesis
`depth`. It skips whitespace and comments and removes a trailing semicolon. The
Semantic SQL caller asks for
compound operators (`>=`, `<=`, `<>`, `!=`) as single tokens; the Semantic DDL
caller asks for uppercase decoded quoted identifiers instead. The DDL parser
uses spans to splice expressions, while the compiler also uses spans and depth
for SQL composition and reference expansion. These are observed code contracts,
not evidence that Exasol cannot satisfy them. The [lexer tests](../../tests/lua/sql_text_unit_test.lua)
and [compiler tests](../../tests/lua/compiler_unit_test.lua) cover examples of
quoted identifiers, escaped literals, comments, operators, and nesting.

The same lexer runs in the session preprocessor and in direct `COMPILE_SQL`
scripts. [Database-free Lua tests](../../tests/lua/README.md) load these runtimes
without an Exasol `sqlparsing` global.

## Documented alternative

Exasol documents `sqlparsing.tokenize(sqlstring)` as returning strings whose
concatenation reconstructs the input, including whitespace, line breaks, and
comments. It documents helpers for comments, whitespace, identifiers,
keywords, strings, and numbers, and shows `tokenize` called from a regular Lua
script. The documentation therefore supports using it outside the preprocessor
hook; it does not document token objects with spans or nesting.
[Source: Exasol SQL preprocessor](https://docs.exasol.com/db/latest/database_concepts/sql_preprocessor.htm).

This includes the intended `ALTER SEMANTIC VIEW` path in principle: Exasol runs
the preprocessor before its SQL compiler, allowing unsupported syntax to be
rewritten. Today the preprocessor passes the original statement to
`semantic_definition.preprocess_sql`, whose own parser recognizes `ALTER`,
`SEMANTIC`, and `VIEW` before parsing the rest. `sqlparsing.tokenize` would only
replace that parser's lexer; it would not supply the Semantic DDL grammar or
perform the rewrite. Exasol's documentation explicitly lists qualified names
such as `test.tab` and `"foo"."bar"` as single identifier tokens. The current
Semantic DDL parser expects separate name, dot, and name tokens, so an adapter
would need to split qualified identifiers while preserving quotes and byte
positions. Exasol also describes `iskeyword` in terms of its SQL keywords; it
cannot be assumed to classify this repository's `SEMANTIC` vocabulary.

An adapter could filter whitespace and comments, accumulate byte lengths to
derive spans, decode quoted identifiers, track parentheses for depth, and split
or combine operator strings for the two modes. This is an implementation
inference from the documented string-token API, not a demonstrated equivalent.
It would also need to preserve current behavior for unsupported or incomplete
SQL fragments, which a database tokenizer may handle differently.

`sqlparsing.tokenize` only separates lexical units. The repository still needs
its semantic grammar parser to recognize model fields, Semantic DDL, clause
boundaries, and supported or refused query shapes. Tokenization alone cannot
replace that parser.

## Rationale

- Owning the semantic grammar is the most flexible option for this layer: we
  can define the `ALTER SEMANTIC VIEW` and Semantic SQL forms we want, including
  syntax Exasol does not natively understand, then rewrite supported statements
  before Exasol compiles them. The boundary is what the preprocessor receives
  and what our parser and rewrite implement, rather than Exasol's SQL grammar.
  This supports retaining the semantic parser; it does not establish that
  `sqlparsing` could not tokenize the same input.
- The semantic grammar parser remains necessary with either tokenizer. It
  recognizes this repository's `ALTER SEMANTIC VIEW` forms and Semantic SQL
  clauses, applies semantic rules, and produces the repository's diagnostics.
- The existing lexer supplies exactly the token shape those parsers consume.
  Exasol supplies strings; an adapter would still implement span and depth
  tracking, identifier splitting and decoding, comment filtering, and both
  operator and identifier modes. Replacing the lexer would therefore retain
  substantial custom lexical code and require changes to both parser callers.
- One shared lexer already serves the preprocessor, direct compile scripts, and
  the database-free tests. Using `sqlparsing` would introduce an Exasol API
  dependency into those tests or require a second tokenization path for them.
- The current lexer and parser behavior is covered by repository tests. No
  concrete correctness or maintenance benefit from an adapter has been
  established that warrants changing this working contract.

There is no recorded side-by-side output for the supported corpus on a
supported Exasol version. The decision does not rely on claiming that Exasol's
tokenizer is incompatible; its exact tokenization of this corpus remains
unverified. Reconsider only if a specific defect or new requirement gives a
reason to change the lexer.
