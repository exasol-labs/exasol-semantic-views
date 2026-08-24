#!/usr/bin/env python3
"""Verify that a choice between safe relationship paths is reported, not hidden.

A path proof measures ambiguity as "more than one *shortest* safe path" and
refuses that outright: validation rejects the metric/dimension pair
(`SEMANTIC_MODEL_030` / `AMBIGUOUS_RELATIONSHIP_PATH`) and no query compiles.
An alternative of a *different* length passed the same gate silently — the
shortest path simply won, with `warnings: []` and a proof whose
`candidate_paths` was empty. Path length is not a statement about meaning: the
longer path can attribute a fact row to a different dimension row, so the
choice decides the number.

This builds a disposable model with exactly that shape — a shortcut edge to
`beta`, plus a two-step walk through `alpha` that lands on a different `beta`
row — and asserts:

  1. authoring — `VALIDATE_MODEL` reports `SEMANTIC_MODEL_055` (WARNING) naming
     the selected path and the one not selected, and the pair stays valid;
  2. compiling — the plan carries a `RELATIONSHIP_PATH_ALTERNATIVES` warning and
     the LEGACY_JOIN proof names every candidate with its selection reason;
  3. STRICT_GRAIN refuses the same request (`RELATIONSHIP_PATH_AMBIGUOUS`);
  4. an equal-length tie is still an authoring-time ERROR;
  5. the two paths really do return different numbers, so the warning is about
     a live choice rather than a redundant declaration.
"""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any

