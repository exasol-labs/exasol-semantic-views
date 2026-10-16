"""Preprocessor query logging is a switch an administrator controls.

The preprocessor wrote SYS_SEMANTIC.QUERY_LOG for every statement it rewrote,
unconditionally: a write on the interactive path of every BI session,
contending with every other session's, and refusals were not recorded at all
(GitHub #18). SET_QUERY_LOGGING now sets it per deployment or per session.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

import verify_support as support

SEMANTIC = "SELECT CUSTOMER_REGION, TOTAL_REVENUE FROM SEMANTIC_SALES.SALES"
REFUSED = "SELECT COUNT(TOTAL_REVENUE) FROM SEMANTIC_SALES.SALES"
PROBE_USER, PROBE_PW = "ZZ_QUERY_LOG_PROBE", "Probe-Password-1"


def setting(con: Any, scope: str, value: str | None) -> dict[str, Any]:
    return support.named_row(con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.SET_QUERY_LOGGING('{scope}', "
        f"{'NULL' if value is None else support.sql_string(value)})"))


def logged(con: Any) -> list[tuple[Any, ...]]:
    """Run a rewrite, a refusal and ordinary SQL; return the rows they logged."""
    before = con.execute("SELECT COALESCE(MAX(QUERY_LOG_ID), 0) FROM SEMANTIC_SOURCE.MY_QUERY_LOG").fetchone()[0]
    con.execute(SEMANTIC).fetchall()
    with pytest.raises(Exception, match="SEMANTIC_QUERY_007"):
        con.execute(REFUSED)
    con.execute("SELECT 1 FROM DUAL").fetchall()
    return con.execute("SELECT ORIGINAL_SQL, STATUS, ERROR_CODE, ERROR_MESSAGE"
                       " FROM SEMANTIC_SOURCE.MY_QUERY_LOG WHERE QUERY_LOG_ID > "
                       f"{before} ORDER BY QUERY_LOG_ID").fetchall()


@pytest.fixture
def deployment_off(semantic_con: Any) -> Iterator[Any]:
    """Logging switched off for the deployment, and restored afterwards."""
    previous = semantic_con.execute("SELECT DEPLOYMENT_VALUE FROM SEMANTIC_CATALOG.SETTINGS"
                                    " WHERE SETTING_NAME = 'PREPROCESSOR_QUERY_LOG'").fetchone()[0]
    setting(semantic_con, "DEPLOYMENT", "OFF")
    try:
        yield semantic_con
    finally:
        setting(semantic_con, "SESSION", None)
        setting(semantic_con, "DEPLOYMENT", previous or "ON")


@pytest.fixture
def semantic_user() -> Iterator[Any]:
    """A principal holding only SEMANTIC_USER."""
    admin = support.connect()
    admin.execute(f"DROP USER IF EXISTS {PROBE_USER} CASCADE")
    admin.execute(f'CREATE USER {PROBE_USER} IDENTIFIED BY "{PROBE_PW}"')
    admin.execute(f"GRANT CREATE SESSION TO {PROBE_USER}")
    admin.execute(f"GRANT SEMANTIC_USER TO {PROBE_USER}")
    probe = support.connect(user=PROBE_USER, password=PROBE_PW)
    try:
        yield probe
    finally:
        probe.close()
        admin.execute(f"DROP USER IF EXISTS {PROBE_USER} CASCADE")
        admin.close()


def test_off_logs_neither_a_rewrite_nor_a_refusal(deployment_off):
    assert logged(deployment_off) == []


def test_compile_sql_debug_logs_whatever_the_setting(deployment_off):
    debug = deployment_off.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL_DEBUG("
                                   f"{support.sql_string(SEMANTIC)}, 'test_query_logging')")
    assert support.named_row(debug)["query_log_id"] is not None


def test_a_session_override_wins_and_logs_the_refusal_code(deployment_off):
    state = setting(deployment_off, "SESSION", "ON")
    assert (state["deployment_value"], state["session_value"], state["effective_value"]) == ("OFF", "ON", "ON")
    rows = logged(deployment_off)
    # Ordinary SQL leaves no row: only the rewrite and the refusal.
    assert [(sql, status, code) for sql, status, code, _ in rows] == [
        (SEMANTIC, "OK", None), (REFUSED, "ERROR", "SEMANTIC_QUERY_007")]
    assert "COUNT(total_revenue)" in rows[1][3]


def test_clearing_the_override_restores_the_deployment_value(deployment_off):
    setting(deployment_off, "SESSION", "ON")
    state = setting(deployment_off, "SESSION", None)
    assert (state["session_value"], state["effective_value"]) == (None, "OFF")


def test_a_semantic_user_cannot_change_the_setting(semantic_user):
    with pytest.raises(Exception, match="insufficient privileges"):
        setting(semantic_user, "SESSION", "OFF")
