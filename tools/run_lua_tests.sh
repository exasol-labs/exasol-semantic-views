#!/usr/bin/env sh
set -eu

# pyexasol 3 reports usage on connect; a test run never does.
export EXASOL_TELEMETRY_DISABLE=true

if [ -n "${LUA_BIN:-}" ]; then
  lua_bin="$LUA_BIN"
elif command -v lua >/dev/null 2>&1; then
  lua_bin="lua"
elif command -v lua5.4 >/dev/null 2>&1; then
  lua_bin="lua5.4"
else
  echo "Lua 5.4 is required. Install it with 'brew install lua' or set LUA_BIN." >&2
  exit 2
fi

if [ -n "${LUAC_BIN:-}" ]; then
  luac_bin="$LUAC_BIN"
elif command -v luac >/dev/null 2>&1; then
  luac_bin="luac"
elif command -v luac5.4 >/dev/null 2>&1; then
  luac_bin="luac5.4"
else
  echo "Lua 5.4 compiler is required for script-body coverage." >&2
  exit 2
fi

LUAC_BIN="$luac_bin" "$lua_bin" tests/lua/run.lua "$@"
