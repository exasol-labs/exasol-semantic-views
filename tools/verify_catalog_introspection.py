#!/usr/bin/env python3
"""Verify the two introspection surfaces answer "what are the columns?" truthfully.

Catalog column names are not guessable from the concept they expose
(`CURRENT_VALIDATION_ISSUES` names the rule `RULE_CODE`, not `ISSUE_CODE`;
`VALIDATION_RUNS` ends a run at `FINISHED_AT`, not `COMPLETED_AT`), and the
compile scripts return nine columns whose layout a documentation error already
got wrong once — consumers following it read `NULL` (see docs/known-issues.md).

Two surfaces answer those questions as data rather than as prose:

  1. `SEMANTIC_CATALOG.CATALOG_COLUMNS` — every catalog, agent, core, and
     published-model surface with its columns. Derived from `EXA_ALL_COLUMNS`,
     so this test asserts it agrees with `EXA_ALL_COLUMNS` exactly, covers each
     schema completely, and gains a published model's typed views when one is
     published.
  2. `SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT` — the compile result
     contract. This is hand-declared SQL, so it is the one that can rot: every
     row is asserted against the **live** result set of each script, including
     that `COMPILE_SQL_DEBUG` ends with `QUERY_LOG_ID` and not
     `AGENT_REQUEST_ID`.

It also asserts the privilege behaviour the catalog view relies on: a user with
`SELECT` on `SEMANTIC_CATALOG` alone sees the catalog rows and not the agent or
core rows, because `EXA_ALL_COLUMNS` is filtered per session.
"""

from __future__ import annotations

import os
import ssl
import sys
from typing import Any

MODEL = "introspect_verify"
SCHEMA = "INTROSPECT_VERIFY"
PROBE_USER = "introspect_verify_user"
PROBE_PASSWORD = "introspect_verify_pw"

