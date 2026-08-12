#!/usr/bin/env python3
"""Regression tests for installer reset schema discovery."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("semantic_install", ROOT / "tools/install.py")
INSTALL = importlib.util.module_from_spec(SPEC)  # type: ignore[arg-type]
SPEC.loader.exec_module(INSTALL)  # type: ignore[union-attr]


class Result:
    def __init__(self, rows):
        self.rows = rows

    def fetchall(self):
        return self.rows


class Connection:
    def __init__(self, catalog_exists=True, catalog_broken=False):
        self.catalog_exists = catalog_exists
        self.catalog_broken = catalog_broken
        self.sql = []

    def execute(self, sql):
        self.sql.append(sql)
        if "EXA_ALL_VIEWS" in sql:
            return Result([(1 if self.catalog_exists else 0,)])
        if "SEMANTIC_CATALOG.MODELS" in sql:
            if self.catalog_broken:
                raise RuntimeError("catalog unavailable")
            return Result([
                ("SEMANTIC_ECOMMERCE",),
                ("semantic_sales",),
                (None,),
            ])
        raise AssertionError(f"unexpected SQL: {sql}")


class InstallerResetTest(unittest.TestCase):
    def test_f2_binding_install_surface_is_split_into_statements(self):
        statements = []
        for path in INSTALL.INSTALL_FILES:
            statements.extend(INSTALL.split_exasol_sql(path.read_text(encoding="utf-8")))
        expected_fragments = {
            "SYS_SEMANTIC.ATTRIBUTE_BINDINGS",
            "SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS",
            "SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING",
            "SEMANTIC_ADMIN.REMOVE_ATTRIBUTE_BINDING",
        }
        for fragment in expected_fragments:
            self.assertTrue(any(fragment in sql for sql in statements), fragment)

        add_binding = next(
            sql
            for sql in statements
            if "SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING" in sql
        )
        self.assertLess(
            add_binding.index("baseline_validation_rows"),
            add_binding.index("INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS"),
        )
        self.assertIn("if not baseline_errors[signature]", add_binding)

    def test_representation_promotion_preserves_explicit_binding_precedence(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        promotion = next(
            sql
            for sql in statements
            if "SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION" in sql
        )
        self.assertIn("stale_default_count", promotion)
        self.assertIn("stale default bindings were repaired", promotion)
        self.assertIn("explicit.IS_DEFAULT = FALSE", promotion)
        self.assertIn("explicit.REPRESENTATION_ID = :representation_id", promotion)
        self.assertIn("AND NOT EXISTS (", promotion)
        self.assertLess(
            promotion.index("stale_default_count"),
            promotion.index("SET REPRESENTATION_ROLE = 'ALTERNATE'"),
        )

    def test_f3_coverage_admin_surface_is_installable(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        coverage = next(
            sql
            for sql in statements
            if "SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE" in sql
        )
        self.assertIn("COVERAGE_PREDICATE = :coverage_predicate", coverage)
        self.assertIn("VALID_FROM = :valid_from", coverage)
        self.assertIn("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE", coverage)
        self.assertIn("STATUS = 'STALE'", coverage)

    def test_reset_discovers_non_example_published_schemas(self):
        statements = INSTALL.reset_statements(Connection())
        self.assertEqual(
            'DROP SCHEMA IF EXISTS "SEMANTIC_ECOMMERCE" CASCADE',
            statements[0],
        )
        self.assertEqual(1, sum("SEMANTIC_SALES" in sql for sql in statements))

    def test_reset_without_catalog_uses_fixed_managed_schemas(self):
        statements = INSTALL.reset_statements(Connection(catalog_exists=False))
        self.assertEqual(INSTALL.RESET_STATEMENTS, statements)

    def test_reset_recovers_from_broken_catalog(self):
        statements = INSTALL.reset_statements(Connection(catalog_broken=True))
        self.assertEqual(INSTALL.RESET_STATEMENTS, statements)

    def test_identifier_quoting(self):
        self.assertEqual('"A""B"', INSTALL.quote_ident('A"B'))


if __name__ == "__main__":
    unittest.main()
