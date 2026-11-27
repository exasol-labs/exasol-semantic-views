"""Per-file Python line-coverage thresholds enforced by
`tools/run_python_tests.sh`.

Same discipline as `tests/lua/coverage_thresholds.lua`: raise a threshold
whenever coverage grows; do not lower one to merge.

Only `tools/*.py` files that are exercised by DB-free unit tests appear here.
The many `verify_*.py` integration scripts are covered by
`tools/run_system_tests.sh` against a real database, not by coverage.py — that
distinction is why they're excluded via `omit_patterns` below rather than
appearing here with 0%.

Baselines captured 2026-08-22 from a fresh run of the four database-free
test files plus `tests/unit/test_property.py`; treat these as the point-of-truth
we want to hold in place, not as aspirational targets. `tools/install.py`
ratcheted 2026-08-23 with the build-provenance helpers, and again 2026-08-24
alongside `tools/semantic_client.py`, whose result mapping is now unit-tested in
`tests/unit/test_semantic_client.py`. Ratcheted again 2026-08-25 with the packager
signature-coverage, main-chunk-local ceiling, and packager-output formatting
tests -- the last of which covers reformatting that had never executed.
"""

from __future__ import annotations

LINE_THRESHOLDS: dict[str, float] = {
    "tools/semantic_client.py": 44.7,
    "tools/install.py":         58.39,
    "tools/osi.py":             59.8,
    "tools/run_sql_files.py":   62.3,
    "tools/release_notes.py":   72.0,
    # Values floored to nearest 0.1 pp below the actual observed percentage so
    # display-rounded floats (e.g. `48/77 × 100 = 62.337662…` displaying as
    # `62.34`) don't trip the gate on unchanged code.
}

# Tools outside the unit-coverage gate, including live integration scripts and
# standalone build and static-check utilities.
OMIT_PATTERNS: list[str] = [
    "tests/fuzz/*.py",
    "tools/import_databricks.py",
    "tools/package_lua_scripts.py",
    "tools/check_lua_syntax.py",         # static check, exercised directly
    "tools/lua_runtime.py",              # bootstrap utility; validated through its callers
    "tools/dev/*.py",                    # developer helpers: lint, live measurement
    "tools/dev/user_studies/*.py",       # the simulated user-study harness
]
