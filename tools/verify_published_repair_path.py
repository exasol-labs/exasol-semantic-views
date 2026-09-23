#!/usr/bin/env python3
"""Verify a published model carrying validation errors can still be repaired.

Every mutator that touches a *published* model revalidates the candidate and
reverts itself with `SEMANTIC_ADMIN_094` if the candidate fails. Measured
against zero errors that is a trap rather than a guard: a model holding two
independent errors cannot be repaired, because every single step removes one and
leaves the other, so every step is refused and rolled back. The model is then
unpublishable and unrepairable, and only `DROP_MODEL` escapes -- taking the
entities, relationships, published views and grants with it. That is the same
class of dead end `REMOVE_SEMANTIC_OBJECT` was added to solve one level up.

The state is reachable without any admin call: dropping a column that a binding
reads leaves the published model invalid the next time anyone validates it,
which is how this verifier gets there.

`SEMANTIC_ADMIN.NEW_VALIDATION_ERRORS` reports only the errors a candidate
*introduced*, against the errors the model already had. Both halves of that are
asserted here, because a guard that stops refusing is not a fix:

  1. The trap is gone -- a step that introduces nothing is accepted even though
     the model is still invalid, and a two-error model is returned to a clean,
     published one entirely through the admin surface.
  2. The guard still holds -- a step that introduces a *new* error is still
     refused with `SEMANTIC_ADMIN_094` and still reverted, with the model left
     exactly as it was.
  3. `RECERTIFY_MODEL_IF_PUBLISHED` distinguishes the two: `ERROR` for an error
     this change caused, `ERROR_PRE_EXISTING` for one it inherited.
  4. The documented limit: the baseline is the model's *previous* validation
     run, so before anyone revalidates a model that has just broken, every error
     still reads as new and the guard refuses as it always did.

Also asserted: `SEMANTIC_MODEL_070` and `SEMANTIC_MODEL_071`, split out of
`SEMANTIC_MODEL_044`, name what they counted. Both used to print only their
requirement, and a steward reading the catalog could see rows the validator did
not count and conclude the rule contradicted it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, named_rows, sql_argument, sql_string  # noqa: E402

SCHEMA = "REPAIR_PATH_VERIFY"
MODEL = "repair_path_verify"
PUBLISHED = "SEMANTIC_REPAIR_PATH"
CODES = "repair_path_codes"
ENTITY = "customer"


def execute(con, sql):
    statement = con.execute(sql)
    if statement.num_columns == 0:
        return []
    return named_rows(statement)


def script(con, name, *arguments):
    """Run an admin script; return rows on success, or its refusal code."""
    rendered = ", ".join(sql_argument(argument) for argument in arguments)
    try:
        return execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.{name}({rendered})")
    except Exception as failure:  # noqa: BLE001 -- the refusal is the observation
        message = re.search(r'message\s+=>\s+"(.*?)" caught in script', str(failure), re.S)
        text = message.group(1) if message else str(failure)
        code = re.search(r"\b(SEMANTIC_[A-Z]+_\d+)\b", text)
        return code.group(1) if code else text.strip().split("\n")[0][:200]


def errors(con):
    rows = execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({sql_string(MODEL)})")
    return [row for row in rows if row["severity"] in ("ERROR", "PRECONDITION")]


def outcome(rows_or_code):
    """'accepted', or the refusal code -- so a failure names what was refused."""
    return "accepted" if isinstance(rows_or_code, list) else rows_or_code


def check(name, actual, expected):
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"  ok  {name}")


def teardown(con):
    for model in (MODEL, CODES):
        try:
            con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL({sql_string(model)})")
        except Exception:  # noqa: BLE001
            pass
    for schema in (SCHEMA, PUBLISHED, "SEMANTIC_" + CODES.upper()):
        try:
            con.execute(f"DROP SCHEMA IF EXISTS {schema} CASCADE")
        except Exception:  # noqa: BLE001
            pass


def build(con):
    """A published model whose one entity is reconciled across two sources.

    Both dimensions bind on both representations and carry RECONCILE, so each
    binding is load-bearing: that is what makes a single-step repair leave the
    model invalid. The alternate exposes the entity's own key, so no semantic
    identity is needed (SEMANTIC_MODEL_036).
    """
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    for table in ("C_MDM", "C_CRM"):
        con.execute(f"CREATE TABLE {SCHEMA}.{table} ("
                    "CUSTOMER_ID DECIMAL(18,0), NAME VARCHAR(50), TIER VARCHAR(20))")
        con.execute(f"INSERT INTO {SCHEMA}.{table} VALUES (1,'Ada','GOLD'),(2,'Bo','SILVER')")

    key_json = '[{"column_name":"CUSTOMER_ID","ordinal_position":1}]'
    steps = [
        ("CREATE_MODEL", MODEL, PUBLISHED, "repair path probe", None),
        ("ADD_ENTITY", MODEL, ENTITY, SCHEMA, "C_MDM", "c", "c.customer_id",
         "One customer", "Customer"),
        ("ADD_UNIQUE_KEY_WITH_COLUMNS", MODEL, ENTITY, "pk", "PRIMARY", "MDM key",
         "NATIVE", key_json),
        ("ADD_SEMANTIC_OBJECT", MODEL, "C360", ENTITY, "Customer 360"),
        ("ADD_ENTITY_REPRESENTATION", MODEL, ENTITY, "crm", "RELATION", SCHEMA,
         "C_CRM", 20, None),
        ("SET_REPRESENTATION_AUTHORITY", MODEL, ENTITY, "crm", "AUTHORITATIVE"),
    ]
    for name, column in (("cname", "NAME"), ("tier", "TIER")):
        steps.append(("ADD_DIMENSION", MODEL, "C360", ENTITY, name, f"c.{column}",
                      "VARCHAR(50)", name, name, None, True))
        steps.append(("ADD_ATTRIBUTE_BINDING", MODEL, "DIMENSION", name, "crm",
                      f"c.{column}", "PREFER", 1))
        steps.append(("SET_ATTRIBUTE_FUSION_POLICY", MODEL, "DIMENSION", name, "RECONCILE"))
    for step in steps:
        result = script(con, *step)
        if not isinstance(result, list):
            raise AssertionError(f"setup step {step[0]} failed: {result}")
    return script(con, "PUBLISH_MODEL", MODEL)


def main():
    con = connect()
    con.execute("ALTER SESSION SET QUERY_TIMEOUT = 30")
    teardown(con)
    try:
        published = build(con)
        if not isinstance(published, list):
            raise AssertionError(f"setup did not publish: {published}")
        check("model publishes clean", len(errors(con)), 0)

        # Break it from outside the admin surface, twice, so no single admin
        # call can return the model to zero errors.
        con.execute(f"ALTER TABLE {SCHEMA}.C_CRM DROP COLUMN NAME")
        con.execute(f"ALTER TABLE {SCHEMA}.C_CRM DROP COLUMN TIER")
        # Before validating: the baseline is the clean run from before the
        # breakage, so both errors read as new and the guard refuses, exactly as
        # it did before this change. That is the documented limit of the fix,
        # pinned here rather than only described.
        check("a stale baseline still refuses",
              script(con, "SET_ATTRIBUTE_FUSION_POLICY", MODEL, "DIMENSION",
                     "cname", "COALESCE"),
              "SEMANTIC_ADMIN_094")

        broken = errors(con)
        check("two independent errors", sorted(row["object_name"] for row in broken),
              ["cname@crm", "tier@crm"])
        check("both are the same rule", {row["rule_code"] for row in broken},
              {"SEMANTIC_MODEL_040"})

        recertified = script(con, "RECERTIFY_MODEL_IF_PUBLISHED", MODEL)
        check("recertify separates inherited from caused",
              recertified[0]["validation_status"], "ERROR_PRE_EXISTING")

        # The guard still holds. Dropping the representation while both
        # dimensions still reconcile removes the two contributors RECONCILE
        # needs, which is an error this change would cause.
        check("a change that introduces an error is still refused",
              script(con, "REMOVE_ENTITY_REPRESENTATION", MODEL, ENTITY, "crm"),
              "SEMANTIC_ADMIN_094")
        check("and is rolled back", sorted(row["object_name"] for row in errors(con)),
              ["cname@crm", "tier@crm"])

        # The trap is gone. Neither of these reaches zero errors, and under the
        # old rule each was refused for that reason alone.
        for name in ("cname", "tier"):
            check(f"policy change on {name} is accepted while the model is invalid",
                  outcome(script(con, "SET_ATTRIBUTE_FUSION_POLICY", MODEL,
                                 "DIMENSION", name, "PREFER")), "accepted")
        check("still invalid, and that is not this change's doing", len(errors(con)), 2)

        # With nothing reconciling, the same removal introduces nothing.
        check("the step that repairs is accepted",
              outcome(script(con, "REMOVE_ENTITY_REPRESENTATION", MODEL, ENTITY, "crm")),
              "accepted")
        check("model is clean again", len(errors(con)), 0)
        check("and republishes without DROP_MODEL",
              outcome(script(con, "PUBLISH_MODEL", MODEL)), "accepted")

        # SEMANTIC_MODEL_070 / _071 name what they counted. A draft model,
        # because on a published one the policy that provokes them is itself a
        # change that introduces an error, and is correctly refused.
        script(con, "CREATE_MODEL", CODES, "SEMANTIC_" + CODES.upper(),
               "split-code probe", None)
        for step in (
            ("ADD_ENTITY", CODES, ENTITY, SCHEMA, "C_MDM", "c", "c.customer_id",
             "One customer", "Customer"),
            ("ADD_UNIQUE_KEY_WITH_COLUMNS", CODES, ENTITY, "pk", "PRIMARY", "MDM key",
             "NATIVE", '[{"column_name":"CUSTOMER_ID","ordinal_position":1}]'),
            ("ADD_SEMANTIC_OBJECT", CODES, "C360", ENTITY, "Customer 360"),
            ("ADD_DIMENSION", CODES, "C360", ENTITY, "tier", "c.TIER",
             "VARCHAR(20)", "tier", "tier", None, True),
            # RECONCILE with the primary representation as the only contributor:
            # one binding, no authority among the bound.
            ("SET_ATTRIBUTE_FUSION_POLICY", CODES, "DIMENSION", "tier", "RECONCILE"),
        ):
            result = script(con, *step)
            if not isinstance(result, list):
                raise AssertionError(f"draft setup step {step[0]} failed: {result}")
        rows = execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL({sql_string(CODES)})")
        counted = {row["rule_code"]: row["message"] for row in rows
                   if row["rule_code"] in ("SEMANTIC_MODEL_070", "SEMANTIC_MODEL_071")}
        check("the split codes fire", sorted(counted), 
              ["SEMANTIC_MODEL_070", "SEMANTIC_MODEL_071"])
        check("_070 names the one representation it counted",
              "found 1 (primary)" in counted["SEMANTIC_MODEL_070"], True)
        check("_071 names the authorities it counted, and the contributors",
              "found 0 (none)" in counted["SEMANTIC_MODEL_071"]
              and "1 representation(s) that bind it (primary)" in counted["SEMANTIC_MODEL_071"],
              True)
    finally:
        teardown(con)
        con.close()
    print("verify_published_repair_path: OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
