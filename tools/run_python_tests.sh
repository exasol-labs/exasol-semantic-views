#!/usr/bin/env sh
# Database-free Python test suite with line-coverage enforcement.
#
# Runs each host-side test file under coverage.py, enforces the per-file
# thresholds in tests/python_coverage_thresholds.py, and fails if any file
# regresses. Mirrors tools/run_lua_tests.sh's discipline for Lua.
#
# The DB-backed verify_* scripts live in tools/run_smoke.sh; they are
# intentionally excluded from this suite (see OMIT_PATTERNS in the
# thresholds file).

set -eu

if [ -z "${PYTHON_BIN:-}" ]; then
  PYTHON_BIN="python3"
fi

TESTS="tests/test_osi_tool.py \
       tests/test_install.py \
       tests/test_release_notes.py \
       tests/test_sql_splitter.py \
       tests/test_property.py"

# Discard any prior .coverage file so a stale run does not lower thresholds
# below the honest baseline.
rm -f .coverage

FIRST=1
for TEST in $TESTS; do
  if [ "$FIRST" = "1" ]; then
    "$PYTHON_BIN" -m coverage run --source=tools --branch "$TEST"
    FIRST=0
  else
    "$PYTHON_BIN" -m coverage run --append --source=tools --branch "$TEST"
  fi
done

echo
"$PYTHON_BIN" - <<'PY'
import fnmatch, sys
from coverage import Coverage
from tests.python_coverage_thresholds import LINE_THRESHOLDS, OMIT_PATTERNS

cov = Coverage()
cov.load()
data = cov.get_data()

failures = 0
print("Python line coverage (unit-test surface)")
for path, threshold in sorted(LINE_THRESHOLDS.items()):
    _, statements, excluded, missing, _ = cov.analysis2(path)
    total = len(statements) - len(excluded)
    hit = total - len(missing)
    pct = 100.0 if total == 0 else hit * 100.0 / total
    marker = "OK  "
    if pct + 0.0001 < threshold:
        marker = "FAIL"
        failures += 1
    print(f"  {marker} {path:36s} {hit:4d}/{total:<4d} {pct:6.2f}% (minimum {threshold:.2f}%)")

# Also list any tools/*.py NOT covered by thresholds and NOT in OMIT_PATTERNS,
# so new modules can't sneak in unmeasured.
tracked = set(LINE_THRESHOLDS.keys())
def omitted(path):
    return any(fnmatch.fnmatch(path, pat) for pat in OMIT_PATTERNS)

untracked = []
for path in sorted(data.measured_files()):
    rel = path[path.find("tools/"):] if "tools/" in path else path
    if not rel.startswith("tools/"):
        continue
    if rel in tracked:
        continue
    if omitted(rel):
        continue
    untracked.append(rel)

if untracked:
    print()
    print("Untracked modules with measurements (add to LINE_THRESHOLDS or OMIT_PATTERNS):")
    for u in untracked:
        print(f"  {u}")
    failures += 1

print()
if failures:
    print(f"{failures} coverage failure(s).")
    sys.exit(1)
print("Python coverage: all thresholds met.")
PY
