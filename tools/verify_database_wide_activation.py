#!/usr/bin/env python3
"""Database-wide activation does not deny service to principals outside this layer.

`docs/admin-db-wide-setup.md` calls `ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT`
the supported BI deployment mode, because a BI tool opens its own pooled
connections and has nowhere to run a per-session statement. Exasol then runs the
preprocessor **as the caller**, for every statement in the database.

So a principal who has never heard of this layer runs the preprocessor too. If
they cannot execute it, they cannot execute anything: `SELECT 1` returns
`insufficient privileges for executing a script`, and the supported deployment
mode is a database-wide outage. That is what this checks, because nothing else
does -- the rest of the suite activates per session, which is precisely the
configuration in which the fault cannot appear.

Two properties, and the second matters as much as the first. The preprocessor is
executable by anyone, and a caller who may run it but may *not* run the compiler
runtimes has their SQL passed through untouched rather than turned into an
error. The preprocessor's job is to rewrite semantic statements; one it cannot
rewrite belongs to the database exactly as written.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

PLAIN, PLAIN_PW = "ESV_DBWIDE_PLAIN", "pw_plain"
READER, READER_PW = "ESV_DBWIDE_READER", "pw_reader"
ROLE = "ESV_DBWIDE_ROLE"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
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


def quiet(con, sql: str) -> None:
    try:
        con.execute(sql)
    except Exception:
        pass


def runs(user: str, password: str, sql: str) -> bool:
    con = connect(user=user, password=password)
    try:
        con.execute(sql).fetchall()
        return True
    except Exception:
        return False
    finally:
        con.close()


def teardown(con) -> None:
    for user in (PLAIN, READER):
        quiet(con, f"DROP USER IF EXISTS {user} CASCADE")
    con.execute(f"DELETE FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS WHERE ROLE_NAME = '{ROLE}'")
    quiet(con, f"DROP ROLE IF EXISTS {ROLE} CASCADE")
    con.commit()


def main() -> None:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    teardown(con)

    # Whatever the deployment had is restored, not assumed to be NULL.
    previous = con.execute(
        "SELECT SYSTEM_VALUE FROM EXA_PARAMETERS "
        "WHERE PARAMETER_NAME = 'SQL_PREPROCESSOR_SCRIPT'").fetchone()[0]

    con.execute(f'CREATE USER {PLAIN} IDENTIFIED BY "{PLAIN_PW}"')
    con.execute(f"GRANT CREATE SESSION TO {PLAIN}")
    con.execute(f'CREATE USER {READER} IDENTIFIED BY "{READER_PW}"')
    con.execute(f"GRANT CREATE SESSION TO {READER}")
    con.execute(f"CREATE ROLE {ROLE}")
    con.execute(f"GRANT {ROLE} TO {READER}")
    con.execute(f"GRANT SELECT ON SCHEMA MART TO {ROLE}")
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('sales', '{ROLE}')")
    con.commit()

    try:
        con.execute(f"ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")
        con.commit()

        # A principal with nothing but CREATE SESSION. Every one of these failed
        # with `insufficient privileges for executing a script` before the
        # preprocessor was granted to PUBLIC.
        check("a plain principal can run a constant select",
              runs(PLAIN, PLAIN_PW, "SELECT 1"), True)
        check("and one that names a schema this layer does not own",
              runs(PLAIN, PLAIN_PW, "SELECT COUNT(*) FROM EXA_ALL_TABLES"), True)
        check("and a statement the parser has to look at properly",
              runs(PLAIN, PLAIN_PW,
                   "SELECT CASE WHEN 1 = 1 THEN 'a' ELSE 'b' END FROM DUAL"), True)

        # The layer still works for someone entitled to it, in both lanes.
        check("a granted principal still compiles a bare semantic query",
              runs(READER, READER_PW,
                   "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"), True)
        check("and a wrapped one",
              runs(READER, READER_PW,
                   "SELECT SUM(t0.TOTAL_REVENUE) FROM SEMANTIC_SALES.SALES t0"), True)

        # The administrator's own session is unaffected.
        admin = connect()
        check("and the administrator's session is unaffected",
              len(admin.execute(
                  "SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"
              ).fetchall()) > 0, True)
        admin.close()
    finally:
        # Leaving this set would run every later verifier under a system-wide
        # preprocessor, so it is restored even if an assertion above raised.
        restore = "NULL" if previous is None else previous
        con.execute(f"ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = {restore}")
        con.commit()

    settled = con.execute(
        "SELECT SYSTEM_VALUE FROM EXA_PARAMETERS "
        "WHERE PARAMETER_NAME = 'SQL_PREPROCESSOR_SCRIPT'").fetchone()[0]
    check("the system setting is put back", settled, previous)

    teardown(con)
    con.close()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok database-wide activation: the supported deployment mode serves everyone")


if __name__ == "__main__":
    main()
