#!/usr/bin/env python3
"""A valid statement never fails in SQL the author cannot see.

Reference expansion splices compiled SQL into the middle of somebody else's
statement. Two things can then go wrong, and both did.

The first is that the spliced text does not parse, so an ordinary statement
comes back as a syntax error. `SELECT region, revenue / 1000 FROM obj` was
reported as `syntax error, unexpected invalid token ... [line 10, column 3]` --
for a statement written on one line. The construct was fine; the SQL the layer
built around it was not. That is BUG-B09, and the first half of this verifier
holds the invariant it violated: **a valid statement either answers or is
refused by a rule code, never by a parser.** It is written as a corpus rather
than as the three reported cases, because the defect was never about arithmetic
-- it was about what the layer emits, and the next construct to hit it will be
one nobody listed.

The second is subtler and outlived the first. The compiled SQL is eight or so
lines, so everything after the splice moved down by that many lines, and Exasol
reported failures at `line 10` of a one-line statement. A position that points
into text the author never wrote is worse than no position: it sends the reader
to look at the wrong thing, and there is nothing at line 10 to find. The second
half holds the fix -- `sql_text.flatten_lines` puts the derived table on one
line, so line numbers survive the rewrite.

What this deliberately does not claim: for genuinely malformed SQL the *column*
still counts characters that include the spliced text, so it can point past the
end of the author's line. Inline rewriting cannot preserve both, and the line is
the half a reader navigates by.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
OBJECT = "SEMANTIC_SALES.SALES"
failures: list[str] = []


def ok(name: str, detail: str = "") -> None:
    print(f"ok {name}" + (f": {detail}" if detail else ""))


def fail(name: str, detail: str) -> None:
    failures.append(name)
    print(f"FAIL {name}: {detail}")


# Valid SQL over a published object. Every one must answer or carry a rule code.
# The first three are B09's report verbatim; the fourth is B10's.
VALID = [
    "SELECT CUSTOMER_REGION, TOTAL_REVENUE / 1000 FROM {o}",
    "SELECT CUSTOMER_REGION, CASE WHEN TOTAL_REVENUE > 95000 THEN 'big'"
    " ELSE 'small' END FROM {o}",
    "SELECT CUSTOMER_REGION, PRODUCT_CATEGORY, TOTAL_REVENUE FROM {o}"
    " GROUP BY CUSTOMER_REGION",
    "SELECT DISTINCT CUSTOMER_REGION FROM {o}",
    "SELECT CUSTOMER_REGION FROM {o}",
    "SELECT * FROM {o}",
    "SELECT CUSTOMER_REGION FROM {o} WHERE CUSTOMER_REGION = 'North'",
    "SELECT CUSTOMER_REGION FROM {o} WHERE TOTAL_REVENUE BETWEEN 0 AND 9999999",
    "SELECT CUSTOMER_REGION FROM {o} ORDER BY TOTAL_REVENUE DESC",
    "SELECT CUSTOMER_REGION FROM {o} ORDER BY CUSTOMER_REGION LIMIT 2 OFFSET 1",
    "SELECT CUSTOMER_REGION FROM {o} WHERE CUSTOMER_REGION IN"
    " (SELECT REGION FROM MART.CUSTOMERS)",
    "SELECT t0.CUSTOMER_REGION FROM {o} t0 WHERE EXISTS"
    " (SELECT 1 FROM MART.CUSTOMERS c WHERE c.REGION = t0.CUSTOMER_REGION)",
    "SELECT UPPER(CUSTOMER_REGION) FROM {o}",
    "SELECT CUSTOMER_REGION || '!' FROM {o}",
    "SELECT CAST(TOTAL_REVENUE AS VARCHAR(30)) FROM {o}",
    "SELECT ROW_NUMBER() OVER (ORDER BY TOTAL_REVENUE) FROM {o}",
    "SELECT COUNT(*) FROM (SELECT t0.CUSTOMER_REGION FROM {o} t0) z",
    "WITH x AS (SELECT CUSTOMER_REGION FROM {o}) SELECT * FROM x",
    "SELECT CUSTOMER_REGION FROM {o} UNION ALL SELECT CUSTOMER_REGION FROM {o}",
    "SELECT CUSTOMER_REGION FROM {o} INTERSECT SELECT CUSTOMER_REGION FROM {o}",
    "SELECT CUSTOMER_REGION AS r FROM {o} ORDER BY r",
    "SELECT CUSTOMER_REGION FROM {o} WHERE ORDER_MONTH > DATE '2020-01-01'",
    "SELECT CUSTOMER_REGION, MEASURE(TOTAL_REVENUE) FROM {o} GROUP BY CUSTOMER_REGION",
    "SELECT CUSTOMER_REGION FROM {o} ORDER BY 1",
    "SELECT CUSTOMER_REGION FROM {o} LIMIT 0",
    # Multi-line, because the line-shift defect only shows once a statement has
    # more than one line to get wrong.
    "SELECT CUSTOMER_REGION,\n       TOTAL_REVENUE\n  FROM {o}\n ORDER BY 1",
]

# Malformed or unsupported. These are Exasol's to report -- but whatever it says
# must point at a line the author actually wrote.
MALFORMED = [
    "SELECT CUSTOMER_REGION FROM {o} ORDER BY 7",
    "SELECT CUSTOMER_REGION FROM {o} ORDER BY nonexistent_col",
    "SELECT CUSTOMER_REGION FROM {o} WHERE nonexistent_col = 1",
    "SELECT CUSTOMER_REGION FROM {o} WHERE TOTAL_REVENUE >",
    "SELECT CUSTOMER_REGION FROM {o} LIMIT -1",
    "SELECT CUSTOMER_REGION FROM {o} FOR UPDATE",
    "SELECT CUSTOMER_REGION FROM {o} WHERE CUSTOMER_REGION IN ()",
    "SELECT DISTINCT ON (CUSTOMER_REGION) CUSTOMER_REGION FROM {o}",
    # Multi-line: the error belongs on line 3, and used to be reported on line 12.
    "SELECT CUSTOMER_REGION\n  FROM {o}\n ORDER BY nonexistent_col",
]

CODE = re.compile(r"SEMANTIC_[A-Z]+_\d+")
POSITION = re.compile(r"\[line (\d+), column (\d+)\]")


def run(con, sql: str):
    try:
        con.execute(sql).fetchall()
        return None
    except Exception as exception:  # noqa: BLE001 -- the refusal is the result
        return " ".join(str(exception).split())


def main() -> int:
    con = connect()
    con.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")

    unparsed = []
    for template in VALID:
        sql = template.format(o=OBJECT)
        message = run(con, sql)
        if message is not None and not CODE.search(message):
            unparsed.append((sql, message))
    if unparsed:
        for sql, message in unparsed:
            fail("a valid statement answers or carries a rule code",
                 f"{sql.splitlines()[0][:70]}... -> {message[:110]}")
    else:
        ok(f"all {len(VALID)} valid statements answer or carry a rule code")

    misplaced = []
    for template in MALFORMED:
        sql = template.format(o=OBJECT)
        lines = sql.count("\n") + 1
        message = run(con, sql)
        if message is None or CODE.search(message):
            continue          # answered, or refused by the layer -- no position to check
        position = POSITION.search(message)
        if position is not None and int(position.group(1)) > lines:
            misplaced.append((sql, int(position.group(1)), lines))
    if misplaced:
        for sql, line, lines in misplaced:
            fail("a parser error points at a line the author wrote",
                 f"reported line {line} for a {lines}-line statement:"
                 f" {sql.splitlines()[0][:60]}")
    else:
        ok(f"every parser error over {len(MALFORMED)} malformed statements"
           " points at a real line")

    if failures:
        print(f"\n{len(failures)} failure(s)")
        return 1
    print("\ngenerated SQL parses, and positions survive the rewrite")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
