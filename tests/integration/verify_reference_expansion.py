#!/usr/bin/env python3
"""BI-generated SQL is accepted by expanding the reference, and composition is refused.

The problem. A BI tool almost never emits `SELECT fields FROM object`. It emits
the object wrapped in something: a TopN wrapper, a CTE with outer aggregation, a
subquery, a union, a window, arithmetic in the select list, `COUNT(*)`. ESV
compiled the *whole statement* or refused it, so most of that was refused.

The fix is to compile the *reference* instead: replace `SEMANTIC_X.OBJ t0` with
`(<compiled SQL>) t0` and leave everything around it to Exasol, which already
handles joins, CTEs, unions and windows natively.

What that buys, and what it costs. It makes the semantic result a derived table,
and ordinary SQL can then join it to another relation, repeat its rows, and
re-aggregate the repeats into a wrong number. This verifier demonstrates that
arithmetic rather than describing it: North is 3635, and the same query across a
join re-aggregates to 7270. So composition is refused by default, and a
deployment that wants ordinary-SQL semantics opts in per model and is told what
it is accepting.

Projection inference is the correctness surface, so it refuses rather than
guesses. An earlier prototype fell back to "all columns" when it could not tell
and returned seven rows where three were correct -- with correct totals, which
is the most dangerous shape of wrong, because the number a reviewer checks first
agrees.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

MODEL = "sales"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
TRUTH = {("North", "3635"), ("South", "135"), ("West", "1500")}
failures: list[str] = []


def ok(name: str, detail: str = "") -> None:
    print(f"ok {name}" + (f": {detail}" if detail else ""))


def fail(name: str, detail: str) -> None:
    failures.append(name)
    print(f"FAIL {name}: {detail}")


def check(name: str, actual, expected) -> None:
    if actual == expected:
        ok(name, repr(actual))
    else:
        fail(name, f"expected {expected!r}, got {actual!r}")


def rows_of(con, sql: str) -> set:
    return {(r[0], str(r[1])) for r in con.execute(sql).fetchall()}


def refusal_code(exc: Exception) -> str:
    # Matched, not enumerated. This was a list of three codes, so when a refusal
    # legitimately changed to a fourth the check reported the whole Exasol
    # message as the "code" and the failure read as if the statement had been
    # accepted -- the diagnosis cost more than the defect.
    text = str(exc)
    found = re.search(r"SEMANTIC_[A-Z]+_\d+", text)
    return found.group(0) if found else text.replace("\n", " ")[:100]


# Every shape here was refused before expansion. Each is checked for the values
# it returns, not merely for not raising: a shape that runs and answers wrongly
# is worse than one that refuses.
ACCEPTED = [
    ("bare object", "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"),
    ("aliased and qualified",
     "SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES t0"),
    ("subquery wrapper",
     "SELECT * FROM (SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE"
     " FROM SEMANTIC_SALES.SALES t0) x"),
    ("CTE with outer projection",
     "WITH q AS (SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES t0)"
     " SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM q"),
    ("union of two references",
     "SELECT a.CUSTOMER_REGION, a.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES a"
     " UNION SELECT b.CUSTOMER_REGION, b.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES b"),
]


def main() -> None:
    con = connect()
    con.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")
    admin = connect()
    admin.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    admin.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('{MODEL}', 'FALSE')")
    admin.commit()

    for name, sql in ACCEPTED:
        try:
            check(f"{name} returns the model's values", rows_of(con, sql), TRUTH)
        except Exception as exc:
            fail(f"{name} returns the model's values", refusal_code(exc))

    # The star in `SELECT * FROM (SELECT t0.A, t0.B FROM obj t0) x` belongs to
    # the subquery, not to the object. Reading it as "every column of obj"
    # compiled nine columns instead of two, which grouped by four dimensions
    # instead of one and returned North as 0. Same values, right grain.
    try:
        columns = con.execute(
            "SELECT * FROM (SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE"
            " FROM SEMANTIC_SALES.SALES t0) x").columns()
        check("a star is scoped to its own query block", len(columns), 2)
    except Exception as exc:
        fail("a star is scoped to its own query block", refusal_code(exc))

    # Aggregation above the derived table, which is the common BI wrapper.
    check("an outer aggregate sees the whole result",
          con.execute("SELECT SUM(t0.TOTAL_REVENUE) FROM SEMANTIC_SALES.SALES t0")
             .fetchone()[0], "5270")
    check("COUNT(*) over the object counts its rows",
          con.execute("SELECT COUNT(*) FROM (SELECT t0.CUSTOMER_REGION"
                      " FROM SEMANTIC_SALES.SALES t0) z").fetchone()[0], 3)

    # Projection inference refuses instead of guessing. The code is the
    # whole-statement lane's `_005` rather than expansion's `_011`, because both
    # lanes now see every statement (see verify_sql_lane_parity.py) and the one
    # that can name what is wrong with this SELECT list wins: "SELECT supports
    # semantic field names, MEASURE(metric), or *" says more than "cannot tell
    # which columns this needs". Expansion's `_011` still surfaces where the
    # other lane had no opinion at all.
    try:
        con.execute("SELECT 1 FROM SEMANTIC_SALES.SALES t0").fetchall()
        fail("a statement naming no column is refused", "it was accepted")
    except Exception as exc:
        check("a statement naming no column is refused",
              refusal_code(exc), "SEMANTIC_QUERY_005")

    # More than one model may carry the same PUBLISHED_SCHEMA -- the OSI
    # round-trip creates three beside the example model, all publishing to
    # SEMANTIC_SALES. Matching the column list on the schema name alone returned
    # every object called SALES in any of them, so the derived table had four
    # columns named CUSTOMER_REGION and Exasol rejected it as ambiguous. This
    # verifier runs before those models exist, which is exactly why the failure
    # survived a green suite: it only appeared once the later verifiers had run.
    sharing = con.execute(
        "SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS WHERE UPPER(PUBLISHED_SCHEMA) = "
        "UPPER('SEMANTIC_SALES')").fetchone()[0]
    if sharing > 1:
        ok("more than one model publishes to this schema", f"{sharing}")
    else:
        # Make the condition rather than wait for another verifier to create it.
        con.execute(
            "INSERT INTO SYS_SEMANTIC.MODELS (MODEL_NAME, PUBLISHED_SCHEMA, STATUS) "
            "VALUES ('esv_schema_twin', 'SEMANTIC_SALES', 'DRAFT')")
        con.commit()
        try:
            check("a second model on the same schema does not duplicate columns",
                  rows_of(con, "SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE"
                               " FROM SEMANTIC_SALES.SALES t0"), TRUTH)
        finally:
            con.execute("DELETE FROM SYS_SEMANTIC.MODELS "
                        "WHERE MODEL_NAME = 'esv_schema_twin'")
            con.commit()

    # The fan-out guard, and the arithmetic that justifies it.
    composed = ("SELECT t0.CUSTOMER_REGION, t0.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES t0"
                " JOIN MART.CUSTOMERS c ON c.REGION = t0.CUSTOMER_REGION")
    regrouped = ("SELECT t0.CUSTOMER_REGION, SUM(t0.TOTAL_REVENUE)"
                 " FROM SEMANTIC_SALES.SALES t0 JOIN MART.CUSTOMERS c"
                 " ON c.REGION = t0.CUSTOMER_REGION GROUP BY 1")
    for name, sql in (("a join to another relation", composed),
                      ("a comma join", "SELECT t0.CUSTOMER_REGION FROM SEMANTIC_SALES.SALES t0,"
                                       " MART.CUSTOMERS c")):
        try:
            con.execute(sql).fetchall()
            fail(f"{name} is refused by default", "it was accepted")
        except Exception as exc:
            check(f"{name} is refused by default", refusal_code(exc), "SEMANTIC_QUERY_012")

    admin.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('{MODEL}', 'TRUE')")
    admin.commit()
    try:
        check("opting in accepts the composition", len(con.execute(composed).fetchall()), 4)
        # And this is what opting in accepts. North is 3635; the join repeats it
        # once per matching customer and the re-aggregation doubles it.
        wrong = dict(con.execute(regrouped).fetchall())
        check("the fan-out the guard exists for is real", str(wrong.get("North")), "7270")
        ok("truth for the same region", "3635")
    except Exception as exc:
        fail("opting in accepts the composition", refusal_code(exc))
    finally:
        admin.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MODEL_DERIVED_COMPOSITION('{MODEL}', 'FALSE')")
        admin.commit()

    check("and the refusal returns once the model opts back out",
          refusal_code(_expect_raise(con, composed)), "SEMANTIC_QUERY_012")

    # A view over a semantic object stores compiled physical SQL, so it answers
    # with no preprocessor at all. Keeping the view stale-free is step 8's job;
    # what is checked here is that the text really was compiled.
    plain = connect()
    plain.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    con.execute("DROP VIEW IF EXISTS MART.V_ESV_EXPANSION")
    con.execute("CREATE VIEW MART.V_ESV_EXPANSION AS SELECT t0.CUSTOMER_REGION,"
                " t0.TOTAL_REVENUE FROM SEMANTIC_SALES.SALES t0")
    con.commit()
    check("a view over a semantic object reads without the preprocessor",
          rows_of(plain, "SELECT * FROM MART.V_ESV_EXPANSION"), TRUTH)
    frozen = plain.execute(
        "SELECT VIEW_TEXT FROM EXA_ALL_VIEWS WHERE VIEW_SCHEMA = 'MART'"
        " AND VIEW_NAME = 'V_ESV_EXPANSION'").fetchone()[0]
    check("and its stored text is compiled, not a semantic reference",
          "SEMANTIC_SALES" in frozen, False)
    plain.execute("DROP VIEW IF EXISTS MART.V_ESV_EXPANSION")
    plain.commit()
    plain.close()

    con.close()
    admin.close()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok reference expansion: BI shapes compile, composition is refused unless opted into")


def _expect_raise(con, sql: str) -> Exception:
    try:
        con.execute(sql).fetchall()
        return AssertionError("statement was accepted")
    except Exception as exc:
        return exc


if __name__ == "__main__":
    main()
