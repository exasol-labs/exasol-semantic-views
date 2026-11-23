#!/usr/bin/env sh
set -eu

# pyexasol 3 reports usage on connect; a test run never does.
export EXASOL_TELEMETRY_DISABLE=true

lua_bin="$(python3 tools/lua_runtime.py --lua)"
luac_bin="$(python3 tools/lua_runtime.py --luac)"

LUAC_BIN="$luac_bin" "$lua_bin" tests/lua/run.lua "$@"
