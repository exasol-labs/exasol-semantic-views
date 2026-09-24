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

Read the *ratios* first and the differences second; the absolutes are the least
portable thing here. The baseline moves with the hardware and with what else the
release is doing per statement, and an external re-measurement of this table
found every absolute 0.71-0.82x of the published one while the relative
structure reproduced exactly -- so a reader comparing milliseconds concludes the
table is wrong, and a reader comparing ratios finds the one row that really is.
"""

from __future__ import annotations

import platform
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

OBJECT = "SEMANTIC_SALES.SALES"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
CODE = re.compile(r"SEMANTIC_[A-Z]+_\d+")

# Ordered so each expensive shape sits next to the cheap way of writing the same
# thing: the bare/wrapped pairs are where the cost actually lives, and a single
# row can only be read against its partner.
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
    # The wrapped forms of the two rows above. They are what substantiates the
    # claim in docs/bi-tools.md 3 that wrapping the object is several times
    # faster than the bare form, which was asserted there without a number.
    ("arithmetic (wrapped)",
     f"SELECT x.CUSTOMER_REGION, x.TOTAL_REVENUE / 1000 FROM"
     f" (SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM {OBJECT} t0) x"),
    ("ORDER BY unselected (wrapped)",
     f"SELECT x.CUSTOMER_REGION FROM"
     f" (SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM {OBJECT} t0) x"
     " ORDER BY x.TOTAL_REVENUE DESC"),
    # Refused, and the pair is the point. This row was published as "refused
    # early" and *below* the bare baseline, on the reasoning that a refusal
    # precedes the catalog read. It does not: reference expansion has to resolve
    # the model and the object's columns before it can know the reference is a
    # semantic object at all, and only then can it refuse. The bare form also
    # pays the whole-statement lane's late failure first, which is the gap
    # between these two rows.
    ("composed (refused)",
     f"SELECT t0.CUSTOMER_REGION FROM {OBJECT} t0"
     " JOIN MART.CUSTOMERS c ON c.REGION = t0.CUSTOMER_REGION"),
    ("composed (wrapped, refused)",
     f"SELECT y.R, SUM(y.V) FROM"
     f" (SELECT t0.CUSTOMER_REGION AS R, t0.TOTAL_REVENUE AS V FROM {OBJECT} t0) y"
     " JOIN MART.CUSTOMERS c ON c.REGION = y.R GROUP BY 1"),
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

    # The outcome is carried into the table beside the timing. A refused row that
    # quietly started compiling -- or a working row that started being refused --
    # would make its number mean something else entirely, and a bare median says
    # nothing about which happened.
    outcomes: dict[str, str] = {}

    def run(name: str, sql: str) -> float:
        start = time.perf_counter()
        try:
            con.execute(sql).fetchall()
            outcomes[name] = "OK"
        except Exception as refusal:  # noqa: BLE001 -- a refusal is a timed outcome too
            found = CODE.search(" ".join(str(refusal).split()))
            outcomes[name] = found.group(0) if found else "raw error"
        return (time.perf_counter() - start) * 1000

    for name, sql in SHAPES:       # warm the compile cache for every shape
        for _ in range(3):
            run(name, sql)
    con.commit()

    # Interleaved, so drift during the run lands on every shape rather than on
    # whichever happened to be measured last.
    samples: dict[str, list[float]] = {name: [] for name, _ in SHAPES}
    for _ in range(rounds):
        for name, sql in SHAPES:
            samples[name].append(run(name, sql))
    con.commit()

    base = statistics.median(samples["bare"])
    print(f"Exasol {version}; {machine()}")
    print(f"{rounds} rounds, interleaved, all cache-warm, preprocessor on\n")
    print("| shape | outcome | median | vs bare | x bare |")
    print("|---|---|---|---|---|")
    for name, _ in SHAPES:
        median = statistics.median(samples[name])
        against = "—" if name == "bare" else f"{median - base:+.1f} ms"
        ratio = "—" if name == "bare" else f"{median / base:.2f}x"
        print(f"| {name} | {outcomes[name]} | {median:.1f} ms | {against} | {ratio} |")
    print("\nRead the ratios first: they carry between machines, the milliseconds do not.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
