#!/usr/bin/env sh
set -eu

# pyexasol 3 reports usage on connect; a test run never does.
export EXASOL_TELEMETRY_DISABLE=true

lua_version="${LUA_VERSION:-5.4.9}"
lua_bin="$(python3 tools/lua_runtime.py --version "$lua_version" --lua)"
luac_bin="$(python3 tools/lua_runtime.py --version "$lua_version" --luac)"

LUA_VERSION="$lua_version" LUAC_BIN="$luac_bin" "$lua_bin" tests/lua/run.lua "$@"
