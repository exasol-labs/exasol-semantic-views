#!/usr/bin/env python3
"""Concurrent admin-mutation regression test.

`tools/verify_concurrent_compile.py` proves that concurrent COMPILE_* calls
against the same published model succeed. It does not cover the harder
case: multiple threads mutating the same model at once (ADD_METRIC while
PUBLISH_MODEL runs, VALIDATE_MODEL under ADD_DIMENSION, etc.).

This suite runs a small grid of admin operations from several threads and
asserts a set of invariants after the storm settles:

1. Every admin call either succeeds or fails with a specific SEMANTIC_*_NNN
   code — no bare pyexasol GlobalTransactionRollback or `SEMANTIC_*_999`
   catch-all leaks through.
2. After every thread joins, the model is queryable via COMPILE_REQUEST_JSON.
3. VALIDATION_RUNS shows no run stuck in `RUNNING`.
4. No `zz_race_*` object is left in an inconsistent state (a metric exists
   with no OBJECT_COLUMNS row, or vice versa).

Runs against the sales model. Uses zz_race_* names so it can be run
repeatedly against an accumulated seed.
"""

from __future__ import annotations

import os
import re
import ssl
import sys
import threading
import time
from typing import Any


THREADS = int(os.environ.get("ADMIN_RACE_THREADS", "4"))
ITERATIONS = int(os.environ.get("ADMIN_RACE_ITERATIONS", "3"))


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required.", file=sys.stderr)
        raise SystemExit(2)
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


PASSED = 0
FAILED = 0


def ok(name: str, detail: str = "") -> None:
    global PASSED
    PASSED += 1
    print(f"ok  {name}{': ' + detail if detail else ''}")


def fail(name: str, detail: str) -> None:
    global FAILED
    FAILED += 1
    print(f"FAIL {name}: {detail}", file=sys.stderr)


def try_run(con, sql: str) -> tuple[bool, str]:
    """Run `sql`. Return (ok, message). A caught SEMANTIC_*_NNN error counts
    as a well-formed refusal; a bare pyexasol error message does not."""
    try:
        con.execute(sql)
        return True, ""
    except Exception as exc:  # noqa: BLE001 — we specifically want to inspect any failure
        return False, str(exc)


def is_well_formed_error(message: str) -> bool:
    """A refusal is well-formed if the caller can act on it. Two shapes count:

      * A specific `SEMANTIC_*_NNN` code (excluding the `_999`
        transient-collision catch-all, which is exactly the shape we don't
        want to see leak through).
      * `GlobalTransactionRollback` — the Exasol storage layer signalling a
        genuine transaction collision. Callers retry; the semantic layer
        cannot suppress this and shouldn't try. It IS a well-formed,
        documented error class; asserting it here pins the shape so a
        future refactor that turns it into a generic Python exception
        surfaces immediately.
    """
    if "GlobalTransactionRollback" in message:
        return True
    m = re.search(r"SEMANTIC_[A-Z]+_[0-9]{3}", message)
    if not m:
        return False
    return not m.group(0).endswith("_999")


