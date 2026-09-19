#!/usr/bin/env python3
"""Model authorization is a database-enforced property, and it counts inherited roles.

Two defects this exists for.

The catalog read surface was the whole catalog. The compiler runs as the caller
-- an Exasol scripting script has the caller's rights -- so for a non-SYS
principal to compile anything it needed SELECT on SYS_SEMANTIC, which is every
other model's metric definitions, every other user's logged requests, and a map
of the physical estate. No amount of care in the compiler could narrow that,
because the caller can read the tables without going through it.

And model authorization was accidental. MODEL_ROLE_GRANTS existed and nothing
consulted it. What actually stopped a caller reaching a model was lacking
privileges on its *physical* sources, so the source-column probe found nothing
and the planner reported SEMANTIC_REQUEST_080 -- "no active representation can
traverse relationship ..." -- an authorization outcome reported as a modelling
defect, which sends a modeller looking for a bug that does not exist.

Both close the same way: the caller is granted SEMANTIC_SOURCE, not SYS_SEMANTIC,
and those views carry the filter. A view is owner-rights while CURRENT_USER and
EXA_SESSION_ROLES inside it resolve to the caller, so the rule is enforced by the
database rather than by the compiler agreeing to apply it.

The role hierarchy here is three levels deep on purpose. ESV used to match
principals as `IN (CURRENT_USER, 'PUBLIC')`, which sees a directly granted role
and misses everything it inherits.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, sql_string  # noqa: E402

USER, PASSWORD = "ESV_PRINCIPAL_PROBE", "probe"
OUTER, MIDDLE, INNER = ("ESV_PRINCIPAL_L1", "ESV_PRINCIPAL_L2", "ESV_PRINCIPAL_L3")
OTHER = "ESV_PRINCIPAL_OTHER"
# Only the example model is guaranteed to exist here: every other model in the
# suite is created by a verifier that runs later. So one model is used twice --
# withheld first, then granted -- which is a better test anyway, because it
# proves the transition rather than two unrelated states.
MODEL, OBJECT = "sales", "SALES"
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
    for stmt in (f"DROP USER IF EXISTS {USER} CASCADE",
                 f"DROP ROLE IF EXISTS {OUTER} CASCADE",
                 f"DROP ROLE IF EXISTS {MIDDLE} CASCADE",
                 f"DROP ROLE IF EXISTS {INNER} CASCADE",
                 f"DROP ROLE IF EXISTS {OTHER} CASCADE"):
        try:
            con.execute(stmt)
        except Exception:
            pass
    con.execute("DELETE FROM SYS_SEMANTIC.MODEL_ROLE_GRANTS WHERE ROLE_NAME IN "
                f"('{INNER}', '{OTHER}')")
    con.commit()


def compile_as(con, request: dict) -> dict:
    statement = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(json.dumps(request))})")
    names = [n.lower() for n in statement.columns().keys()]
    return dict(zip(names, statement.fetchone()))


def main() -> None:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    drop_all(con)

    # USER -> OUTER -> MIDDLE -> INNER. Only OUTER is granted to the user, and
    # only INNER is ever granted the model, so nothing short of the transitive
    # closure connects the two.
    con.execute(f'CREATE USER {USER} IDENTIFIED BY "{PASSWORD}"')
    for role in (OUTER, MIDDLE, INNER, OTHER):
        con.execute(f"CREATE ROLE {role}")
    con.execute(f"GRANT {INNER} TO {MIDDLE}")
    con.execute(f"GRANT {MIDDLE} TO {OUTER}")
    con.execute(f"GRANT {OUTER} TO {USER}")
    con.execute(f"GRANT CREATE SESSION TO {USER}")
    con.execute(f"GRANT SELECT ON SCHEMA MART TO {INNER}")
    # The baseline, granted directly so the withheld phase below reaches the
    # compiler at all: a caller that cannot call it proves nothing about what it
    # is allowed to see.
    con.execute(f"GRANT SEMANTIC_USER TO {INNER}")
    # Granted to a role nobody here holds. Without any grant the model would
    # stay visible to everyone, which is the documented opt-in default.
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('{MODEL}', '{OTHER}')")
    con.commit()

    # GRANT_MODEL_ROLE hands out the baseline as well as the model. Checked on
    # OTHER, which started with nothing, so the grant cannot be mistaken for the
    # one made directly above.
    baseline = con.execute(
        "SELECT COUNT(*) FROM EXA_DBA_ROLE_PRIVS "
        f"WHERE GRANTEE = '{OTHER}' AND GRANTED_ROLE = 'SEMANTIC_USER'").fetchone()[0]
    check("granting a model grants the baseline it needs to be usable", baseline, 1)

    probe = connect(user=USER, password=PASSWORD)
    probe.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")

    # 1. the transitive closure is what ESV now matches against
    principals = {r[0] for r in probe.execute(
        "SELECT PRINCIPAL_NAME FROM SEMANTIC_SOURCE.EFFECTIVE_PRINCIPAL").fetchall()}
    check("the inherited role two levels up is a principal", INNER in principals, True)
    check("so is the directly granted one", OUTER in principals, True)
    check("and the caller itself", USER in principals, True)

    # 2. SYS_SEMANTIC is not readable -- this is what makes the filter a control
    #    rather than a convention the compiler could be talked out of.
    for table in ("METRICS", "ENTITY_REPRESENTATIONS", "AGENT_REQUEST_LOG"):
        try:
            probe.execute(f"SELECT COUNT(*) FROM SYS_SEMANTIC.{table}").fetchall()
            fail(f"SYS_SEMANTIC.{table} is not readable", "the caller could read it")
        except Exception as exc:
            if "insufficient privileges" in str(exc):
                ok(f"SYS_SEMANTIC.{table} is not readable")
            else:
                fail(f"SYS_SEMANTIC.{table} is not readable", str(exc)[:90])

    # 3. withheld: the model is absent from every scoped surface, including the
    #    one that would otherwise hand over a map of the physical estate
    def visible_models():
        return {r[0] for r in probe.execute(
            "SELECT MODEL_NAME FROM SEMANTIC_SOURCE.AUTHORIZED_MODELS").fetchall()}

    # Counted for this model rather than globally: other models may exist by the
    # time this runs, and an ungranted one stays visible by design, so a global
    # zero would be asserting something this step never claimed.
    def mart_representations():
        return probe.execute(
            "SELECT COUNT(*) FROM SEMANTIC_SOURCE.ENTITY_REPRESENTATIONS "
            "WHERE SOURCE_SCHEMA = 'MART'").fetchone()[0]

    def visible_columns():
        return probe.execute(
            "SELECT COUNT(*) FROM SEMANTIC_SOURCE.OBJECT_COLUMNS").fetchone()[0]

    check("a model granted to another role is invisible", MODEL in visible_models(), False)
    check("and so is its physical estate", mart_representations(), 0)
    withheld_columns = visible_columns()

    withheld = compile_as(probe, {"model": MODEL, "object": OBJECT,
                                  "metrics": ["total_revenue"]})
    check("compiling it refuses", withheld["status"], "ERROR")
    check("with the not-found code, not a relationship-traversal defect",
          withheld["error_code"], "SEMANTIC_REQUEST_011")
    check("and the message points at authorization",
          "not granted to you" in (withheld["error_message"] or ""), True)

    # 4. an administrator is not locked out of a model granted to someone else
    admin = compile_as(con, {"model": MODEL, "object": OBJECT,
                             "dimensions": ["customer_region"],
                             "metrics": ["total_revenue"]})
    check("an administrator still reaches it", admin["status"], "OK")

    # 5. granted: the same principal, the same model, one grant later
    con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.GRANT_MODEL_ROLE('{MODEL}', '{INNER}')")
    con.commit()
    check("granting the inherited role makes it visible", MODEL in visible_models(), True)
    check("and its representations with it", mart_representations() > 0, True)
    # The child table carries no MODEL_ID and is scoped through its parent, so
    # its row count has to move with the grant like everything else.
    check("a child table is scoped through its parent, not left open",
          visible_columns() > withheld_columns, True)

    granted = compile_as(probe, {"model": MODEL, "object": OBJECT,
                                 "dimensions": ["customer_region"],
                                 "metrics": ["total_revenue"]})
    check("it compiles through the scoped catalog", granted["status"], "OK")
    if granted["status"] == "OK":
        rows = probe.execute(granted["generated_sql"]).fetchall()
        check("and the compiled SQL runs", len(rows) > 0, True)

    probe.close()
    drop_all(con)
    con.close()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok effective principal: authorization is enforced by the database, inherited roles included")


if __name__ == "__main__":
    main()
