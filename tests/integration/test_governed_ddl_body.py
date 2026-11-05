"""A governed query legal as a SELECT is legal as the body of DDL and DML.

`SELECT r, m FROM obj GROUP BY r` compiled on its own, and the same text as a
`CREATE VIEW ... AS`, `CREATE TABLE ... AS` or `INSERT INTO ... SELECT` body was
refused with SEMANTIC_QUERY_015, the double-grouping guard, although nothing is
grouped twice. Only a parenthesized block was compiled as a whole semantic
query, so an unparenthesized body's GROUP BY read as grouping the object again.
Materialising a governed result is mainstream, and ibis infers every result
schema with `CREATE VIEW "ibis_..." AS <query>`, so it could not read the
governed layer at all.
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest

SCHEMA = "GOVERNED_DDL_PROBE"
QUERY = ("SELECT customer_region, total_revenue FROM SEMANTIC_SALES.SALES"
         " GROUP BY customer_region")


def rows(con: Any, sql: str) -> list[tuple[str, ...]]:
    return sorted(tuple(str(value) for value in row) for row in con.execute(sql).fetchall())


@pytest.fixture
def probe(semantic_con: Any) -> Iterator[Any]:
    semantic_con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")
    semantic_con.execute(f"CREATE SCHEMA {SCHEMA}")
    try:
        yield semantic_con
    finally:
        semantic_con.execute(f"DROP SCHEMA IF EXISTS {SCHEMA} CASCADE")


@pytest.mark.parametrize("statement, relation", [
    (f"CREATE OR REPLACE VIEW {SCHEMA}.V AS {QUERY}", "V"),
    (f"CREATE OR REPLACE VIEW {SCHEMA}.VC (R, V) AS {QUERY} COMMENT IS 'governed'", "VC"),
    (f"CREATE OR REPLACE TABLE {SCHEMA}.T AS {QUERY}", "T"),
    (f"CREATE OR REPLACE VIEW {SCHEMA}.VO AS {QUERY} ORDER BY customer_region", "VO"),
])
def test_a_ddl_body_answers_what_the_query_answers(probe: Any, statement: str,
                                                   relation: str) -> None:
    probe.execute(statement)
    assert rows(probe, f"SELECT * FROM {SCHEMA}.{relation}") == rows(probe, QUERY)


def test_ctas_with_no_data_keeps_its_trailer(probe: Any) -> None:
    probe.execute(f"CREATE TABLE {SCHEMA}.EMPTY AS {QUERY} WITH NO DATA")
    assert probe.execute(f"SELECT COUNT(*) FROM {SCHEMA}.EMPTY").fetchone()[0] == 0


def test_insert_select_writes_the_governed_rows(probe: Any) -> None:
    probe.execute(f"CREATE TABLE {SCHEMA}.TARGET (R VARCHAR(100), V DECIMAL(36,2))")
    probe.execute(f"INSERT INTO {SCHEMA}.TARGET (R, V) {QUERY}")
    assert rows(probe, f"SELECT * FROM {SCHEMA}.TARGET") == rows(probe, QUERY)


def test_the_ibis_schema_probe_runs(probe: Any) -> None:
    probe.execute(f"OPEN SCHEMA {SCHEMA}")
    probe.execute(f'CREATE VIEW "ibis_exasol_metadata_probe" AS {QUERY}')
    assert rows(probe, 'SELECT * FROM "ibis_exasol_metadata_probe"') == rows(probe, QUERY)


def test_a_body_is_still_judged_like_the_query(probe: Any) -> None:
    # Compiled as the query, so it is refused as the query is: by name.
    with pytest.raises(Exception, match="SEMANTIC_QUERY_020"):
        probe.execute(f"CREATE VIEW {SCHEMA}.BAD AS SELECT bogus, total_revenue"
                      " FROM SEMANTIC_SALES.SALES GROUP BY bogus")
