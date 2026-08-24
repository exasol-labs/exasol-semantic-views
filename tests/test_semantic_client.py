#!/usr/bin/env python3
"""Database-free tests for the client's result mapping and the compile contract.

An `EXECUTE SCRIPT` result set is named: `RETURNS TABLE` declares STATUS,
GENERATED_SQL, and the rest, and the driver carries those names. Reading such a
result positionally is what turned one incorrect column layout in the docs into
consumers silently reading `NULL` (docs/known-issues.md), so the client maps by
name and this suite holds that line.

The second half is a static invariant on the install SQL:
`SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT` hand-declares the compile
result contract, so it can drift from the scripts it describes.
`tools/verify_catalog_introspection.py` catches that against a live database;
this catches it at parse time, without one.
"""

from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
ADMIN_SQL = (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text()
AGENT_SQL = (ROOT / "sql/install/006_create_semantic_agent_views.sql").read_text()

COMPILE_ENTRYPOINTS = ("COMPILE_REQUEST_JSON", "COMPILE_SQL", "COMPILE_SQL_DEBUG")


def _load(name: str, relative_path: str) -> Any:
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


semantic_client = _load("_esv_semantic_client_unit", "tools/semantic_client.py")


class FakeStatement:
    """The parts of a pyexasol statement the client is allowed to rely on."""

    def __init__(self, columns: list[str], rows: list[tuple[Any, ...]]) -> None:
        self._columns = columns
        self._rows = list(rows)

    def columns(self) -> dict[str, dict[str, str]]:
        return {name: {"type": "VARCHAR"} for name in self._columns}

    def fetchone(self) -> tuple[Any, ...] | None:
        return self._rows.pop(0) if self._rows else None


def script_result_columns(script_name: str) -> list[str]:
    """Column names from a script's RETURNS TABLE declaration, in order."""
    start = ADMIN_SQL.index(f"CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.{script_name}(")
    body = ADMIN_SQL[start:]
    body = body[: body.index("\n/\n")]
    declaration = body[body.rindex("[[") + 2: body.rindex("]]")]
    columns = []
    for line in declaration.strip().splitlines():
        line = line.strip().rstrip(",")
        if line:
            columns.append(line.split()[0])
    return columns


def declared_contract() -> dict[str, list[str]]:
    """Column order per script as published by COMPILE_RESULT_SCHEMA_FOR_AGENT.

    The view shares its first eight rows across entrypoints with a CROSS JOIN,
    then appends a per-entrypoint ninth column, so the parse mirrors that shape:
    the LAYOUT block gives the shared columns and ENTRYPOINTS gives the handles.
    """
    start = AGENT_SQL.index(
        "CREATE OR REPLACE VIEW SEMANTIC_AGENT.COMPILE_RESULT_SCHEMA_FOR_AGENT AS"
    )
    view = AGENT_SQL[start:]
    view = view[: view.index(";\n")]

    layout_block = view[view.index("LAYOUT AS ("):]
    # Two row shapes: the first branch names its columns with AS, the rest are
    # bare SELECT lists. Key both by ordinal so order comes from the data.
    by_ordinal: dict[int, str] = {}
    for ordinal, column in re.findall(
        r"(\d+) AS ORDINAL_POSITION,\s*\n\s*'([A-Z_]+)' AS COLUMN_NAME", layout_block
    ):
        by_ordinal[int(ordinal)] = column
    for ordinal, column in re.findall(r"SELECT (\d+), '([A-Z_]+)'", layout_block):
        by_ordinal[int(ordinal)] = column
    shared = [by_ordinal[ordinal] for ordinal in sorted(by_ordinal)]

    entrypoint_block = view[view.index("ENTRYPOINTS AS ("): view.index("LAYOUT AS (")]
    handles: dict[str, str] = {}
    for script, handle in re.findall(
        r"'(COMPILE[A-Z_]*)',\s*\n?\s*'([A-Z_]*_ID)'", entrypoint_block
    ):
        handles[script] = handle
    for match in re.finditer(
        r"'(COMPILE[A-Z_]*)' AS SCRIPT_NAME,\s*\n\s*'([A-Z_]*_ID)' AS HANDLE_COLUMN",
        entrypoint_block,
    ):
        handles[match.group(1)] = match.group(2)

    return {script: shared + [handle] for script, handle in handles.items()}


class NamedResultMapping(unittest.TestCase):
    def test_maps_by_result_column_name_not_position(self) -> None:
        statement = FakeStatement(
            ["STATUS", "ERROR_CODE", "GENERATED_SQL"],
            [("OK", None, "SELECT 1")],
        )
        self.assertEqual(
            semantic_client._named_row(statement),
            {"status": "OK", "error_code": None, "generated_sql": "SELECT 1"},
        )

    def test_a_reordered_result_set_still_maps_correctly(self) -> None:
        """The property positional indexing does not have.

        Same values, different declared order: a positional reader would report
        the SQL as the status. A name-based reader cannot.
        """
        statement = FakeStatement(
            ["GENERATED_SQL", "STATUS", "ERROR_CODE"],
            [("SELECT 1", "OK", None)],
        )
        mapped = semantic_client._named_row(statement)
        self.assertEqual(mapped["status"], "OK")
        self.assertEqual(mapped["generated_sql"], "SELECT 1")

    def test_empty_result_maps_to_none(self) -> None:
        self.assertIsNone(semantic_client._named_row(FakeStatement(["STATUS"], [])))

    def test_client_error_shape(self) -> None:
        error = semantic_client._client_error("No result row returned.")
        self.assertEqual(error["status"], "ERROR")
        self.assertEqual(error["error_code"], "CLIENT_ERROR")
        self.assertEqual(error["error_message"], "No result row returned.")

    def test_client_never_indexes_a_result_row_positionally(self) -> None:
        """A positional read here is the defect this module exists to avoid."""
        source = (ROOT / "tools/semantic_client.py").read_text()
        offenders = re.findall(r"\brow\[\d+\]", source)
        self.assertEqual(offenders, [], f"positional result reads: {offenders}")


class PublishedCompileContract(unittest.TestCase):
    def setUp(self) -> None:
        self.contract = declared_contract()

    def test_every_compile_entrypoint_is_published(self) -> None:
        self.assertEqual(sorted(self.contract), sorted(COMPILE_ENTRYPOINTS))

    def test_published_contract_matches_script_declarations(self) -> None:
        for script in COMPILE_ENTRYPOINTS:
            with self.subTest(script=script):
                self.assertEqual(self.contract[script], script_result_columns(script))

    def test_the_ninth_column_differs_by_entrypoint(self) -> None:
        """The trap: two entrypoints end with a request id, one with a log id."""
        ninth = {script: columns[8] for script, columns in self.contract.items()}
        self.assertEqual(
            ninth,
            {
                "COMPILE_REQUEST_JSON": "AGENT_REQUEST_ID",
                "COMPILE_SQL": "AGENT_REQUEST_ID",
                "COMPILE_SQL_DEBUG": "QUERY_LOG_ID",
            },
        )

    def test_entrypoints_share_their_first_eight_columns(self) -> None:
        prefixes = {tuple(columns[:8]) for columns in self.contract.values()}
        self.assertEqual(len(prefixes), 1, f"layouts diverged before the handle: {prefixes}")


if __name__ == "__main__":
    unittest.main()
