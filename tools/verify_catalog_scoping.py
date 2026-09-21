#!/usr/bin/env python3
"""The catalog and agent surfaces show a caller only the models it may see.

`SEMANTIC_SOURCE` was introduced so a non-`SYS` principal would not need `SELECT`
on `SYS_SEMANTIC` -- "every other model's metric definitions, every other user's
logged requests, and a map of the physical estate". It is correctly scoped. But
`SEMANTIC_USER` also carries `SELECT` on `SEMANTIC_CATALOG` and `SEMANTIC_AGENT`,
and every view in them read the tables directly, so the disclosure came back
through the surface beside the one that had been fixed:

    GOVERNANCE_FOR_MODEL            ->  sales | VISIBLE_TO_CALLER = False
    SEMANTIC_CATALOG.METRICS        ->  sales | total_revenue | SUM(net_revenue)

One view truthfully reporting the model is not visible while the view next to it
hands over its definitions is worse than either answer alone, because the first
one is what an auditor reads.

The fix is not 59 more `WHERE` clauses. Those views now read the already-filtered
`SEMANTIC_SOURCE` views instead of the tables, so the scoping is inherited rather
than restated -- and a view added later inherits it by construction.

What is deliberately *not* scoped: deployment identity (`PRODUCT_VERSION`), which
is a property of the installation and not of any model.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

USER, PASSWORD = "ESV_SCOPE_ANALYST", "pw_scope"
HELD, WITHHELD_ROLE = "ESV_SCOPE_HELD", "ESV_SCOPE_OTHER"
WITHHELD_MODEL = "sales"
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


def teardown(con) -> None:
    quiet(con, f"DROP USER IF EXISTS {USER} CASCADE")
    con.execute("DELETE FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS WHERE ROLE_NAME IN "
                f"('{HELD}', '{WITHHELD_ROLE}')")
    for role in (HELD, WITHHELD_ROLE):
        quiet(con, f"DROP ROLE IF EXISTS {role} CASCADE")
    con.commit()


def main() -> None:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    teardown(con)

    # The analyst holds a role that is granted no model. `sales` is granted to a
    # role it does not hold, which is what makes the model invisible: an
    # ungranted model stays visible to everyone by design.
    con.execute(f'CREATE USER {USER} IDENTIFIED BY "{PASSWORD}"')
    con.execute(f"GRANT CREATE SESSION TO {USER}")
    for role in (HELD, WITHHELD_ROLE):
        con.execute(f"CREATE ROLE {role}")
    con.execute(f"GRANT {HELD} TO {USER}")
    con.execute(f"GRANT SEMANTIC_USER TO {HELD}")
    con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('{WITHHELD_MODEL}', '{WITHHELD_ROLE}')")
    con.commit()

    analyst = connect(user=USER, password=PASSWORD)
    analyst.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")

    def count(sql: str) -> int:
        return analyst.execute(sql).fetchone()[0]

    try:
        # The surface that was already right, as the baseline.
        check("the model is reported as not visible",
              analyst.execute(
                  "SELECT VISIBLE_TO_CALLER FROM SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL "
                  f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'").fetchone()[0], False)
        check("and SEMANTIC_SOURCE agrees",
              count("SELECT COUNT(*) FROM SEMANTIC_SOURCE.MODELS m "
                    f"WHERE m.MODEL_NAME = '{WITHHELD_MODEL}'"), 0)

        # The surfaces that did not. Each of these returned rows.
        for name, sql in (
            ("metric expressions",
             "SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
            ("dimension expressions",
             "SELECT COUNT(*) FROM SEMANTIC_CATALOG.DIMENSIONS "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
            ("the entity list",
             "SELECT COUNT(*) FROM SEMANTIC_CATALOG.ENTITIES "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
            ("the physical estate",
             "SELECT COUNT(*) FROM SEMANTIC_CATALOG.ENTITY_REPRESENTATIONS "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
            ("the trust classification",
             "SELECT COUNT(*) FROM SEMANTIC_CATALOG.SOURCE_TRUST_FOR_MODEL "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
            ("validation findings",
             "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
            ("the agent field list",
             "SELECT COUNT(*) FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
            ("the agent object list",
             "SELECT COUNT(*) FROM SEMANTIC_AGENT.OBJECTS_FOR_AGENT "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
            ("the agent model list",
             "SELECT COUNT(*) FROM SEMANTIC_AGENT.MODELS_FOR_AGENT "
             f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'"),
        ):
            try:
                check(f"a withheld model's {name} are not readable", count(sql), 0)
            except Exception as exc:
                fail(f"a withheld model's {name} are not readable",
                     str(exc).replace("\n", " ")[:90])

        # Granting it makes the same surfaces answer, or the scoping is just an
        # outage wearing a control's clothes.
        con.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('{WITHHELD_MODEL}', '{HELD}')")
        con.commit()
        granted = connect(user=USER, password=PASSWORD)
        granted.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
        check("granting the model makes its metrics readable",
              granted.execute("SELECT COUNT(*) FROM SEMANTIC_CATALOG.METRICS "
                              f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'").fetchone()[0] > 0, True)
        check("and its fields discoverable by an agent",
              granted.execute("SELECT COUNT(*) FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT "
                              f"WHERE MODEL_NAME = '{WITHHELD_MODEL}'").fetchone()[0] > 0, True)
        # Deployment identity is a property of the installation, not of a model.
        check("deployment identity stays readable",
              granted.execute(
                  "SELECT COUNT(*) FROM SEMANTIC_CATALOG.PRODUCT_VERSION").fetchone()[0] > 0,
              True)
        granted.close()
    finally:
        analyst.close()
        teardown(con)
        con.close()

    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok catalog scoping: the human and agent surfaces show only what the caller may see")


if __name__ == "__main__":
    main()
