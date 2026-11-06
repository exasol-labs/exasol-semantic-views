# JSON codec: custom Lua or Lua CJSON

**Status:** Keep the current codec for now. Lua CJSON is a viable replacement
for ordinary decoding, but a direct replacement of the encoder would change
numeric values and the compiler's cache keys. Legacy, non-standard JSON
decoding is not a requirement for a future codec.

## Current use

[`shared/json.lua`](../../lua/semantic_layer/shared/json.lua) provides `decode`,
`is_valid`, `encode`, and one shared `NULL` sentinel. It sorts object keys when
encoding. The strict validator and the lenient decoder currently disagree on
inputs such as `01` and malformed Unicode escapes; that compatibility behavior
can be removed when changing codecs.

Stable object-key order is required for the structured-request cache:
[`canonical_request_text`](../../lua/semantic_layer/compiler/request_json.lua)
serializes the request and hashes the resulting bytes. Equivalent requests
must yield the same key regardless of table insertion order. It is not a
general requirement for every JSON result. In particular,
`EXPORT_SEMANTIC_DEFINITION` emits SQL rather than JSON, and the fusion export
explicitly controls its outer JSON fields and entity order. The latter's
nested objects still benefit from stable formatting for readable diffs, but
that is not itself a correctness requirement.

## CJSON behavior

Exasol [bundles `lua-cjson`](https://docs.exasol.com/db/latest/database_concepts/udf_scripts/lua.htm)
and [updated it to 2.1.0.10 in Exasol 8.34.0](https://docs.exasol.com/db/latest/changelogs/24031.htm).
The [Lua CJSON manual](https://kyne.au/~mark/software/lua-cjson-manual.html)
documents `cjson.null`: decoded JSON `null` is a light userdata value that
compares equal to this sentinel, including in objects and arrays. It can be
encoded back to JSON `null`. A shared wrapper could expose it as `NULL` without
translating every decoded value. Exasol's SQL `null` is separate and needs an
encoding guard. The exact bundled CJSON version in each supported Exasol
2025.1+ runtime has not been checked here.

The manual also documents `cjson.new()` for independent configuration and
`decode_invalid_numbers(false)` to reject non-standard numbers. The encoder
defaults to 14 significant digits and cannot be configured above 14. CJSON
does not promise sorted object keys.

## Local experiment, 2026-11-06

Ran Lua 5.4.8 with `lua-cjson` 2.1.0.10 from
`~/.luarocks/lib64/lua/5.4/cjson.so`, against the current
`shared/json.lua`. The CJSON instance used `decode_invalid_numbers(false)`.
This is a local library comparison, not an Exasol runtime measurement.

| Case | Current codec | CJSON |
| --- | --- | --- |
| Decode `null`, `{"k":null}`, `[null]` | Shared table sentinel | All compare equal to `cjson.null`; re-encode as `null` |
| Decode `"\\u0041"` | `"?"` | `"A"` |
| Decode `01` or `"\\uZZZZ"` | Accepted by lenient `decode` | Rejected |
| Decode `1.` or a raw newline in a string | Accepted | Also accepted; `decode_invalid_numbers(false)` alone is not an RFC 8259 validator |
| Decode `9007199254740993` | Exact Lua integer | Rounded Lua float |
| Encode `1234567890123456` | `1234567890123456` | `1.2345678901235e+15` |
| Encode `9007199254740991` | `9007199254740991` | `9.007199254741e+15` |
| Encode the same 40-key object built in opposite insertion orders | Identical strings | Different key order |
| Decode 10,000 small nested requests | 0.195 s | 0.009 s |

The timing is one local `os.clock()` run and is only directional. CJSON
preserved the tested ordinary scalar and nested values, and its Unicode
decoding is more faithful. Its default encoding of 16-digit integers is
value-changing, not merely a different spelling. The current formatter also
uses Lua `tostring` for floating-point numbers, so it does not guarantee
lossless round trips for arbitrary doubles either; the precision conclusion
is specifically that CJSON's 14-digit limit is insufficient for the integer
values the current formatter preserves. CJSON also parses large integer JSON
numbers as floating-point values, so a decoder change needs a documented
numeric range or a guard for integer-sensitive fields.

## Decision for a future change

Use CJSON decoding only after defining the accepted numeric range and checking
the validation path separately. `is_valid` still needs strict JSON checks:
the tested CJSON configuration accepted `1.` and a raw newline in a string.
Do not preserve the custom decoder's legacy acceptance of malformed input.

Keep deterministic encoding for cache input, either with the current formatter
or a dedicated canonical serializer. Ordinary JSON output need not have sorted
keys. Before replacing the formatter, specify how to handle SQL `null`, empty
objects versus arrays, and numeric values beyond 14 significant digits.
