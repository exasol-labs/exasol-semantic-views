#!/usr/bin/env python3
"""The controls explain themselves: one surface for what the layer vouches for and accepts.

An unexplainable control is an unusable one. Steps 4 through 9 added real
enforcement -- a trust boundary, principal-scoped catalog reads, a fan-out
guard, frozen-view tracking, policy columns that refuse -- and every one of them
is invisible at the point where the questions actually get asked:

    "why can I not see this metric"
    "why is my number different from my colleague's"

Both are asked after the fact, about a statement that already ran, by someone
who should not have to read generated SQL to answer them.

So: `GOVERNANCE_FOR_MODEL` says what a model vouches for, in a sentence.
`QUERY_CAPABILITIES` says what the layer accepts and what it says when it does
not. `PLAN_JSON` carries a `governance` block recording what was in force when
the SQL was produced, and `EXPLAIN_COMPILED_SQL` renders it in prose.

The check that keeps the capability list honest is here rather than in a
comment: every refusal code it names must be one the compiler actually emits.
A published contract that has drifted from the code is worse than none, because
it is believed.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect, compile_request, sql_string  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
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


def main() -> None:
    con = connect()
    con.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")

    # 1. one row per model, and a sentence an operator can act on
    rows = con.execute(
        "SELECT MODEL_NAME, GOVERNANCE_MODE, VISIBLE_TO_CALLER, GOVERNED_SOURCES,"
        " RAW_SOURCES, DIVERGENT_SOURCES, FROZEN_VIEWS, SUMMARY"
        " FROM SEMANTIC_CATALOG.GOVERNANCE_FOR_MODEL ORDER BY MODEL_NAME").fetchall()
    check("every model has a governance row",
          len(rows) == con.execute("SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS").fetchone()[0],
          True)
    sales = next((r for r in rows if r[0] == MODEL), None)
    if sales is None:
        fail("the example model is present", "not found")
    else:
        check("it is visible to the caller", sales[2], True)
        check("and its summary says what mode it is in",
              sales[1].lower() in (sales[7] or "").lower(), True)
        check("the summary is a sentence, not a shrug", len(sales[7] or "") > 80, True)

    # 2. the capability list names only codes the compiler can emit
    capabilities = con.execute(
        "SELECT SHAPE, SUPPORT, REFUSAL_CODE FROM SEMANTIC_CATALOG.QUERY_CAPABILITIES").fetchall()
    check("the capability list is published", len(capabilities) >= 10, True)
    emitted = set()
    for source in ("lua/semantic_layer/compiler/request_json.lua",
                   "lua/semantic_layer/admin/validator.lua"):
        text = (ROOT / source).read_text()
        emitted.update(re.findall(r"SEMANTIC_[A-Z]+_\d{3}", text))
        # codes built from the lane prefix, e.g. error_prefix .. "_024"
        for suffix in re.findall(r'error_prefix \.\. "_(\d{3})"', text):
            emitted.add(f"SEMANTIC_REQUEST_{suffix}")
            emitted.add(f"SEMANTIC_QUERY_{suffix}")
    unknown = [r[2] for r in capabilities if r[2] and r[2] not in emitted]
    check("every refusal code it names is one the compiler emits", unknown, [])

    # 3. the plan records what was in force, and EXPLAIN says it in prose
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    con.commit()
    request = {"model": MODEL, "object": OBJECT,
               "dimensions": ["customer_region"], "metrics": ["total_revenue"]}
    compiled = compile_request(con, request)
    check("the request compiles", compiled["status"], "OK")
    plan = json.loads(compiled["plan_json"] or "{}")
    governance = plan.get("governance")
    if not isinstance(governance, dict):
        fail("the plan carries a governance block", f"got {governance!r}")
    else:
        check("it records who compiled it", governance.get("compiled_by"), "SYS")
        check("and the mode in force", governance.get("governance_mode"), "OPEN")
        check("and classifies every relation the SQL reads",
              len(governance.get("sources") or []) > 0, True)
        classes = {s["trust_class"] for s in governance.get("sources") or []}
        check("with a trust class, not a bare name",
              all(isinstance(c, str) and c for c in classes), True)

    statement = con.execute(
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(%s)" % sql_string(json.dumps(request)))
    names = [n.lower() for n in statement.columns().keys()]
    handle = dict(zip(names, statement.fetchone()))["agent_request_id"]
    explained = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL('AGENT_REQUEST', {handle})")
    columns = [n for n in explained.columns().keys()]
    row = dict(zip(columns, explained.fetchone()))
    check("EXPLAIN publishes a governance column", "GOVERNANCE" in columns, True)
    narrative = row.get("GOVERNANCE") or ""
    check("and it names the principal", "SYS" in narrative, True)
    check("and says what the layer does or does not vouch for",
          ("does not vouch for" in narrative) or ("vouches for" in narrative), True)
    check("in prose, not JSON", narrative.strip().startswith("{"), False)

    con.close()
    if failures:
        print(f"\n{len(failures)} failure(s): {', '.join(failures)}")
        raise SystemExit(1)
    print("ok governance surfacing: what the layer vouches for and accepts, in one place")


if __name__ == "__main__":
    main()
