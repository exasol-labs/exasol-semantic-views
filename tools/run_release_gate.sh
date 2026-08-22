#!/usr/bin/env sh
# Release gate: run the full Nano smoke suite AND a wide fuzz campaign.
#
# Intent: this is the pre-release verification, not the per-check gate. The
# fuzz campaign here is deliberately large enough to cost minutes so that
# nobody is tempted to add it to run_nano_smoke.sh. Run it before every
# major release, after any change to the compiler, planner, or admin scripts
# whose blast radius is broad.
#
# Two knobs (environment variables):
#   FUZZ_SEEDS   — space-separated seeds. Default "0 1 2 7 42 99 123 456".
#   FUZZ_CASES   — cases per (seed, oracle) pair. Default 250.
#
# A divergence in either fuzz oracle exits non-zero AFTER the smoke suite has
# run, so callers see both the smoke summary and the fuzz reproduction.

set -eu

if [ -z "${PYTHON_BIN:-}" ]; then
  if [ -x ../exasol-json-tables/.venv/bin/python ]; then
    PYTHON_BIN="../exasol-json-tables/.venv/bin/python"
  else
    PYTHON_BIN="python3"
  fi
fi

FUZZ_SEEDS="${FUZZ_SEEDS:-0 1 2 7 42 99 123 456}"
FUZZ_CASES="${FUZZ_CASES:-250}"

echo "==> Nano smoke suite"
sh tools/run_nano_smoke.sh

echo
echo "==> Compiler fuzz campaign (seeds='$FUZZ_SEEDS' cases=$FUZZ_CASES)"
FUZZ_FAILURES=0
for FUZZ_SEED in $FUZZ_SEEDS; do
  for FUZZ_ORACLE in differential tlp; do
    printf "  seed=%s oracle=%s " "$FUZZ_SEED" "$FUZZ_ORACLE"
    if "$PYTHON_BIN" tools/fuzz_semantic_differential.py \
         --oracle "$FUZZ_ORACLE" --seed "$FUZZ_SEED" --cases "$FUZZ_CASES" \
         > /tmp/fuzz.$$.out 2>&1
    then
      echo "OK ($FUZZ_CASES cases)"
    else
      echo "FAIL — reproduction below"
      cat /tmp/fuzz.$$.out
      FUZZ_FAILURES=$((FUZZ_FAILURES + 1))
    fi
    rm -f /tmp/fuzz.$$.out
  done
done

echo
if [ "$FUZZ_FAILURES" -gt 0 ]; then
  echo "RELEASE GATE FAILED: $FUZZ_FAILURES fuzz campaign(s) diverged."
  exit 1
fi
echo "RELEASE GATE PASSED: smoke + fuzz all green."