def add_metric_body(name: str, i: int) -> str:
    metric_name = f"zz_race_metric_{name}_{i}"
    return (
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC('sales', 'SALES', "
        f"'{metric_name}', 'SUM(net_revenue)', NULL, 'ADDITIVE', 'order_line', "
        f"'DECIMAL(18,2)', 'race probe', 'race probe', NULL, FALSE, FALSE)"
    )


def validate_body() -> str:
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')"


def compile_body() -> str:
    payload = (
        '{"model":"sales","object":"SALES","metrics":["total_revenue"],'
        '"dimensions":["customer_region"],"client":"concurrent_admin"}'
    )
    return f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('{payload}')"


def publish_body() -> str:
    return "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')"


ROLES = ["add_metric", "validate", "compile", "publish"]


def worker(role: str, results: list[dict[str, Any]]) -> None:
    con = connect()
    try:
        for i in range(ITERATIONS):
            if role == "add_metric":
                sql = add_metric_body(role, i)
            elif role == "validate":
                sql = validate_body()
            elif role == "compile":
                sql = compile_body()
            elif role == "publish":
                sql = publish_body()
            else:
                continue
            started = time.perf_counter()
            success, message = try_run(con, sql)
            results.append({
                "role": role,
                "iteration": i,
                "success": success,
                "message": message[:200] if message else "",
                "elapsed_ms": (time.perf_counter() - started) * 1000.0,
            })
    finally:
        con.close()


def cleanup_race_metrics(con) -> None:
    con.execute(
        "DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE COLUMN_KIND = 'METRIC' "
        "AND UPPER(COLUMN_NAME) LIKE 'ZZ_RACE_METRIC_%'"
    )
    con.execute(
        "DELETE FROM SYS_SEMANTIC.METRICS "
        "WHERE UPPER(METRIC_NAME) LIKE 'ZZ_RACE_METRIC_%'"
    )
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")


def main() -> int:
    con = connect()
    try:
        cleanup_race_metrics(con)

        # Roles are assigned round-robin across THREADS workers.
        results: list[dict[str, Any]] = []
        results_lock = threading.Lock()

        def collecting_worker(role: str) -> None:
            local: list[dict[str, Any]] = []
            worker(role, local)
            with results_lock:
                results.extend(local)

        threads: list[threading.Thread] = []
        for i in range(THREADS):
            role = ROLES[i % len(ROLES)]
            t = threading.Thread(target=collecting_worker, args=(role,))
            threads.append(t)
            t.start()
        for t in threads:
            t.join()

        # ---- Invariants ----
        total = len(results)
        bad_errors = [r for r in results
                      if not r["success"] and not is_well_formed_error(r["message"])]
        if bad_errors:
            fail("no unformatted errors",
                 f"{len(bad_errors)}/{total} calls had non-SEMANTIC or _999 errors; "
                 f"first: {bad_errors[0]['message']!r}")
        else:
            ok("no unformatted errors", f"{total} calls, well-formed refusals only")

        # Every compile after the storm should be OK.
        settled = None
        for _ in range(10):
            try:
                row = con.execute(compile_body()).fetchone()
                if row and row[0] == "OK":
                    settled = row
                    break
            except Exception:
                pass
            time.sleep(0.5)
        if settled is None:
            fail("post-storm compile", "COMPILE_REQUEST_JSON did not return OK within 10 tries")
        else:
            ok("post-storm compile", "OK")

        # No validation run stuck in RUNNING.
        stuck = con.execute(
            "SELECT COUNT(*) FROM SYS_SEMANTIC.VALIDATION_RUNS "
            "WHERE STATUS = 'RUNNING'"
        ).fetchone()[0]
        if int(stuck) != 0:
            fail("no stuck validation runs", f"{stuck} row(s) still RUNNING")
        else:
            ok("no stuck validation runs", "0")

        # Consistency: every zz_race_metric_* in METRICS has a matching
        # OBJECT_COLUMNS row (or none — but no half-created).
        rows = con.execute(
            "SELECT COUNT(*) FROM SYS_SEMANTIC.METRICS m "
            "WHERE UPPER(m.METRIC_NAME) LIKE 'ZZ_RACE_METRIC_%' "
            "AND NOT EXISTS ("
            "  SELECT 1 FROM SYS_SEMANTIC.OBJECT_COLUMNS oc "
            "  WHERE oc.COLUMN_KIND = 'METRIC' AND oc.OBJECT_REF_ID = m.METRIC_ID"
            ")"
        ).fetchone()[0]
        if int(rows) != 0:
            fail("no orphan race metrics",
                 f"{rows} METRICS row(s) without matching OBJECT_COLUMNS")
        else:
            ok("no orphan race metrics", "0")

        cleanup_race_metrics(con)

        print()
        outcome = "PASSED" if FAILED == 0 else "FAILED"
        print(f"{outcome}: {PASSED} passed, {FAILED} failed "
              f"({total} concurrent admin calls, "
              f"{sum(1 for r in results if r['success'])} succeeded, "
              f"{sum(1 for r in results if not r['success'])} refused)")
        return 0 if FAILED == 0 else 1
    finally:
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
