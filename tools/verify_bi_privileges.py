#!/usr/bin/env python3
"""The privilege table in bi-tools.md is what the database actually enforces.

`docs/bi-tools.md` tells an integrator what to grant. A table of privileges is
exactly the kind of documentation that rots quietly: nothing fails when it drifts,
and the person who finds out is the one whose BI role cannot retrieve a row.

Two claims are worth more than the rest.

**A model grant is not enough to get rows back.** The compiler runs as the
caller, so the SQL it generates reads the physical tables with the caller's
rights. A role granted the model but not the sources browses every field,
compiles every query, and retrieves nothing.

**`CREATE VIEW` over a semantic object is not a BI capability**, though
`bi-tools.md` shows it among the statements that compile. It needs a privilege a
reporting role should not hold, and what it produces is readable by anyone
granted the view -- with no rights on the sources and no preprocessor -- because
the stored text is compiled physical SQL and the view runs with its owner's
rights. That is a durable grant of data, so it is checked here rather than
described.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

MODEL, OBJECT = "sales", "SEMANTIC_SALES.SALES"
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
AUTHOR, AUTHOR_PW, AUTHOR_ROLE = "ESV_BIPRIV_AUTHOR", "Esv-bipriv-a-1", "ESV_BIPRIV_AUTHOR_ROLE"
READER, READER_PW, READER_ROLE = "ESV_BIPRIV_READER", "Esv-bipriv-r-1", "ESV_BIPRIV_READER_ROLE"
OWNED_SCHEMA = "ESV_BIPRIV_SCHEMA"
CODE = re.compile(r"SEMANTIC_[A-Z]+_\d+")
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


def outcome(con, sql: str) -> str:
    """"rows" / "none", a rule code, or DENIED."""
    try:
        rows = con.execute(sql).fetchall()
        return "rows" if rows and rows[0] and rows[0][0] else "none"
    except Exception as exception:  # noqa: BLE001 -- the refusal is the result
        text = " ".join(str(exception).split())
        found = CODE.search(text)
        if found:
            return found.group(0)
        return "DENIED" if "insufficient privileges" in text else text[:60]


def main() -> int:
    admin = connect()
    admin.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")

    def quietly(statement: str) -> None:
        try:
            admin.execute(statement)
            admin.commit()
        except Exception:  # noqa: BLE001 -- absent is the normal case
            admin.rollback()

    def teardown() -> None:
        quietly(f"DROP SCHEMA IF EXISTS {OWNED_SCHEMA} CASCADE")
        for user in (AUTHOR, READER):
            quietly(f"DROP USER {user} CASCADE")
        for role in (AUTHOR_ROLE, READER_ROLE):
            quietly("EXECUTE SCRIPT SEMANTIC_ADMIN."
                    f"REVOKE_MODEL_ROLE('{MODEL}', '{role}')")
            quietly(f"DROP ROLE {role} CASCADE")

    teardown()
    try:
        for user, password, role in ((AUTHOR, AUTHOR_PW, AUTHOR_ROLE),
                                     (READER, READER_PW, READER_ROLE)):
            admin.execute(f'CREATE USER {user} IDENTIFIED BY "{password}"')
            admin.execute(f"CREATE ROLE {role}")
            admin.execute(f"GRANT {role} TO {user}")
            admin.execute(f"GRANT CREATE SESSION TO {user}")
            admin.execute("EXECUTE SCRIPT SEMANTIC_ADMIN."
                          f"GRANT_MODEL_ROLE('{MODEL}', '{role}')")
        admin.commit()

        # 1. the model grant alone: everything but the rows
        probe = connect(user=READER, password=READER_PW)
        probe.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")
        check("a model grant alone lists the models",
              outcome(probe, "SELECT COUNT(*) FROM SEMANTIC_SOURCE.AUTHORIZED_MODELS"),
              "rows")
        check("and browses the catalog",
              outcome(probe, "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CATALOG_COLUMNS"),
              "rows")
        # Either symptom is correct, and which one appears depends on the compile
        # cache. Cold, the compile itself fails: the caller cannot see the source
        # metadata, so the planner finds no representation that can traverse the
        # relationship (`SEMANTIC_QUERY_080`, whose message now names the
        # privilege possibility). Warm, an entry compiled by someone who *could*
        # read the sources is served and the execution is denied instead. What
        # matters to the table in bi-tools.md is the same either way: no rows.
        source_less = outcome(probe, f"SELECT CUSTOMER_REGION, TOTAL_REVENUE"
                                     f" FROM {OBJECT}")
        check("but retrieves no data without rights on the sources",
              source_less in ("SEMANTIC_QUERY_080", "DENIED"), True)
        check("and cannot read the sources directly either",
              outcome(probe, "SELECT COUNT(*) FROM MART.ORDER_LINES"), "DENIED")

        # 2. CREATE VIEW is a privilege a reporting role does not have
        check("a BI role cannot create a view over a semantic object",
              outcome(probe, "CREATE VIEW MART.V_ESV_BIPRIV AS"
                             f" SELECT CUSTOMER_REGION FROM {OBJECT}"), "DENIED")
        probe.close()

        # 3. with source rights, the same role gets rows
        admin.execute(f"GRANT SELECT ON SCHEMA MART TO {READER_ROLE}")
        admin.commit()
        probe = connect(user=READER, password=READER_PW)
        probe.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")
        check("granting the sources is what makes rows appear",
              outcome(probe, f"SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM {OBJECT}"),
              "rows")
        probe.close()
        admin.execute(f"REVOKE SELECT ON SCHEMA MART FROM {READER_ROLE}")
        admin.commit()

        # 4. what a view over a semantic object really hands out
        admin.execute(f"GRANT SELECT ON SCHEMA MART TO {AUTHOR_ROLE}")
        admin.execute(f"GRANT CREATE SCHEMA TO {AUTHOR}")
        admin.execute(f"GRANT CREATE VIEW TO {AUTHOR_ROLE}")
        admin.commit()
        author = connect(user=AUTHOR, password=AUTHOR_PW)
        author.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")
        author.execute(f"CREATE SCHEMA {OWNED_SCHEMA}")
        author.execute(f"CREATE VIEW {OWNED_SCHEMA}.V_FROZEN AS"
                       f" SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM {OBJECT}")
        author.commit()
        ok("CREATE VIEW works in a schema the author owns")
        check("but not in one they do not own",
              outcome(author, f"CREATE VIEW MART.V_ESV_BIPRIV2 AS"
                              f" SELECT CUSTOMER_REGION FROM {OBJECT}"), "DENIED")
        # Plain SELECT on the sources is not enough to pass the view on.
        check("and the author cannot grant the view on without grantable source rights",
              outcome(author, f"GRANT SELECT ON {OWNED_SCHEMA}.V_FROZEN"
                              f" TO {READER_ROLE}"), "DENIED")
        author.close()

        admin.execute(f"GRANT SELECT ON {OWNED_SCHEMA}.V_FROZEN TO {READER_ROLE}")
        admin.commit()
        reader = connect(user=READER, password=READER_PW)
        reader.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
        check("a reader with no source rights and no preprocessor reads the view",
              outcome(reader, f"SELECT COUNT(*) FROM {OWNED_SCHEMA}.V_FROZEN"), "rows")
        check("while the sources stay closed to them",
              outcome(reader, "SELECT COUNT(*) FROM MART.ORDER_LINES"), "DENIED")

        # 5. the published object itself refuses without the preprocessor --
        #    including COUNT(*), which evaluates no column and used to return 1
        check("the published object refuses without the preprocessor",
              outcome(reader, f"SELECT CUSTOMER_REGION FROM {OBJECT}"),
              "SEMANTIC_SURFACE_001")
        check("and COUNT(*) does not slip past the guard",
              outcome(reader, f"SELECT COUNT(*) FROM {OBJECT}"),
              "SEMANTIC_SURFACE_001")
        reader.close()
    finally:
        teardown()

    if failures:
        print(f"\n{len(failures)} failure(s): " + ", ".join(failures))
        return 1
    print("\nthe privilege table matches what the database enforces")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
