#!/usr/bin/env python3
"""Verify that preprocessor query logging is a switch an administrator controls.

The preprocessor wrote SYS_SEMANTIC.QUERY_LOG for every statement it rewrote,
unconditionally: a write on the interactive path of every BI session, contending
with every other session's, and refusals were not recorded at all (GitHub #18).
SET_QUERY_LOGGING now sets it per deployment or per session.

This asserts, against the sales model:

- with logging OFF, neither a rewrite nor a refusal writes a row, while
  COMPILE_SQL_DEBUG still logs;
- with it ON, both do, and the refusal row carries its ERROR_CODE;
- ordinary SQL the preprocessor leaves unchanged is never logged;
- a session override wins over the deployment value, and clearing it restores
  the deployment value, as SEMANTIC_CATALOG.SETTINGS reports;
- a SEMANTIC_USER principal cannot change the setting.
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

SEMANTIC = "SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM SEMANTIC_SALES.SALES"
REFUSED = "SELECT COUNT(TOTAL_REVENUE) FROM SEMANTIC_SALES.SALES"
PROBE_USER, PROBE_PW = "ZZ_QUERY_LOG_PROBE", "Probe-Password-1"


def logged(con: Any) -> list[tuple[Any, ...]]:
    """Run a rewrite, a refusal and ordinary SQL; return the rows they logged."""
    before = con.execute("SELECT COALESCE(MAX(QUERY_LOG_ID), 0) FROM SEMANTIC_SOURCE.MY_QUERY_LOG").fetchone()[0]
    con.execute(SEMANTIC).fetchall()
    try:
        con.execute(REFUSED)
    except Exception:  # noqa: BLE001 -- the refusal is the point
        pass
    con.execute("SELECT 1 FROM DUAL").fetchall()
    return con.execute("SELECT ORIGINAL_SQL, STATUS, ERROR_CODE, ERROR_MESSAGE"
                       " FROM SEMANTIC_SOURCE.MY_QUERY_LOG WHERE QUERY_LOG_ID > "
                       f"{before} ORDER BY QUERY_LOG_ID").fetchall()


def setting(con: Any, scope: str, value: str | None) -> dict[str, Any]:
    return support.named_row(con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_QUERY_LOGGING('{scope}', "
        f"{'NULL' if value is None else support.sql_string(value)})"))


def main() -> int:
    admin = support.connect()
    deployment = admin.execute("SELECT DEPLOYMENT_VALUE FROM SEMANTIC_CATALOG.SETTINGS"
                               " WHERE SETTING_NAME = 'PREPROCESSOR_QUERY_LOG'").fetchone()[0]
    try:
        admin.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")

        setting(admin, "DEPLOYMENT", "OFF")
        if logged(admin):
            raise AssertionError("logging OFF still wrote QUERY_LOG rows")
        debug = admin.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL_DEBUG("
                              f"{support.sql_string(SEMANTIC)}, 'verify_query_logging')")
        if support.named_row(debug)["query_log_id"] is None:
            raise AssertionError("COMPILE_SQL_DEBUG stopped logging with preprocessor logging OFF")
        print("ok OFF: no row for a rewrite or a refusal; COMPILE_SQL_DEBUG still logs")

        state = setting(admin, "SESSION", "ON")
        if (state["deployment_value"], state["session_value"], state["effective_value"]) != ("OFF", "ON", "ON"):
            raise AssertionError(f"a session override did not win: {state}")
        rows = logged(admin)
        if [(sql, status, code) for sql, status, code, _ in rows] != [
                (SEMANTIC, "OK", None), (REFUSED, "ERROR", "SEMANTIC_QUERY_007")]:
            raise AssertionError(f"ON did not log exactly the rewrite and the refusal: {rows}")
        if "COUNT(total_revenue)" not in rows[1][3]:
            raise AssertionError(f"the refusal row lost its message: {rows[1]}")
        print("ok a session ON overrides deployment OFF; the refusal row carries its ERROR_CODE;"
              " ordinary SQL is not logged")

        state = setting(admin, "SESSION", None)
        if (state["session_value"], state["effective_value"]) != (None, "OFF"):
            raise AssertionError(f"clearing the override did not restore the deployment: {state}")
        print("ok clearing the session override restores the deployment value")

        admin.execute(f"DROP USER IF EXISTS {PROBE_USER} CASCADE")
        admin.execute(f'CREATE USER {PROBE_USER} IDENTIFIED BY "{PROBE_PW}"')
        admin.execute(f"GRANT CREATE SESSION TO {PROBE_USER}")
        admin.execute(f"GRANT SEMANTIC_USER TO {PROBE_USER}")
        probe = support.connect(user=PROBE_USER, password=PROBE_PW)
        try:
            setting(probe, "SESSION", "OFF")
            raise AssertionError("a SEMANTIC_USER principal switched off its own logging")
        except Exception as exc:  # noqa: BLE001
            if "insufficient privileges" not in str(exc) or isinstance(exc, AssertionError):
                raise
        finally:
            probe.close()
        print("ok a SEMANTIC_USER principal cannot change the setting")
        return 0
    finally:
        setting(admin, "SESSION", None)
        setting(admin, "DEPLOYMENT", deployment or "ON")
        admin.execute(f"DROP USER IF EXISTS {PROBE_USER} CASCADE")
        admin.close()


if __name__ == "__main__":
    raise SystemExit(main())
