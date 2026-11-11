#!/usr/bin/env sh
# Release gate: run the full system suite AND a wide fuzz campaign.
#
# Intent: this is the pre-release verification, not the per-check gate. The
# fuzz campaign here is deliberately large enough to cost minutes so that
# nobody is tempted to add it to run_system_tests.sh. Run it before every
# major release, after any change to the compiler, planner, or admin scripts
# whose blast radius is broad.
#
# Two knobs (environment variables):
#   FUZZ_SEEDS   — space-separated seeds. Default "0 1 2 7 42 99 123 456".
#   FUZZ_CASES   — cases per (seed, generator, oracle) campaign. Default 250.
#
# Pass --fuzz-only when another CI job owns the system suite, whether it runs
# in parallel for PRs or finished first for a release. A failed campaign exits
# non-zero after all seeds have run.

set -eu

# pyexasol 3 reports usage on connect; a test run never does.
export EXASOL_TELEMETRY_DISABLE=true

if [ -z "${PYTHON_BIN:-}" ]; then
  if [ -x ../exasol-json-tables/.venv/bin/python ]; then
    PYTHON_BIN="../exasol-json-tables/.venv/bin/python"
  else
    PYTHON_BIN="python3"
  fi
fi

FUZZ_SEEDS="${FUZZ_SEEDS:-0 1 2 7 42 99 123 456}"
FUZZ_CASES="${FUZZ_CASES:-250}"

case "${1:-}" in
  "")
    echo "==> system suite"
    sh tools/run_system_tests.sh
    ;;
  --fuzz-only)
    shift
    ;;
  *)
    echo "Usage: sh tools/run_release_gate.sh [--fuzz-only]" >&2
    exit 2
    ;;
esac

if [ "$#" -ne 0 ]; then
  echo "Usage: sh tools/run_release_gate.sh [--fuzz-only]" >&2
  exit 2
fi

echo
echo "==> Compiler fuzz campaign (seeds='$FUZZ_SEEDS' cases=$FUZZ_CASES)"
FUZZ_FAILURES=0
run_campaign() {
  FUZZ_GENERATOR=$1
  FUZZ_ORACLE=$2
  printf "  seed=%s generator=%s oracle=%s " "$FUZZ_SEED" "$FUZZ_GENERATOR" "$FUZZ_ORACLE"
  if "$PYTHON_BIN" tests/fuzz/run_semantic_fuzz.py \
       --generator "$FUZZ_GENERATOR" --oracle "$FUZZ_ORACLE" \
       --seed "$FUZZ_SEED" --cases "$FUZZ_CASES" \
       > /tmp/fuzz.$$.out 2>&1
  then
    echo "OK ($FUZZ_CASES cases)"
  else
    echo "FAIL — reproduction below"
    cat /tmp/fuzz.$$.out
    FUZZ_FAILURES=$((FUZZ_FAILURES + 1))
  fi
  rm -f /tmp/fuzz.$$.out
}

for FUZZ_SEED in $FUZZ_SEEDS; do
  run_campaign handwritten differential
  run_campaign handwritten tlp
  run_campaign sqlglot contract
done

echo
if [ "$FUZZ_FAILURES" -gt 0 ]; then
  echo "FUZZ CAMPAIGN FAILED: $FUZZ_FAILURES campaign(s) diverged."
  exit 1
fi
echo "FUZZ CAMPAIGN PASSED."
