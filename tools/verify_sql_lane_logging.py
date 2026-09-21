#!/usr/bin/env python3
"""The lane BI tools use records what it did, and the record explains itself.

`QUERY_LOG` was written by `COMPILE_SQL_DEBUG` and by nothing else. So after a
day of dashboards the table held zero rows from the preprocessor,
`SEMANTIC_SOURCE.MY_QUERY_LOG` was permanently empty, and
`EXPLAIN_COMPILED_SQL('QUERY_LOG', …)` had no handle to explain --
which is the remedy `docs/bi-tools.md` offers for "why is my number different
from my colleague's" and `docs/governance.md` for reading the governance prose
after a query has run. Both were reachable from every lane except the one most
queries take. `SEMANTIC_USER` was even granted `INSERT` on the table, for a
writer that never ran.

Writing the row is only half of it, and the weaker half. A row is worth having
because it can be explained, and everything `EXPLAIN_COMPILED_SQL` reports --
the governance prose, the materialization, which fields were asked for -- is
read back out of `PLAN_JSON`. So this verifier checks the explanation, not the
row count: a lane that logged diligently with no plan would satisfy the letter
of the fix and leave the story exactly as unreachable.

It runs as a scoped principal rather than as `SYS`, because that is the caller
the surface exists for and the one every part of this failed for. `SYS` has
SELECT on everything and would not have noticed that the script reads the base
table with the caller's rights.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, named_row  # noqa: E402

MODEL = "sales"
OBJECT = "SEMANTIC_SALES.SALES"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
USER, PASSWORD, ROLE = "ESV_LANELOG_USER", "Esv-lanelog-pw-1", "ESV_LANELOG_ROLE"
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


def drop_all(con) -> None:
    # Revoked before the role is dropped. The grant is a catalog row, not a
    # database privilege, so dropping the role leaves it ACTIVE and pointing at
    # a principal that no longer exists -- which changes what later verifiers
    # see, because a model with no active grant is visible to everyone.
    try:
        con.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.REVOKE_MODEL_ROLE('{MODEL}', '{ROLE}')")
    except Exception:  # noqa: BLE001 -- nothing granted yet is the normal case
        pass
    for statement in (f"DROP USER {USER} CASCADE", f"DROP ROLE {ROLE} CASCADE"):
        try:
            con.execute(statement)
        except Exception:  # noqa: BLE001 -- absent is the normal case
            pass
    con.commit()


def main() -> int:
    admin = connect()
    admin.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    drop_all(admin)
    admin.execute(f'CREATE USER {USER} IDENTIFIED BY "{PASSWORD}"')
    admin.execute(f"CREATE ROLE {ROLE}")
    admin.execute(f"GRANT {ROLE} TO {USER}")
    admin.execute(f"GRANT CREATE SESSION TO {USER}")
    admin.execute(f"GRANT SELECT ON SCHEMA MART TO {ROLE}")
    admin.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('{MODEL}', '{ROLE}')")
    admin.commit()

    try:
        probe = connect(user=USER, password=PASSWORD)
        probe.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")

        before = probe.execute(
            "SELECT COUNT(*) FROM SEMANTIC_SOURCE.MY_QUERY_LOG").fetchone()[0]

        # The whole-statement lane and the expansion lane, then something the
        # layer had no part in.
        probe.execute(f"SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM {OBJECT}").fetchall()
        probe.execute(f"SELECT TOTAL_REVENUE / 1000 FROM {OBJECT}").fetchall()
        probe.execute("SELECT 1 FROM DUAL").fetchall()
        probe.commit()

        rows = probe.execute(
            "SELECT QUERY_LOG_ID, CLIENT_NAME, USER_NAME,"
            " CASE WHEN PLAN_JSON IS NULL THEN 0 ELSE 1 END AS HAS_PLAN"
            " FROM SEMANTIC_SOURCE.MY_QUERY_LOG"
            " ORDER BY QUERY_LOG_ID DESC LIMIT 2").fetchall()
        after = probe.execute(
            "SELECT COUNT(*) FROM SEMANTIC_SOURCE.MY_QUERY_LOG").fetchone()[0]

        check("the preprocessor lane writes one row per semantic statement",
              after - before, 2)
        check("and nothing for a statement the layer did not touch",
              after - before == 2, True)
        check("the rows belong to the principal that ran them",
              {row[2] for row in rows}, {USER})
        check("both sub-lanes are distinguishable in the record",
              {str(row[1]) for row in rows},
              {"PREPROCESSOR", "PREPROCESSOR:EXPANSION"})
        check("every row carries the plan its explanation is read from",
              {row[3] for row in rows}, {1})

        # The payoff. This is the call that had nothing to explain. Explained by
        # lane rather than by recency: the two statements asked for different
        # fields, and asserting on whichever happened to be newest tests the
        # ordering rather than the record.
        by_lane = {str(row[1]): row[0] for row in rows}
        handle = by_lane["PREPROCESSOR"]

        def explain(query_log_id):
            """Guarded, because the way this fails is a privilege error.

            The script runs with the caller's rights, so reading the base table
            instead of the scoped view raises rather than returning nothing --
            an unguarded call ends the run with a traceback and names no
            invariant, which is exactly the shape that hides a regression.
            """
            try:
                return named_row(probe.execute(
                    "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL("
                    f"'QUERY_LOG', {query_log_id})")), None
            except Exception as exception:  # noqa: BLE001
                return None, " ".join(str(exception).split())

        explained, why = explain(handle)
        if explained is None:
            fail("a BI user can explain their own query", why[:160])
            explained = {}
        else:
            check("a BI user can explain their own query",
                  explained["model_name"], MODEL)
        governance = str(explained.get("governance") or "")
        check("and the explanation carries governance prose",
              "mode." in governance, True)
        check("naming the principal whose rights resolved the rows",
              USER in governance, True)
        # Read back out of PLAN_JSON, because the preprocessor lane has no
        # canonical request to write them from.
        check("and which fields were asked for",
              "customer_region" in str(explained.get("requested_dimensions") or ""),
              True)

        # The expansion lane too, whose row is the one with no canonical request
        # behind it at all -- its fields exist only inside the inner compile's
        # plan, which expansion used to discard.
        expanded, why = explain(by_lane["PREPROCESSOR:EXPANSION"])
        check("an expanded statement is explainable too",
              expanded is not None
              and "total_revenue" in str(expanded.get("requested_metrics") or ""),
              True)

        # A handle belonging to somebody else is not theirs to read. SYS has
        # written plenty of rows; none should be reachable here.
        other = admin.execute(
            "SELECT MAX(QUERY_LOG_ID) FROM SYS_SEMANTIC.QUERY_LOG"
            f" WHERE USER_NAME <> '{USER}'").fetchone()[0]
        if other is None:
            ok("no other principal's row exists to probe", "skipped")
        else:
            try:
                probe.execute(
                    "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL("
                    f"'QUERY_LOG', {other})").fetchall()
                fail("another principal's query is not explainable",
                     "it was explained")
            except Exception as exception:  # noqa: BLE001 -- refusal is the result
                message = " ".join(str(exception).split())
                check("another principal's query reports as not found,"
                      " not as forbidden",
                      "SEMANTIC_AGENT_030" in message, True)
    finally:
        drop_all(admin)

    if failures:
        print(f"\n{len(failures)} failure(s): " + ", ".join(failures))
        return 1
    print("\nthe SQL lane records what it did, and the record explains itself")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
