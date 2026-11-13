#!/usr/bin/env sh
set -eu

# pyexasol 3 reports usage on connect; a test run never does.
export EXASOL_TELEMETRY_DISABLE=true

# Lua 5.4, as CI installs it, and not whichever `lua` comes first: script-body
# coverage counts the active lines in the compiler's listing, and another
# version lists some lines differently, so a floor measured under 5.4 can fail
# under 5.5 (publish_model.lua counts 215 lines under 5.4 and 216 under 5.5)
# with no test or script changed. Homebrew's `lua` is 5.5 now; `lua@5.4` is
# keg-only, so it is looked for there too.
brew_lua_bin=""
if command -v brew >/dev/null 2>&1; then
  brew_lua_bin="$(brew --prefix lua@5.4 2>/dev/null || true)/bin"
fi

is_lua54() {
  "$1" -v 2>&1 | grep -q '^Lua 5\.4'
}

pick() {
  # $1: the versioned name (lua5.4); $2: the plain name (lua).
  for candidate in "$1" "${brew_lua_bin}/$1"; do
    if command -v "$candidate" >/dev/null 2>&1; then
      echo "$candidate"
      return 0
    fi
  done
  if command -v "$2" >/dev/null 2>&1; then
    echo "$2"
    return 0
  fi
  return 1
}

need_54() {
  echo "Lua 5.4 is required, as in CI; found: $1." >&2
  echo "Install it with 'brew install lua@5.4' (or 'apt-get install lua5.4')," >&2
  echo "or set LUA_BIN and LUAC_BIN to a Lua 5.4 interpreter and compiler." >&2
  exit 2
}

lua_bin="${LUA_BIN:-$(pick lua5.4 lua || true)}"
if [ -z "$lua_bin" ]; then
  need_54 "no Lua interpreter"
fi
if ! is_lua54 "$lua_bin"; then
  need_54 "$("$lua_bin" -v 2>&1 | head -n 1) at $lua_bin"
fi

luac_bin="${LUAC_BIN:-$(pick luac5.4 luac || true)}"
if [ -z "$luac_bin" ]; then
  need_54 "no Lua compiler"
fi
if ! is_lua54 "$luac_bin"; then
  need_54 "$("$luac_bin" -v 2>&1 | head -n 1) at $luac_bin"
fi

LUAC_BIN="$luac_bin" "$lua_bin" tests/lua/run.lua "$@"