COMPILE_SCRIPTS = {
    "COMPILE_REQUEST_JSON": (
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON("
        "'{\"model\":\"sales\",\"object\":\"SALES\",\"metrics\":[\"total_revenue\"],"
        "\"dimensions\":[\"customer_region\"],\"client\":\"verify_catalog_introspection\"}')"
    ),
    "COMPILE_SQL": (
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL("
        "'SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region')"
    ),
    "COMPILE_SQL_DEBUG": (
        "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL_DEBUG("
        "'SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES "
        "GROUP BY customer_region', 'verify_catalog_introspection')"
    ),
}


def connect(user: str | None = None, password: str | None = None):
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)
    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=user or os.environ.get("EXASOL_USER", "sys"),
        password=password or os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def execute(con: Any, sql: str) -> list[tuple[Any, ...]]:
    statement = con.execute(sql)
    if statement.num_columns == 0:
        return []
    return [tuple(row) for row in statement.fetchall()]


def result_columns(con: Any, sql: str) -> list[str]:
    """The live column names of a script result set, in declared order."""
    statement = con.execute(sql)
    names = list(statement.columns().keys())
    if statement.num_columns:
        statement.fetchall()
    return names


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_true(name: str, condition: bool, detail: Any = "") -> None:
    if not condition:
        raise AssertionError(f"{name}: {detail}")
    print(f"ok {name}")


def build_published_model(con: Any) -> None:
    """A disposable single-entity model, published, so PUBLISHED rows exist."""
    con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    con.execute(f"CREATE SCHEMA {SCHEMA}")
    con.execute(
        f"CREATE TABLE {SCHEMA}.TICKETS (TICKET_ID DECIMAL(18,0) PRIMARY KEY, "
        "CHANNEL VARCHAR(20) NOT NULL, AMOUNT DECIMAL(18,2) NOT NULL)"
    )
    con.execute(f"INSERT INTO {SCHEMA}.TICKETS VALUES (1, 'WEB', 10.00), (2, 'PHONE', 5.00)")
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.CREATE_MODEL("
        f"'{MODEL}', 'SEMANTIC_{SCHEMA}', 'Disposable introspection model', NULL)",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY("
        f"'{MODEL}', 'ticket', '{SCHEMA}', 'TICKETS', 't', 't.ticket_id', "
        "'One row per ticket', 'Ticket grain')",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY("
        f"'{MODEL}', 'ticket', 'ticket_pk', 'PRIMARY', 'Row grain', 'NATIVE')",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_COLUMN("
        f"'{MODEL}', 'ticket', 'ticket_pk', 'ticket_id', NULL, 1)",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_OBJECT("
        f"'{MODEL}', 'TICKETS', 'ticket', 'Ticket-grain object')",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION("
        f"'{MODEL}', 'TICKETS', 'ticket', 'channel', 't.channel', 'VARCHAR(20)', "
        "'Channel', 'Contact channel', NULL, TRUE)",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT("
        f"'{MODEL}', 'ticket', 'amount', 't.amount', 'DECIMAL(18,2)', 'ADDITIVE', "
        "'Amount', 'Ticket amount', FALSE, TRUE)",
    )
    execute(
        con,
        "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC("
        f"'{MODEL}', 'TICKETS', 'total_amount', 'SUM(amount)', NULL, 'ADDITIVE', "
        "'ticket', 'DECIMAL(18,2)', 'Total Amount', 'Amount across tickets', "
        "'currency', FALSE, TRUE)",
    )
    execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('{MODEL}')")
    execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('{MODEL}')")


def main() -> int:
    con = connect()
    try:
        con.execute("ALTER SESSION SET QUERY_TIMEOUT=60")

        # 1. CATALOG_COLUMNS agrees with EXA_ALL_COLUMNS, per surface kind.
        for kind, schema in (
            ("CATALOG", "SEMANTIC_CATALOG"),
            ("AGENT", "SEMANTIC_AGENT"),
            ("CORE", "SYS_SEMANTIC"),
        ):
            expected = execute(
                con,
                "SELECT COLUMN_TABLE, COLUMN_ORDINAL_POSITION, COLUMN_NAME, COLUMN_TYPE "
                f"FROM EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA = {sql_string(schema)} "
                "ORDER BY 1, 2",
            )
            actual = execute(
                con,
                "SELECT SURFACE_NAME, ORDINAL_POSITION, COLUMN_NAME, DATA_TYPE "
                "FROM SEMANTIC_CATALOG.CATALOG_COLUMNS "
                f"WHERE SURFACE_KIND = {sql_string(kind)} ORDER BY 1, 2",
            )
            assert_equal(f"{kind} rows match EXA_ALL_COLUMNS", len(actual), len(expected))
            assert_true(
                f"{kind} column metadata is identical",
                actual == expected,
                "CATALOG_COLUMNS disagrees with EXA_ALL_COLUMNS",
            )

        surfaces = execute(
            con,
            "SELECT COUNT(DISTINCT SURFACE_NAME) FROM SEMANTIC_CATALOG.CATALOG_COLUMNS "
            "WHERE SURFACE_KIND IN ('CATALOG', 'AGENT')",
        )[0][0]
        assert_true("catalog and agent surfaces are covered", surfaces >= 40, surfaces)
        print(f"   {surfaces} catalog + agent surfaces indexed")

        # 2. The two names the evaluation mis-guessed resolve, and the guesses
        # do not silently resolve to something else.
        assert_equal(
            "CURRENT_VALIDATION_ISSUES names the rule RULE_CODE",
            execute(
                con,
                "SELECT COLUMN_NAME FROM SEMANTIC_CATALOG.CATALOG_COLUMNS "
                "WHERE SURFACE_NAME = 'CURRENT_VALIDATION_ISSUES' "
                "AND COLUMN_NAME IN ('RULE_CODE', 'ISSUE_CODE')",
            ),
            [("RULE_CODE",)],
        )
        assert_equal(
            "VALIDATION_RUNS ends a run at FINISHED_AT",
            execute(
                con,
                "SELECT COLUMN_NAME FROM SEMANTIC_CATALOG.CATALOG_COLUMNS "
                "WHERE SURFACE_NAME = 'VALIDATION_RUNS' AND SURFACE_KIND = 'CATALOG' "
                "AND COLUMN_NAME IN ('FINISHED_AT', 'COMPLETED_AT')",
            ),
            [("FINISHED_AT",)],
        )

        # 3. The compile result contract matches every script's live result set.
        for script, call in COMPILE_SCRIPTS.items():
            live = result_columns(con, call)
            declared = [
                row[0]
                for row in execute(
                    con,
                    "SELECT COLUMN_NAME FROM SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT "
                    f"WHERE SCRIPT_NAME = {sql_string(script)} ORDER BY ORDINAL_POSITION",
                )
            ]
            assert_equal(f"{script} declared layout matches the live result set", declared, live)
            indices = execute(
                con,
                "SELECT ORDINAL_POSITION, ZERO_BASED_INDEX "
                "FROM SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT "
                f"WHERE SCRIPT_NAME = {sql_string(script)} ORDER BY ORDINAL_POSITION",
            )
            assert_equal(
                f"{script} ordinals are 1-based and paired with 0-based indices",
                indices,
                [(position, position - 1) for position in range(1, len(live) + 1)],
            )

        # The distinction a positional reader gets wrong.
        assert_equal(
            "the ninth column differs by entrypoint",
            execute(
                con,
                "SELECT SCRIPT_NAME, COLUMN_NAME "
                "FROM SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT "
                "WHERE ORDINAL_POSITION = 9 ORDER BY SCRIPT_NAME",
            ),
            [
                ("COMPILE_REQUEST_JSON", "AGENT_REQUEST_ID"),
                ("COMPILE_SQL", "AGENT_REQUEST_ID"),
                ("COMPILE_SQL_DEBUG", "QUERY_LOG_ID"),
            ],
        )
        assert_true(
            "the JSON entrypoint says ORIGINAL_SQL is always NULL",
            "Always NULL" in execute(
                con,
                "SELECT NULL_WHEN FROM SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT "
                "WHERE SCRIPT_NAME = 'COMPILE_REQUEST_JSON' AND COLUMN_NAME = 'ORIGINAL_SQL'",
            )[0][0],
            "missing the always-NULL note",
        )

        # 4. Publishing a model makes its typed views discoverable here too.
        try:
            execute(con, f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')")
        except Exception:
            pass
        build_published_model(con)
        published = execute(
            con,
            "SELECT SURFACE_NAME, COLUMN_NAME FROM SEMANTIC_CATALOG.CATALOG_COLUMNS "
            f"WHERE SURFACE_KIND = 'PUBLISHED' AND SURFACE_SCHEMA = 'SEMANTIC_{SCHEMA}' "
            "AND SURFACE_TYPE = 'VIEW' ORDER BY 1, 2",
        )
        assert_equal(
            "published typed view columns are indexed",
            published,
            [("TICKETS", "CHANNEL"), ("TICKETS", "TOTAL_AMOUNT")],
        )

        # 5. The privilege behaviour the view depends on: EXA_ALL_COLUMNS is
        # filtered per session, so a limited user sees only what they may read.
        try:
            con.execute(f"DROP USER {PROBE_USER} CASCADE")
        except Exception:
            pass
        con.execute(f'CREATE USER {PROBE_USER} IDENTIFIED BY "{PROBE_PASSWORD}"')
        con.execute(f"GRANT CREATE SESSION TO {PROBE_USER}")
        con.execute(f"GRANT SELECT ON SCHEMA SEMANTIC_CATALOG TO {PROBE_USER}")
        limited = connect(PROBE_USER, PROBE_PASSWORD)
        try:
            kinds = execute(
                limited,
                "SELECT DISTINCT SURFACE_KIND FROM SEMANTIC_CATALOG.CATALOG_COLUMNS ORDER BY 1",
            )
            assert_equal("a catalog-only user sees only catalog surfaces", kinds, [("CATALOG",)])
            assert_true(
                "a catalog-only user can still resolve a column name",
                execute(
                    limited,
                    "SELECT COUNT(*) FROM SEMANTIC_CATALOG.CATALOG_COLUMNS "
                    "WHERE SURFACE_NAME = 'VALIDATION_RUNS' AND COLUMN_NAME = 'FINISHED_AT'",
                )[0][0] == 1,
                "FINISHED_AT not visible to a granted reader",
            )
        finally:
            limited.close()

        # ---- the discovery tables' advertised queries must run --------------
        #
        # Each managed schema holds exactly one physical TABLE -- its
        # SEMANTIC_*_DISCOVERY -- because a physical table is the only thing an
        # MCP client with view listing disabled (the official server's default)
        # can enumerate. Their *_QUERY rows are ready-to-run SELECT strings, and
        # a string naming a column that does not exist is not a syntax error
        # anywhere: it fails only for the agent that follows the advice.
        #
        # SEMANTIC_CATALOG's METRIC_DEFINITIONS_QUERY selected OBJECT_NAME from
        # SEMANTIC_CATALOG.METRICS, which has no such column -- the object name
        # lives on METRIC_OVERVIEW. Nothing executed these rows, so the catalog's
        # own answer to "show me the metric definitions" had been broken with no
        # test failing.
        discovery_tables = execute(
            con,
            "SELECT OBJECT_SCHEMA_NAME, OBJECT_NAME FROM ("
            "  SELECT ROOT_NAME AS OBJECT_SCHEMA_NAME, OBJECT_NAME, OBJECT_TYPE"
            "  FROM SYS.EXA_ALL_OBJECTS"
            "  WHERE ROOT_NAME IN ('SEMANTIC_CATALOG', 'SEMANTIC_AGENT')"
            "     OR ROOT_NAME IN (SELECT PUBLISHED_SCHEMA FROM SEMANTIC_CATALOG.MODELS"
            "                      WHERE PUBLISHED_SCHEMA IS NOT NULL))"
            " WHERE OBJECT_TYPE = 'TABLE' ORDER BY 1, 2",
        )
        assert_true(
            "every managed and published schema has exactly one physical table",
            len(discovery_tables) >= 3
            and len({schema for schema, _ in discovery_tables}) == len(discovery_tables),
            discovery_tables,
        )
        for schema, table in discovery_tables:
            assert_true(
                f"{schema}'s one table is its discovery index",
                "DISCOVERY" in str(table), (schema, table))

        # The published views are guarded, so their SELECT examples only run
        # once the entrypoint the same table advertises has been executed.
        # Running it here checks that advice too.
        con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        try:
            checked = 0
            for schema, table in discovery_tables:
                rows = execute(
                    con, f"SELECT ENTRY_NAME, ENTRY_VALUE FROM {schema}.{table}"
                         " ORDER BY ENTRY_NAME")
                assert_true(f"{schema}.{table} is not empty", len(rows) > 0)
                for name, value in rows:
                    text = str(value or "")
                    if not text.upper().lstrip().startswith("SELECT"):
                        continue
                    try:
                        con.execute(text)
                    except Exception as exc:  # noqa: BLE001 - the run is the assertion
                        raise AssertionError(
                            f"{schema}.{table} advertises a query that does not run: "
                            f"{name}: {text[:150]} -> {str(exc).splitlines()[0][:120]}"
                        ) from None
                    checked += 1
            assert_true("advertised queries all executed", checked >= 12, checked)
            print(f"ok every SELECT the discovery tables advertise runs ({checked} queries)")
        finally:
            con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")

        print()
        print("catalog introspection verified.")
        return 0
    finally:
        for statement in (
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.DROP_MODEL('{MODEL}')",
            f"DROP USER {PROBE_USER} CASCADE",
            f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE",
        ):
            try:
                execute(con, statement)
            except Exception:
                pass
        con.close()


if __name__ == "__main__":
    raise SystemExit(main())
