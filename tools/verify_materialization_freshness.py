#!/usr/bin/env python3
"""Verify that the materialization registry records freshness state and acts on it.

The registry used to hold a free-text FRESHNESS_POLICY and nothing else, so it
could not answer "is this stale right now?" -- and free text it could not act on
was stored anyway and rejected on every compile (BUG-27). This asserts against
the live sales model that:

- a policy the selector cannot act on is refused at registration;
- MARK_MATERIALIZATION_REFRESHED records when, how many rows (measured), and
  which source snapshot, and the catalog view reports AGE_SECONDS / IS_STALE;
- a MAX_AGE materialization is chosen only while fresh -- stale or never
  refreshed, the live sources answer -- and the plan says which and why;
- a compile that chose a time-bounded materialization is not cached.

Order-dependent like verify_materialization_selection.py: it expects the
example's sales_revenue_by_region, which it sets INACTIVE for the duration and
restores afterwards.
"""

from __future__ import annotations

from typing import Any
import importlib.util
import json
from pathlib import Path

# Connection defaults, SQL escaping and named result reads live in
# tools/verify_support.py so verifiers do not each carry their own. See the
# ratchet in tests/test_conventions.py.
_SUPPORT = importlib.util.spec_from_file_location(
    "verify_support", Path(__file__).with_name("verify_support.py"))
support = importlib.util.module_from_spec(_SUPPORT)
_SUPPORT.loader.exec_module(support)

NAME = "zz_fresh_revenue"
TABLE = "MART.ZZ_FRESH_REVENUE"
EXAMPLE = "sales_revenue_by_region"
REQUEST = {"model": "sales", "object": "SALES", "metrics": ["total_revenue"],
           "dimensions": ["customer_region"], "client": "verify_materialization_freshness"}


def registry_row(con: Any) -> dict[str, Any]:
    return support.named_row(con.execute(
        "SELECT LAST_REFRESHED_AT, AGE_SECONDS, REFRESHED_ROW_COUNT, SOURCE_SNAPSHOT,"
        " FRESHNESS_POLICY, FRESHNESS_MAX_AGE_SECONDS, IS_STALE"
        " FROM SEMANTIC_CATALOG.MATERIALIZATIONS"
        f" WHERE MODEL_NAME = 'sales' AND MATERIALIZATION_NAME = '{NAME}'")) or {}


def compile_plan(con: Any) -> tuple[dict[str, Any], dict[str, Any]]:
    result = support.compile_request(con, REQUEST)
    if result.get("status") != "OK":
        raise AssertionError(f"request did not compile: {result}")
    return result, json.loads(result["plan_json"])


def selected(plan: dict[str, Any]) -> str | None:
    chosen = plan.get("selected_materialization")
    return chosen.get("materialization_name") if isinstance(chosen, dict) else None


def rejection(plan: dict[str, Any]) -> str | None:
    decision = plan.get("materialization_decision") or {}
    for entry in decision.get("rejected_materializations") or []:
        if entry.get("materialization_name") == NAME:
            return entry.get("reason_code")
    return None


def answer(con: Any, result: dict[str, Any]) -> list[tuple[Any, ...]]:
    return sorted((str(r[0]), float(r[1])) for r in con.execute(result["generated_sql"]).fetchall())


def mark(con: Any, refreshed_at: str | None, snapshot: str | None) -> dict[str, Any]:
    return support.named_row(support.run_script(
        con, "MARK_MATERIALIZATION_REFRESHED", "sales", NAME, refreshed_at, snapshot)) or {}


def cleanup(con: Any) -> None:
    con.execute(
        "DELETE FROM SYS_SEMANTIC.MATERIALIZATION_COLUMNS WHERE MATERIALIZATION_ID IN ("
        f" SELECT MATERIALIZATION_ID FROM SYS_SEMANTIC.MATERIALIZATIONS WHERE MATERIALIZATION_NAME = '{NAME}')")
    con.execute(f"DELETE FROM SYS_SEMANTIC.MATERIALIZATIONS WHERE MATERIALIZATION_NAME = '{NAME}'")
    con.execute(f"DROP TABLE IF EXISTS {TABLE}")
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")


