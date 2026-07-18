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
