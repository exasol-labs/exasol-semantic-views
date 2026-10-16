#!/usr/bin/env sh
# Static checks: Ruff and mypy for Python, Luacheck for lua/, tests/lua/ and
# the Lua embedded in sql/install/, ShellCheck for the shell entry points.
# Configuration lives in pyproject.toml and .luacheckrc. Every check runs, and
# the script fails if any of them did.
#
# Tools: pip install -r tools/requirements-static.txt, luarocks install
# luacheck 1.2.0, and shellcheck from your package manager. Override the
# binaries with PYTHON_BIN, LUACHECK_BIN and SHELLCHECK_BIN.

set -u

# pyexasol 3 reports usage on connect; a test run never does.
export EXASOL_TELEMETRY_DISABLE=true

PYTHON_BIN="${PYTHON_BIN:-python3}"
LUACHECK_BIN="${LUACHECK_BIN:-luacheck}"
SHELLCHECK_BIN="${SHELLCHECK_BIN:-shellcheck}"
failed=""

run() {
  label="$1"
  shift
  echo "== $label"
  if ! "$@"; then
    failed="$failed $label"
  fi
}

run ruff "$PYTHON_BIN" -m ruff check tools tests
run mypy "$PYTHON_BIN" -m mypy
run luacheck "$LUACHECK_BIN" --formatter plain --codes lua tests/lua
run embedded-lua "$PYTHON_BIN" tools/dev/lint_embedded_lua.py "$LUACHECK_BIN"
run shellcheck "$SHELLCHECK_BIN" tools/*.sh

if [ -n "$failed" ]; then
  echo "static checks failed:$failed"
  exit 1
fi
echo "all static checks passed"
