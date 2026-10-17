"""Every callable admin script describes itself and each of its parameters.

The descriptions are written once, in the annotation block of the script's file
under lua/semantic_layer/scripts/ (or, for a parameter that means the same in
every script, in PARAMETERS.md there), and the build publishes them in
SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS beside the signature CALL_ADMIN_JSON
resolves names from.
"""

from __future__ import annotations


def rows(con, sql):
    return con.execute(sql).fetchall()


def test_every_parameter_and_script_carries_a_description(con):
    undescribed = rows(con, """
        SELECT SCRIPT_NAME, PARAMETER_NAME
        FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS
        WHERE SCRIPT_DESCRIPTION IS NULL
           OR (PARAMETER_NAME IS NOT NULL AND PARAMETER_DESCRIPTION IS NULL)""")
    assert undescribed == []
    assert rows(con, "SELECT COUNT(DISTINCT SCRIPT_NAME) FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS")[0][0] > 80


def test_a_shared_parameter_reads_the_same_everywhere(con):
    descriptions = rows(con, """
        SELECT DISTINCT PARAMETER_DESCRIPTION
        FROM SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS
        WHERE PARAMETER_NAME = 'IS_CERTIFIED'""")
    assert len(descriptions) == 1


def test_the_description_columns_are_in_the_catalog(con):
    columns = [row[0] for row in rows(con, """
        SELECT COLUMN_NAME FROM SEMANTIC_CATALOG.CATALOG_COLUMNS
        WHERE SURFACE_NAME = 'ADMIN_SCRIPT_PARAMETERS' ORDER BY ORDINAL_POSITION""")]
    assert columns[-2:] == ["PARAMETER_DESCRIPTION", "SCRIPT_DESCRIPTION"]
