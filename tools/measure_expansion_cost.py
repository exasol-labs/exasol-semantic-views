#!/usr/bin/env python3
"""Regenerate the per-shape cost of reference expansion.

Not a verifier, and deliberately not in the smoke suite: it measures rather than
asserts, and a threshold on a wall-clock median would be flaky on a laptop.

It exists because a single number — "+0.9 ms on a compile" — was quoted in the
CHANGELOG, named no hardware, and stayed there while being about 30x low for the
shapes a BI tool actually emits. A measurement nobody can reproduce cheaply is a
measurement that goes stale silently, so this prints the table that
`docs/bi-tools.md` and the CHANGELOG quote, with the machine it came from.

    python3 tools/measure_expansion_cost.py [rounds]

Read the *differences*, not the absolutes: the baseline moves with the hardware
and with what else the release is doing per statement.
"""

from __future__ import annotations

import platform
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

OBJECT = "SEMANTIC_SALES.SALES"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"

# The last two are the shapes the single-lane change made work bare. They are
# here because they are the expensive ones, and nothing measured them when that
# change shipped.
SHAPES = [
    ("bare", f"SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM {OBJECT}"),
    ("aliased", f"SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM {OBJECT} t0"),
    ("TopN", f"SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM {OBJECT}"
             " ORDER BY 2 DESC LIMIT 5"),
    ("subquery", f"SELECT x.CUSTOMER_REGION, x.TOTAL_REVENUE FROM"
                 f" (SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM {OBJECT} t0) x"),
    ("CTE", f"WITH z AS (SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM {OBJECT} t0)"
            " SELECT z.CUSTOMER_REGION, z.TOTAL_REVENUE FROM z"),
    ("arithmetic (bare)", f"SELECT CUSTOMER_REGION, TOTAL_REVENUE / 1000 FROM {OBJECT}"),
    ("ORDER BY unselected (bare)",
     f"SELECT CUSTOMER_REGION FROM {OBJECT} ORDER BY TOTAL_REVENUE DESC"),
    # Refused, and included to show where the cost is: a statement the
    # whole-statement path declines *early* never pays for a catalog load.
    ("composed (refused early)",
     f"SELECT t0.CUSTOMER_REGION FROM {OBJECT} t0"
     " JOIN MART.CUSTOMERS c ON c.REGION = t0.CUSTOMER_REGION"),
]


def machine() -> str:
    try:
        cpu = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"],
                             capture_output=True, text=True, timeout=5).stdout.strip()
    except Exception:  # noqa: BLE001 -- not every platform has sysctl
        cpu = platform.processor() or "unknown CPU"
    return f"{cpu}, {platform.system()} {platform.release()}"


def main() -> int:
    rounds = int(sys.argv[1]) if len(sys.argv) > 1 else 25
    con = connect()
    version = con.execute(
        "SELECT PARAM_VALUE FROM SYS.EXA_METADATA"
        " WHERE PARAM_NAME = 'databaseProductVersion'").fetchone()[0]
    con.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")

    def run(sql: str) -> float:
        start = time.perf_counter()
        try:
            con.execute(sql).fetchall()
        except Exception:  # noqa: BLE001 -- a refusal is a timed outcome too
            pass
        return (time.perf_counter() - start) * 1000

    for _, sql in SHAPES:          # warm the compile cache for every shape
        for _ in range(3):
            run(sql)
    con.commit()

    # Interleaved, so drift during the run lands on every shape rather than on
    # whichever happened to be measured last.
    samples: dict[str, list[float]] = {name: [] for name, _ in SHAPES}
    for _ in range(rounds):
        for name, sql in SHAPES:
            samples[name].append(run(sql))
    con.commit()

    base = statistics.median(samples["bare"])
    print(f"Exasol {version}; {machine()}")
    print(f"{rounds} rounds, interleaved, all cache-warm, preprocessor on\n")
    print(f"| shape | median | vs bare |")
    print(f"|---|---|---|")
    for name, _ in SHAPES:
        median = statistics.median(samples[name])
        delta = median - base
        against = "—" if name == "bare" else f"{delta:+.1f} ms"
        print(f"| {name} | {median:.1f} ms | {against} |")
    print("\nRead the differences, not the absolutes.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
