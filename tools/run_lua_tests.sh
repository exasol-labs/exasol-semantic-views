#!/usr/bin/env sh
set -eu

# pyexasol 3 reports usage on connect; a test run never does.
export EXASOL_TELEMETRY_DISABLE=true

# Lua 5.5, as CI builds it (.github/actions/setup-lua), and not whichever `lua`
# comes first: script-body coverage counts the active lines in the compiler's
# listing, and another version lists some lines differently, so a floor
# measured under one can fail under another with no test or script changed
# (publish_model.lua counts 215 lines under 5.4 and 216 under 5.5).
is_lua55() {
  "$1" -v 2>&1 | grep -q '^Lua 5\.5'
}

pick() {
  # $1: the versioned name (lua5.5); $2: the plain name (lua).
  for candidate in "$1" "$2"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  return 1
}

need_55() {
  echo "Lua 5.5 is required, as in CI; found: $1." >&2
  echo "Install it with 'brew install lua', or build it from https://www.lua.org/ftp/," >&2
  echo "or set LUA_BIN and LUAC_BIN to a Lua 5.5 interpreter and compiler." >&2
  exit 2
}

lua_bin="${LUA_BIN:-$(pick lua5.5 lua || true)}"
if [ -z "$lua_bin" ]; then
  need_55 "no Lua interpreter"
fi
if ! is_lua55 "$lua_bin"; then
  need_55 "$("$lua_bin" -v 2>&1 | head -n 1) at $lua_bin"
fi

luac_bin="${LUAC_BIN:-$(pick luac5.5 luac || true)}"
if [ -z "$luac_bin" ]; then
  need_55 "no Lua compiler"
fi
if ! is_lua55 "$luac_bin"; then
  need_55 "$("$luac_bin" -v 2>&1 | head -n 1) at $luac_bin"
fi

LUAC_BIN="$luac_bin" "$lua_bin" tests/lua/run.lua "$@"
