#!/usr/bin/env python3
"""Regression tests for host-side Exasol SQL statement splitting."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def load_splitter(path: Path):
    spec = importlib.util.spec_from_file_location(path.stem, path)
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module.split_exasol_sql


SPLITTERS = {
    "installer": load_splitter(ROOT / "tools/install.py"),
    "sql runner": load_splitter(ROOT / "tools/run_sql_files.py"),
}


class SqlSplitterTest(unittest.TestCase):
    def test_line_comment_quotes_and_semicolons_do_not_hide_statements(self) -> None:
        sql = """\
CREATE TABLE TEST.FIRST (ID DECIMAL(18,0)); -- model's first table; still a comment
-- don't merge the next statement; this apostrophe is not a literal
INSERT INTO TEST.FIRST VALUES (1);
CREATE TABLE TEST.SECOND (VALUE VARCHAR(20));
"""
        for name, splitter in SPLITTERS.items():
            with self.subTest(splitter=name):
                statements = splitter(sql)
                self.assertEqual(3, len(statements))
                self.assertEqual(
                    "CREATE TABLE TEST.FIRST (ID DECIMAL(18,0))",
                    statements[0],
                )
                self.assertEqual("INSERT INTO TEST.FIRST VALUES (1)", statements[1])
                self.assertEqual(
                    "CREATE TABLE TEST.SECOND (VALUE VARCHAR(20))",
                    statements[2],
                )

    def test_comment_marker_inside_literals_is_preserved(self) -> None:
        sql = """\
INSERT INTO TEST.VALUES_TABLE VALUES ('a--b', "c--d"); -- trailing comment's quote
SELECT 1;
"""
        for name, splitter in SPLITTERS.items():
            with self.subTest(splitter=name):
                statements = splitter(sql)
                self.assertEqual(2, len(statements))
                self.assertIn("'a--b'", statements[0])
                self.assertIn('"c--d"', statements[0])

    def test_f2_catalog_migration_splits_into_individual_statements(self) -> None:
        sql = (ROOT / "sql/install/001_create_semantic_catalog.sql").read_text(
            encoding="utf-8"
        )
        for name, splitter in SPLITTERS.items():
            with self.subTest(splitter=name):
                statements = splitter(sql)
                self.assertEqual(41, len(statements))
                self.assertFalse(
                    any(
                        "CREATE TABLE IF NOT EXISTS SYS_SEMANTIC.ATTRIBUTE_BINDINGS" in item
                        and "INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS" in item
                        for item in statements
                    )
                )

    def test_lua_quotes_do_not_hide_script_terminator(self) -> None:
        sql = r'''CREATE OR REPLACE SCRIPT TEST.RUNTIME AS
local escaped = "\\\""
local slash = "/"
return escaped .. slash
/

CREATE TABLE TEST.RESULTS (VALUE VARCHAR(20));
'''
        for name, splitter in SPLITTERS.items():
            with self.subTest(splitter=name):
                statements = splitter(sql)
                self.assertEqual(2, len(statements))
                self.assertTrue(statements[0].endswith("return escaped .. slash"))
                self.assertEqual(
                    "CREATE TABLE TEST.RESULTS (VALUE VARCHAR(20))",
                    statements[1],
                )


if __name__ == "__main__":
    unittest.main()
