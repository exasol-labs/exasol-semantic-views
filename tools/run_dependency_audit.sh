#!/usr/bin/env sh
set -eu

export EXASOL_TELEMETRY_DISABLE=true

PIP_AUDIT_BIN="${PIP_AUDIT_BIN:-pip-audit}"
"$PIP_AUDIT_BIN" --strict \
  --requirement tools/requirements-osi.txt \
  --requirement tools/requirements-static.txt
