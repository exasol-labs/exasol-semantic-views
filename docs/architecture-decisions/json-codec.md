# JSON codec: custom Lua or Lua CJSON

**Status:** Current codec retained pending comparison with the Exasol-provided
CJSON version. A CJSON-backed *parser* appears feasible; the custom formatter's
requirements must be assessed separately.

## Current contract

[`shared/json.lua`](../../lua/semantic_layer/shared/json.lua) exposes `decode`,
strict `is_valid`, `encode`, and a shared `NULL` sentinel. `decode` deliberately
accepts some legacy scalar spellings that `is_valid` refuses; the
[JSON tests](../../tests/lua/json_unit_test.lua) pin those differences. `encode`
sorts object keys, maps SQL `null` and its JSON sentinel to JSON `null`, and
uses Lua's `tostring` for numeric values. Sorted keys matter for exported
documents and canonical cache inputs. This describes existing behavior; it does
not prove CJSON cannot serve either half of the contract.

## Documented alternative

Exasol lists `lua-cjson` among its Lua libraries. Its published changelog says
it updated from 2.1.0 to 2.1.0.10 in Exasol 8.34.0; the exact version in each
supported 2025.1+ runtime still needs confirmation.
[Sources: Exasol Lua libraries](https://docs.exasol.com/db/latest/database_concepts/udf_scripts/lua.htm),
[Exasol CJSON update](https://docs.exasol.com/db/latest/changelogs/24031.htm).

The CJSON manual documents `decode`, `encode`, a `cjson.null` sentinel,
`cjson.new()` for separate configuration, `decode_invalid_numbers(false)`, and
an encoding precision setting limited to 14 significant digits. It does not
promise sorted object keys. An adapter could translate `cjson.null` to the
repository's shared sentinel and reject or normalize SQL `null` before encoding.
A deterministic formatter might still be needed even if CJSON replaces parsing.
The precision limit may matter for numeric output; whether it changes actual
Exasol values and which callers require exact spelling remain unverified.
[Source: Lua CJSON manual](https://kyne.au/~mark/software/lua-cjson-manual.html).

## Evidence still needed

The source header previously described an October 2026 CJSON measurement, but
no probe, database version, or raw output is retained. Its claims about key
order, SQL `null` encoding, precision, and sentinel identity are historical
observations, not reproducible evidence here. A follow-up should compare
configured CJSON with the parser and formatter contracts separately, including
strict versus legacy decoding and the private script-body parsers.