def main() -> int:
    con = support.connect()
    example_status = con.execute(
        "SELECT STATUS FROM SEMANTIC_CATALOG.MATERIALIZATIONS"
        f" WHERE MODEL_NAME = 'sales' AND MATERIALIZATION_NAME = '{EXAMPLE}'").fetchone()
    try:
        cleanup(con)
        if example_status is not None:
            support.run_script(con, "SET_MATERIALIZATION_STATUS", "sales", EXAMPLE, "INACTIVE")
        live_result, live_plan = compile_plan(con)
        live = answer(con, live_result)

        # Deliberately different from the live answer, so a stale read shows.
        con.execute(f"CREATE TABLE {TABLE} AS SELECT CUSTOMER_REGION, TOTAL_REVENUE * 2 AS TOTAL_REVENUE"
                    " FROM MART.SALES_REVENUE_BY_REGION")
        try:
            support.run_script(con, "REGISTER_MATERIALIZATION", "sales", NAME, "MART",
                               "ZZ_FRESH_REVENUE", "AGGREGATE", "dbt run --select gold (hourly)")
        except Exception as exc:
            if "SEMANTIC_ADMIN_003: invalid FRESHNESS_POLICY" not in str(exc) \
                    or "MAX_AGE <n> MINUTES|HOURS|DAYS" not in str(exc):
                raise AssertionError(f"unexpected refusal: {exc}") from exc
        else:
            raise AssertionError("a free-text freshness policy was registered")
        print("ok REGISTER_MATERIALIZATION: a policy the selector cannot act on is refused")

        support.run_script(con, "REGISTER_MATERIALIZATION", "sales", NAME, "MART",
                           "ZZ_FRESH_REVENUE", "AGGREGATE", "max_age 1 hours")
        support.run_script(con, "ADD_MATERIALIZATION_COLUMN", "sales", NAME, "DIMENSION",
                           "customer_region", "CUSTOMER_REGION", "DIRECT")
        support.run_script(con, "ADD_MATERIALIZATION_COLUMN", "sales", NAME, "METRIC",
                           "total_revenue", "TOTAL_REVENUE", "SUM")
        row = registry_row(con)
        if (row.get("freshness_policy"), row.get("freshness_max_age_seconds"),
                row.get("is_stale"), row.get("last_refreshed_at")) != ("MAX_AGE 1 HOURS", 3600, True, None):
            raise AssertionError(f"unexpected registry row before any refresh: {row}")
        result, plan = compile_plan(con)
        if selected(plan) is not None or rejection(plan) != "NEVER_REFRESHED" or answer(con, result) != live:
            raise AssertionError(f"never-refreshed materialization was used: {plan}")
        print("ok never refreshed: IS_STALE, NEVER_REFRESHED in the plan, live answer")

        marked = mark(con, None, "lake@41")
        count = con.execute(f"SELECT COUNT(*) FROM {TABLE}").fetchone()[0]
        if marked.get("refreshed_row_count") != count or marked.get("source_snapshot") != "lake@41":
            raise AssertionError(f"MARK did not record the measured state: {marked}")
        row = registry_row(con)
        if row.get("is_stale") is not False or row.get("age_seconds") is None \
                or float(row["age_seconds"]) > 60 or row.get("refreshed_row_count") != count:
            raise AssertionError(f"registry does not report a fresh materialization: {row}")
        result, plan = compile_plan(con)
        freshness = (plan.get("materialization_decision") or {}).get("freshness") or {}
        if selected(plan) != NAME or freshness.get("source_snapshot") != "lake@41" \
                or freshness.get("time_bounded") is not True:
            raise AssertionError(f"fresh materialization not chosen with provenance: {plan}")
        if answer(con, result) == live:
            raise AssertionError("the fresh read did not come from the materialization")
        cached = con.execute("SELECT COUNT(*) FROM SYS_SEMANTIC.COMPILE_CACHE"
                             f" WHERE PLAN_JSON LIKE '%{NAME}%' AND PLAN_JSON LIKE '%\"selected_materialization\":{{%'"
                             ).fetchone()[0]
        if cached:
            raise AssertionError("a compile that chose a time-bounded materialization was cached")
        print("ok refreshed: measured row count, snapshot id, chosen with freshness provenance, not cached")

        mark(con, "2000-01-01 00:00:00", "lake@1")
        result, plan = compile_plan(con)
        if selected(plan) is not None or rejection(plan) != "STALE" or answer(con, result) != live:
            raise AssertionError(f"stale materialization was used: {plan}")
        if registry_row(con).get("is_stale") is not True:
            raise AssertionError("registry does not report the stale materialization")
        print("ok stale: IS_STALE, STALE in the plan, live answer")

        for bad in ("2999-01-01 00:00:00", "yesterday-ish"):
            try:
                mark(con, bad, None)
            except Exception as exc:
                if "SEMANTIC_ADMIN_222" not in str(exc):
                    raise AssertionError(f"unexpected refusal for {bad}: {exc}") from exc
            else:
                raise AssertionError(f"REFRESHED_AT {bad!r} was accepted")
        print("ok MARK_MATERIALIZATION_REFRESHED: a future or unreadable REFRESHED_AT is refused")
        if selected(live_plan) is not None:
            raise AssertionError("baseline unexpectedly used a materialization")
        return 0
    finally:
        try:
            cleanup(con)
            if example_status is not None:
                support.run_script(con, "SET_MATERIALIZATION_STATUS", "sales", EXAMPLE,
                                   example_status[0])
        finally:
            con.close()


if __name__ == "__main__":
    raise SystemExit(main())
