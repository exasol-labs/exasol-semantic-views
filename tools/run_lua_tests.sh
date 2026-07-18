#!/usr/bin/env sh
set -eu

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

"$lua_bin" tests/lua/run.lua
