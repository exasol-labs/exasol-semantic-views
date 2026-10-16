#!/usr/bin/env sh
# Static checks: Ruff and mypy for Python, Luacheck for lua/ and tests/lua/,
# ShellCheck for the shell entry points. The script bodies in
# lua/semantic_layer/scripts/ take their parameters as globals, so
# tools/dev/lint_script_bodies.py lints them with each script's signature.
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
run luacheck "$LUACHECK_BIN" --formatter plain --codes \
  --exclude-files "lua/semantic_layer/scripts/*.lua" -- lua tests/lua
run script-bodies "$PYTHON_BIN" tools/dev/lint_script_bodies.py "$LUACHECK_BIN"
run shellcheck "$SHELLCHECK_BIN" tools/*.sh

if [ -n "$failed" ]; then
  echo "static checks failed:$failed"
  exit 1
fi
echo "all static checks passed"
