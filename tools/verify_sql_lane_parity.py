#!/usr/bin/env python3
"""One SQL lane: a redundant subquery never decides whether a statement works.

ESV compiles a statement two ways. The *whole-statement* lane reads a bare
`SELECT fields FROM SEMANTIC_X.OBJ` and plans it directly. The *expansion* lane
replaces the reference with `(<compiled SQL>) t0` and leaves the rest to Exasol.

They did not accept the same language, and nothing said so. `SELECT region FROM
SEMANTIC_SALES.SALES ORDER BY revenue DESC` was refused, while the identical
query wrapped in a pointless subquery ran -- because the wrapper pushed it into
the lane that could handle it. An author who happened to write the redundant
subquery got a working report; an author who wrote the obvious thing got a
refusal that named a construct SQL has had for forty years. Which lane you
landed in was invisible, so the workaround could not be discovered, only
stumbled upon.

The fix: the whole-statement lane falls through to expansion whenever it cannot
compile a statement itself. This verifier holds the resulting invariant, which
is the one that actually matters to a BI tool: **for every construct, the bare
form and the wrapped form agree** -- both return the same rows, or both refuse
with the same code. It asserts agreement rather than a hard-coded verdict, so a
future construct that becomes supported is still covered without an edit here.

Fallthrough may turn a refusal into a success. It must not turn one refusal into
a *different* refusal, with two exceptions that are decisions only the expansion
lane is positioned to make: composition it does not supervise (`_012`, `_013`)
and a model that does not vouch for what the statement reads (`_028`).
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


def outcome(con, sql: str):
    """Run a statement and reduce it to a comparable verdict.

    Either ("rows", <sorted rows>) or ("refused", <rule code>). A parse error
    with no rule code is its own verdict -- it is what B09 looked like, and it
    must never be what either lane produces.
    """
    try:
        rows = con.execute(sql).fetchall()
        return ("rows", sorted(tuple(str(value) for value in row) for row in rows))
    except Exception as exception:  # noqa: BLE001 -- the refusal is the result
        message = " ".join(str(exception).split())
        code = re.search(r"SEMANTIC_\w+_\d+", message)
        return ("refused", code.group(0) if code else f"NO-CODE: {message[:160]}")


# Each pair is the same question asked bare and wrapped. The wrapper is
# semantically a no-op -- `SELECT * FROM (<bare>)` -- so any disagreement is the
# lane split, not the query.
PAIRS = [
    ("ORDER BY a non-selected field",
     f"SELECT CUSTOMER_REGION FROM {OBJECT} ORDER BY TOTAL_REVENUE DESC"),
    ("LIMIT with OFFSET",
     f"SELECT CUSTOMER_REGION FROM {OBJECT} ORDER BY CUSTOMER_REGION LIMIT 2 OFFSET 1"),
    ("IN (subquery)",
     f"SELECT CUSTOMER_REGION FROM {OBJECT}"
     " WHERE CUSTOMER_REGION IN (SELECT REGION FROM MART.CUSTOMERS)"),
    ("NOT IN (subquery)",
     f"SELECT CUSTOMER_REGION FROM {OBJECT}"
     " WHERE CUSTOMER_REGION NOT IN (SELECT REGION FROM MART.CUSTOMERS WHERE REGION = 'South')"),
    ("correlated EXISTS",
     f"SELECT t0.CUSTOMER_REGION FROM {OBJECT} t0"
     " WHERE EXISTS (SELECT 1 FROM MART.CUSTOMERS c WHERE c.REGION = t0.CUSTOMER_REGION)"),
    ("arithmetic in the select list",
     f"SELECT TOTAL_REVENUE / 1000 FROM {OBJECT}"),
    ("CASE in the select list",
     f"SELECT CASE WHEN TOTAL_REVENUE > 0 THEN 1 ELSE 0 END FROM {OBJECT}"),
    ("SELECT DISTINCT",
     f"SELECT DISTINCT CUSTOMER_REGION FROM {OBJECT}"),
    ("a plain projection",
     f"SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM {OBJECT}"),
    ("an ordinary WHERE",
     f"SELECT CUSTOMER_REGION FROM {OBJECT} WHERE CUSTOMER_REGION = 'North'"),
    ("BETWEEN",
     f"SELECT CUSTOMER_REGION FROM {OBJECT} WHERE TOTAL_REVENUE BETWEEN 0 AND 99999999"),
    ("an unknown field",
     f"SELECT bogus_field FROM {OBJECT}"),
]

# Refusals the expansion lane is entitled to reach that the other cannot: they
# are judgements about composition and provenance, not about parsing.
EXPANSION_OWNED = {"SEMANTIC_QUERY_012", "SEMANTIC_QUERY_013", "SEMANTIC_QUERY_028"}

# Grouping a published object in its own query block groups an already-grouped
# result. Joining the lanes made this reachable -- expansion would have produced
# `SELECT region, COUNT(*) FROM (<compiled>) GROUP BY region`, valid SQL
# returning a count of groups. Each of these must refuse; the code may be the
# sharper one from whichever lane read the statement.
REAGGREGATION = [
    ("GROUP BY not covering the selected fields",
     f"SELECT CUSTOMER_REGION, PRODUCT_CATEGORY FROM {OBJECT} GROUP BY CUSTOMER_REGION"),
    ("GROUP BY a field that is not selected",
     f"SELECT CUSTOMER_REGION FROM {OBJECT} GROUP BY ORDER_STATUS"),
    ("COUNT(*) beside a grouped field",
     f"SELECT CUSTOMER_REGION, COUNT(*) FROM {OBJECT} GROUP BY CUSTOMER_REGION"),
    ("HAVING without GROUP BY",
     f"SELECT CUSTOMER_REGION FROM {OBJECT} HAVING TOTAL_REVENUE > 0"),
]

# Naming the grain explicitly is the supported way to aggregate a semantic
# result, and the guard above must not reach it: the aggregation is in the outer
# block, the reference in the inner one.
AGGREGATION_OVER_A_SUBQUERY = [
    ("COUNT(*) over a subquery",
     f"SELECT COUNT(*) FROM (SELECT t0.CUSTOMER_REGION FROM {OBJECT} t0) z"),
    ("GROUP BY over a subquery",
     f"SELECT r, COUNT(*) FROM (SELECT CUSTOMER_REGION AS r FROM {OBJECT}) z GROUP BY r"),
    ("MEASURE with an explicit GROUP BY",
     f"SELECT CUSTOMER_REGION, MEASURE(TOTAL_REVENUE) FROM {OBJECT}"
     " GROUP BY CUSTOMER_REGION"),
]

# Statements that reach Exasol and come back with Exasol's own message rather
# than a rule code. Every one is malformed or unsupported dialect, and Exasol
# names the specific problem ("object NONEXISTENT_COL not found", "non-negative
# integer value expected in LIMIT clause"), so none is a wrong *answer* -- but
# the layer used to recognise them and no longer does, because expansion hands
# anything it can rewrite to the database.
#
# This is a ratchet, not a target. It may shrink and may not grow: a change that
# turns a working statement into a raw error fails here. Deliberately not fixed
# by widening the field scan into WHERE and ORDER BY, because completing *that*
# keyword list is a treadmill where one miss refuses a valid query, which is
# worse than this.
#
# What changed for them is the position. Each of these used to be reported at a
# line that did not exist in the author's statement, because the spliced SQL
# moved everything after it down eight lines; the derived table is now emitted on
# one line, so the line Exasol names is one the author wrote. The column still
# counts the spliced characters, which inline rewriting cannot avoid.
# tools/verify_no_raw_parse_errors.py holds both halves of that.
KNOWN_RAW = [
    f"SELECT CUSTOMER_REGION FROM {OBJECT} ORDER BY 7",
    f"SELECT CUSTOMER_REGION FROM {OBJECT} ORDER BY nonexistent_col",
    f"SELECT CUSTOMER_REGION FROM {OBJECT} WHERE nonexistent_col = 1",
    f"SELECT CUSTOMER_REGION FROM {OBJECT} WHERE TOTAL_REVENUE >",
    f"SELECT CUSTOMER_REGION FROM {OBJECT} LIMIT -1",
    f"SELECT CUSTOMER_REGION FROM {OBJECT} FOR UPDATE",
    f"SELECT SUM(CUSTOMER_REGION) FROM {OBJECT}",
    f"SELECT CUSTOMER_REGION FROM {OBJECT} WHERE CUSTOMER_REGION IN ()",
    f"SELECT DISTINCT ON (CUSTOMER_REGION) CUSTOMER_REGION FROM {OBJECT}",
]


def main() -> int:
    con = connect()
    con.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")

    for name, bare in PAIRS:
        wrapped = f"SELECT * FROM ({bare}) esv_wrapper"
        bare_outcome = outcome(con, bare)
        wrapped_outcome = outcome(con, wrapped)

        if bare_outcome[0] == "refused" and bare_outcome[1].startswith("NO-CODE"):
            fail(f"{name}: bare form emits a rule code",
                 f"raw parse error instead: {bare_outcome[1]}")
            continue

        # A wrapper may legitimately change row *order* (the outer SELECT has no
        # ORDER BY of its own), so compare rows as sorted multisets -- which
        # `outcome` already did -- and never as sequences.
        if bare_outcome == wrapped_outcome:
            detail = (f"{len(bare_outcome[1])} rows" if bare_outcome[0] == "rows"
                      else bare_outcome[1])
            ok(f"{name}: bare and wrapped agree", detail)
        else:
            fail(f"{name}: bare and wrapped agree",
                 f"bare {bare_outcome[0]} {str(bare_outcome[1])[:70]} vs "
                 f"wrapped {wrapped_outcome[0]} {str(wrapped_outcome[1])[:70]}")

    # Fallthrough must not downgrade a precise refusal into a vague one. The
    # unknown field is the case that caught this: the whole-statement lane says
    # `Unknown semantic field: bogus_field. Did you mean: ...?` and expansion,
    # seeing no published column, would say only "cannot tell which columns this
    # needs". The better message has to survive.
    unknown = outcome(con, f"SELECT bogus_field FROM {OBJECT}")
    if unknown == ("refused", "SEMANTIC_QUERY_020"):
        ok("an unknown field keeps the naming refusal", "SEMANTIC_QUERY_020")
    else:
        fail("an unknown field keeps the naming refusal",
             f"got {unknown!r}, so fallthrough shadowed the precise message")

    # Composition stays refused through both lanes -- the point of the guard is
    # that it cannot be dodged by choosing a form.
    composed = f"""SELECT t0.CUSTOMER_REGION FROM {OBJECT} t0
        JOIN MART.CUSTOMERS c ON c.REGION = t0.CUSTOMER_REGION"""
    composed_outcome = outcome(con, composed)
    if composed_outcome[0] == "refused" and composed_outcome[1] in EXPANSION_OWNED:
        ok("composition is refused in both lanes", composed_outcome[1])
    else:
        fail("composition is refused in both lanes", f"got {composed_outcome!r}")

    # The guard below is behind the same opt-in as the join guard, so these
    # checks only mean anything while this model has not opted in. An earlier
    # verifier turns it on and back off again; if it ever leaves it on, say that
    # rather than reporting the guard as broken.
    opted_in = con.execute(
        "SELECT ALLOW_DERIVED_COMPOSITION FROM SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL"
        " WHERE MODEL_NAME = 'sales'").fetchone()
    if opted_in is not None and opted_in[0]:
        fail("re-aggregation checks have their precondition",
             "the sales model has SET_MODEL_DERIVED_COMPOSITION on, which accepts"
             " ordinary-SQL semantics -- these checks cannot run")
        REAGGREGATION.clear()

    for name, sql in REAGGREGATION:
        got = outcome(con, sql)
        if got[0] == "refused" and not got[1].startswith("NO-CODE"):
            ok(f"{name} is refused", got[1])
        else:
            fail(f"{name} is refused",
                 f"got {str(got)[:90]} -- an already-grouped result was grouped again")

    for name, sql in AGGREGATION_OVER_A_SUBQUERY:
        got = outcome(con, sql)
        if got[0] == "rows":
            ok(f"{name} still works", f"{len(got[1])} rows")
        else:
            fail(f"{name} still works",
                 f"got {str(got)[:90]} -- the guard reached the supported form")

    # The ratchet. Growing it means a statement the layer used to diagnose now
    # reaches Exasol unrecognised.
    improved = []
    for sql in KNOWN_RAW:
        kind, verdict = outcome(con, sql)
        # A pinned statement that starts returning rows is an improvement too,
        # and `verdict` is a row list there rather than a string -- so ask about
        # the kind first.
        if kind == "rows" or not verdict.startswith("NO-CODE"):
            improved.append(sql)
    if improved:
        ok(f"{len(improved)} of {len(KNOWN_RAW)} statement(s) no longer reach"
           " Exasol unrecognised",
           "shrink KNOWN_RAW in this file to lock the improvement in")

    if failures:
        print(f"\n{len(failures)} failure(s): " + ", ".join(failures))
        return 1
    print("\nall lane-parity checks passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
