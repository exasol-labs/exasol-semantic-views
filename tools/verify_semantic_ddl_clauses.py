#!/usr/bin/env python3
"""Verify that the semantic DDL refuses a clause it does not recognise.

A clause is found by matching a known keyword and its value runs to the next
one, so an unknown keyword used to be absorbed into the previous clause's value
(BUG-25): `RETURNS DECIMAL(18,2) UNIT 'kg'` stored the type
`DECIMAL(18,2) UNIT 'kg'`, validated clean, and failed only at PUBLISH_MODEL.
This asserts that:

- an unknown clause is refused by name (SEMANTIC_DDL_039), in a dry run too;
- UNIT is a real metric clause: it lands in UNIT_HINT and survives export;
- a malformed declared type fails ADD_METRIC and VALIDATE_MODEL
  (SEMANTIC_MODEL_073) instead of waiting for publication.
"""

from __future__ import annotations

from typing import Any
import importlib.util
from pathlib import Path

# Connection defaults, SQL escaping and named result reads live in
# tools/verify_support.py so verifiers do not each carry their own. See the
# ratchet in tests/test_conventions.py.
_SUPPORT = importlib.util.spec_from_file_location(
    "verify_support", Path(__file__).with_name("verify_support.py"))
support = importlib.util.module_from_spec(_SUPPORT)
_SUPPORT.loader.exec_module(support)

METRIC = "zz_ddl_clause_co2"
ADD_METRIC_NAME = "zz_ddl_clause_added"
BAD_TYPE = "DECIMAL(18,2) UNIT 'kg'"


def definition(clause: str) -> str:
    return (
        f"ALTER SEMANTIC VIEW sales.SALES ADD OR REPLACE METRIC {METRIC} "
        "AS SUM(net_revenue) ON ENTITY order_line "
        f"RETURNS DECIMAL(18,2) {clause} DISPLAY 'CO2' COMMENT 'c' ADDITIVE PUBLIC"
    )


def apply(con: Any, sql: str, dry_run: bool) -> dict[str, Any]:
    return support.named_row(support.run_script(
        con, "APPLY_SEMANTIC_DEFINITION", sql, dry_run)) or {}


def metric_row(con: Any) -> tuple[Any, ...] | None:
    return con.execute(
        "SELECT DATA_TYPE, UNIT_HINT FROM SYS_SEMANTIC.METRICS mt "
        "JOIN SYS_SEMANTIC.MODELS m ON m.MODEL_ID = mt.MODEL_ID "
        f"WHERE m.MODEL_NAME = 'sales' AND mt.METRIC_NAME = '{METRIC}' "
        "AND mt.STATUS = 'ACTIVE'").fetchone()


def drop_metric(con: Any) -> None:
    # The drop validates the model, so a corrupted type left by the
    # VALIDATE_MODEL step would make it roll back.
    con.execute("UPDATE SYS_SEMANTIC.METRICS SET DATA_TYPE = 'DECIMAL(18,2)' "
                f"WHERE METRIC_NAME = '{METRIC}' AND STATUS = 'ACTIVE'")
    result = apply(con, f"ALTER SEMANTIC VIEW sales.SALES DROP METRIC {METRIC}", False)
    if metric_row(con) is not None:
        raise AssertionError(f"could not drop {METRIC}: {result}")


def main() -> int:
    con = support.connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")
        for clause, word in (("WOMBAT 'purple'", "WOMBAT"),
                             ("FORMATT 'currency'", "FORMATT")):
            for dry_run in (True, False):
                result = apply(con, definition(clause), dry_run)
                text = str(result)
                if result.get("status") != "ERROR" or "SEMANTIC_DDL_039" not in text \
                        or f"unrecognised clause {word}" not in text:
                    raise AssertionError(f"{clause} was not refused by name: {result}")
            if metric_row(con) is not None:
                raise AssertionError(f"{clause} left a metric behind")
        print("ok unknown clause: refused by name in dry run and apply, nothing stored")

        result = apply(con, definition("UNIT 'kg'"), False)
        if result.get("status") != "OK":
            raise AssertionError(f"UNIT clause refused: {result}")
        if metric_row(con) != ("DECIMAL(18,2)", "kg"):
            raise AssertionError(f"UNIT did not land in UNIT_HINT: {metric_row(con)}")
        issues = support.validate_model(con, "sales")
        if any(issue.get("object_name") == METRIC
               and issue.get("rule_code") == "SEMANTIC_MODEL_022" for issue in issues):
            raise AssertionError("SEMANTIC_MODEL_022 still asks for a unit that is set")
        exported = con.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', "
            f"'{METRIC}')").fetchall()
        if "UNIT 'kg'" not in str(exported):
            raise AssertionError(f"export dropped the unit: {exported}")
        print("ok UNIT clause: stored as UNIT_HINT, satisfies SEMANTIC_MODEL_022, exported")

        # A catalog written before the parser refused it still holds the
        # absorbed type; VALIDATE_MODEL must say so instead of PUBLISH_MODEL.
        con.execute(
            f"UPDATE SYS_SEMANTIC.METRICS SET DATA_TYPE = {support.sql_string(BAD_TYPE)} "
            f"WHERE METRIC_NAME = '{METRIC}' AND STATUS = 'ACTIVE'")
        refused = [issue for issue in support.validate_model(con, "sales")
                   if issue.get("rule_code") == "SEMANTIC_MODEL_073"]
        if [(issue.get("object_name"), str(issue.get("severity")).upper())
                for issue in refused] != [(METRIC, "ERROR")]:
            raise AssertionError(f"expected one SEMANTIC_MODEL_073 error: {refused}")
        if BAD_TYPE not in str(refused[0].get("message")):
            raise AssertionError(f"message does not name the type: {refused[0]}")
        print("ok VALIDATE_MODEL: an absorbed clause in DATA_TYPE is SEMANTIC_MODEL_073")
        drop_metric(con)

        try:
            # A dropped metric stays as an INACTIVE row whose name ADD_METRIC
            # refuses as a duplicate, so this step uses its own name.
            support.run_script(con, "ADD_METRIC", "sales", "SALES", ADD_METRIC_NAME,
                               "SUM(net_revenue)", None, "ADDITIVE", "order_line",
                               BAD_TYPE, "CO2", "c", None, False, False)
        except Exception as exc:
            if "SEMANTIC_MODEL_073" not in str(exc):
                raise AssertionError(f"unexpected ADD_METRIC refusal: {exc}") from exc
        else:
            raise AssertionError("ADD_METRIC accepted a type that is not an Exasol type")
        if con.execute("SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS "
                       f"WHERE METRIC_NAME = '{ADD_METRIC_NAME}'").fetchone()[0]:
            raise AssertionError("refused ADD_METRIC left a metric behind")
        print("ok ADD_METRIC: a malformed DATA_TYPE is refused with SEMANTIC_MODEL_073")
        return 0
    finally:
        try:
            if metric_row(con) is not None:
                drop_metric(con)
        finally:
            con.close()


if __name__ == "__main__":
    raise SystemExit(main())