MODEL = "path_ambiguity_verify"
SCHEMA = "PATH_AMBIGUITY_VERIFY"


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def execute(con: Any, sql: str) -> list[tuple[Any, ...]]:
    statement = con.execute(sql)
    if statement.num_columns == 0:
        return []
    return [tuple(row) for row in statement.fetchall()]


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def compile_request(con: Any, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    row = execute(
        con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    )[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "generated_sql": row[4],
        "plan": json.loads(row[5]) if row[5] else {},
    }


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_contains(name: str, haystack: str, needle: str) -> None:
    if needle not in (haystack or ""):
        raise AssertionError(f"{name}: {needle!r} not found in {haystack!r}")
    print(f"ok {name}: found {needle!r}")


def expect_error(con: Any, sql: str, *fragments: str) -> str:
    try:
        execute(con, sql)
    except Exception as exc:  # noqa: BLE001 - the refusal is the assertion
        message = str(exc)
        for fragment in fragments:
            if fragment not in message:
                raise AssertionError(f"expected {fragment!r} in error, got: {message}") from exc
        return message
    raise AssertionError(f"statement was accepted: {sql}")


def issues(con: Any, rule_code: str) -> list[str]:
    return [
        str(row[0])
        for row in execute(
            con,
            "SELECT MESSAGE FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES "
            f"WHERE MODEL_NAME = {sql_string(MODEL)} "
            f"AND RULE_CODE = {sql_string(rule_code)}",
        )
    ]


def build_fixture(con: Any) -> None:
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    con.execute(
        f"CREATE TABLE {SCHEMA}.BETAS "
        "(BETA_ID DECIMAL(18,0) PRIMARY KEY, BETA_NAME VARCHAR(40) NOT NULL)"
    )
    con.execute(
        f"CREATE TABLE {SCHEMA}.ALPHAS (ALPHA_ID DECIMAL(18,0) PRIMARY KEY, "
        "BETA_ID DECIMAL(18,0) NOT NULL)"
    )
    con.execute(
        f"CREATE TABLE {SCHEMA}.FACTS (FACT_ID DECIMAL(18,0) PRIMARY KEY, "
        "ALPHA_ID DECIMAL(18,0) NOT NULL, BETA_ID DECIMAL(18,0) NOT NULL, "
        "AMOUNT DECIMAL(18,2) NOT NULL)"
    )
    # The fact row points straight at DIRECT, while its alpha points at
    # VIA_ALPHA. Both walks are safe; they disagree about the answer.
    con.execute(f"INSERT INTO {SCHEMA}.BETAS VALUES (1, 'DIRECT'), (2, 'VIA_ALPHA')")
    con.execute(f"INSERT INTO {SCHEMA}.ALPHAS VALUES (1, 2)")
    con.execute(f"INSERT INTO {SCHEMA}.FACTS VALUES (1, 1, 1, 100.00)")

    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL("
        f"'{MODEL}', 'SEMANTIC_{SCHEMA}', 'Disposable path-ambiguity model', NULL)",
    )
    for entity, table, alias, key_expr in (
        ("fact", "FACTS", "f", "f.fact_id"),
        ("alpha", "ALPHAS", "a", "a.alpha_id"),
        ("beta", "BETAS", "b", "b.beta_id"),
    ):
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
            f"'{MODEL}', '{entity}', '{SCHEMA}', '{table}', '{alias}', '{key_expr}', "
            f"'One row per {entity}', '{entity} grain')",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
            f"'{MODEL}', '{entity}', '{entity}_pk', 'PRIMARY', 'Row grain', 'NATIVE')",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
            f"'{MODEL}', '{entity}', '{entity}_pk', '{entity}_id', NULL, 1)",
        )

    for name, from_entity, to_entity, condition, from_column in (
        ("fact_to_beta", "fact", "beta", "f.beta_id = b.beta_id", "beta_id"),
        ("fact_to_alpha", "fact", "alpha", "f.alpha_id = a.alpha_id", "alpha_id"),
        ("alpha_to_beta", "alpha", "beta", "a.beta_id = b.beta_id", "beta_id"),
    ):
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP("
            f"'{MODEL}', '{name}', '{from_entity}', '{to_entity}', "
            f"'{condition}', 'MANY_TO_ONE', 'LEFT', NULL)",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
            f"'{MODEL}', '{name}', '{from_column}', NULL, "
            f"'{to_entity}_id', NULL, 1)",
        )

    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT("
        f"'{MODEL}', 'PROBE', 'fact', 'Fact-grain object')",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
        f"'{MODEL}', 'PROBE', 'beta', 'beta_name', 'b.beta_name', 'VARCHAR(40)', "
        "'Beta Name', 'Beta reached by the selected path', NULL, TRUE)",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT("
        f"'{MODEL}', 'fact', 'amount', 'f.amount', 'DECIMAL(18,2)', 'ADDITIVE', "
        "'Amount', 'Amount on the fact row', FALSE, TRUE)",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC("
        f"'{MODEL}', 'PROBE', 'total_amount', 'SUM(amount)', NULL, 'ADDITIVE', "
        "'fact', 'DECIMAL(18,2)', 'Total Amount', 'Amount across fact rows', "
        "'currency', FALSE, TRUE)",
    )


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
        except Exception:
            pass
        build_fixture(con)
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")

        # 1. Authoring lane: the choice is reported, and the pair stays usable.
        assert_equal("model validates without errors", execute(
            con,
            "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES "
            f"WHERE MODEL_NAME = {sql_string(MODEL)} AND SEVERITY = 'ERROR'",
        )[0][0], 0)
        warnings = issues(con, "SEMANTIC_MODEL_055")
        assert_equal("one path-alternative warning", len(warnings), 1)
        print(f"   {warnings[0]}")
        assert_contains("warning names the entities", warnings[0],
                        "Entity fact reaches entity beta")
        assert_contains("warning names the selected path", warnings[0],
                        "selects fact_to_beta because it is the shortest")
        assert_contains("warning names the path not selected", warnings[0],
                        "not selected: fact_to_alpha > alpha_to_beta")
        assert_equal("the pair is still valid", execute(
            con,
            "SELECT IS_VALID, RELATIONSHIP_PATH FROM SEMANTIC_CATALOG.METRIC_DIMENSION_MATRIX "
            f"WHERE MODEL_NAME = {sql_string(MODEL)}",
        )[0], (True, "fact_to_beta"))

        # 2. Compiling lane: the plan says what it chose over what.
        compiled = compile_request(con, {
            "model": MODEL, "object": "PROBE", "metrics": ["total_amount"],
            "dimensions": ["beta_name"], "client": "verify_path_ambiguity",
        })
        assert_equal("request compiles", compiled["status"], "OK")
        assert_equal("selected path", compiled["plan"]["relationship_paths"], ["fact_to_beta"])
        plan_warnings = compiled["plan"]["warnings"]
        assert_equal("one plan warning", len(plan_warnings), 1)
        warning = plan_warnings[0]
        assert_equal("plan warning code", warning["code"], "RELATIONSHIP_PATH_ALTERNATIVES")
        assert_equal("plan warning severity", warning["severity"], "WARNING")
        assert_equal("plan warning target", warning["target_entity"], "beta")
        assert_equal("plan warning selected path", warning["selected_path"], "fact_to_beta")
        assert_equal("plan warning selection reason",
                     warning["selection_reason"], "SHORTEST_SAFE_PATH")
        assert_equal("plan warning alternates",
                     warning["alternate_paths"], ["fact_to_alpha > alpha_to_beta"])
        # Name no remedy that does not work: PATH_PRIORITY does not select here.
        assert_contains("plan warning does not invent a remedy",
                        warning["message"], "PATH_PRIORITY does not choose between them")

        proofs = [
            proof for proof in compiled["plan"]["logical_plan"]["relationship_proofs"]
            if proof.get("mode") == "LEGACY_JOIN"
        ]
        assert_equal("one legacy proof", len(proofs), 1)
        assert_equal("proof lists every candidate", proofs[0]["candidate_paths"],
                     ["fact_to_beta", "fact_to_alpha > alpha_to_beta"])
        assert_equal("proof names its selection reason",
                     proofs[0]["selection_reason"], "SHORTEST_SAFE_PATH")

        # 3. STRICT_GRAIN refuses rather than choosing.
        strict = compile_request(con, {
            "model": MODEL, "object": "PROBE", "metrics": ["total_amount"],
            "dimensions": ["beta_name"], "proof_mode": "STRICT_GRAIN",
            "client": "verify_path_ambiguity",
        })
        assert_equal("strict mode refuses", strict["status"], "ERROR")
        assert_contains("strict refusal names ambiguity", strict["error_message"],
                        "RELATIONSHIP_PATH_AMBIGUOUS")

        # 4. The warning is not a downgrade of the tie rule: an equal-length
        # alternative is still refused at authoring time.
        con.execute(f"ALTER TABLE {SCHEMA}.FACTS ADD COLUMN BETA_ID_ALT DECIMAL(18,0)")
        con.execute(f"UPDATE {SCHEMA}.FACTS SET BETA_ID_ALT = 2")
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP("
            f"'{MODEL}', 'fact_to_beta_alt', 'fact', 'beta', "
            "'f.beta_id_alt = b.beta_id', 'MANY_TO_ONE', 'LEFT', NULL)",
        )
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING("
            f"'{MODEL}', 'fact_to_beta_alt', 'beta_id_alt', NULL, 'beta_id', NULL, 1)",
        )
        execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")
        tie = issues(con, "SEMANTIC_MODEL_030")
        assert_equal("a tie in length is still an error", len(tie), 1)
        assert_contains("tie names ambiguity", tie[0], "AMBIGUOUS_RELATIONSHIP_PATH")
        tied_request = compile_request(con, {
            "model": MODEL, "object": "PROBE", "metrics": ["total_amount"],
            "dimensions": ["beta_name"], "client": "verify_path_ambiguity",
        })
        assert_equal("a tie serves nothing", tied_request["status"], "ERROR")
        execute(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_RELATIONSHIP_KEY_MAPPING("
            f"'{MODEL}', 'fact_to_beta_alt', 1)",
        )
        execute(
            con,
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.REMOVE_RELATIONSHIP('{MODEL}', 'fact_to_beta_alt')",
        )

        # 5. The choice is live: the paths disagree about the answer, so a
        # fixture that stopped disagreeing would stop testing anything.
        selected = execute(con, compiled["generated_sql"])
        alternate = execute(
            con,
            f"SELECT b.beta_name, SUM(f.amount) FROM {SCHEMA}.FACTS f "
            f"LEFT JOIN {SCHEMA}.ALPHAS a ON f.alpha_id = a.alpha_id "
            f"LEFT JOIN {SCHEMA}.BETAS b ON a.beta_id = b.beta_id GROUP BY b.beta_name",
        )
        print(f"   selected path: {selected}")
        print(f"   alternate path: {alternate}")
        if selected == alternate:
            raise AssertionError(
                "the two paths agree, so this fixture no longer exercises a "
                f"consequential choice ({selected})"
            )
        print("ok the reported choice changes the answer")

        print()
        print("path-ambiguity reporting verified.")
        return 0
    finally:
        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
        except Exception:
            pass
        try:
            con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
        except Exception:
            pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
