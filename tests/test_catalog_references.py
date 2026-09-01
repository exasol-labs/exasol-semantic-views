#!/usr/bin/env python3
"""Static checks that Lua catalog references resolve against the real DDL.

The Lua runtime addresses the catalog through table and column names held in
string literals, so a name that does not exist is not a syntax error and not a
validation failure — it is a runtime SQL error on the one code path that uses
it. `EXISTING_EVOLUTION_TARGETS.SEMANTIC_IDENTITY` carried
`id_column = "SEMANTIC_IDENTITY_ID"` (the column is `IDENTITY_ID`) through
several releases: seven of the eight targets were exercised, the eighth raised
a raw `object SEMANTIC_IDENTITY_ID not found` instead of the clean
`SEMANTIC_AGENT_042` its siblings return.

A test that pinned only that one string would not have helped, because nothing
was wrong with the mechanism — the lookup table had drifted from the schema. So
this suite resolves every entry against the `CREATE TABLE` statements in
`sql/install/001_create_semantic_catalog.sql`, which makes adding a target with
a misspelled column, or pointing one at a table that cannot satisfy the query
the runtime builds, a test failure rather than a latent one.

DB-free: parses the Lua source and the install DDL as text.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CATALOG_DDL = (ROOT / "sql/install/001_create_semantic_catalog.sql").read_text(
    encoding="utf-8"
)
AGENT_RUNTIME = (ROOT / "lua/semantic_layer/agent/runtime.lua").read_text(
    encoding="utf-8"
)

CREATE_TABLE = re.compile(
    r"CREATE TABLE IF NOT EXISTS SYS_SEMANTIC\.([A-Z_]+)\s*\((.*?)\n\);",
    re.S,
)
COLUMN_LINE = re.compile(r"([A-Z_][A-Z0-9_]*)\s+[A-Z]")
LUA_TABLE_ENTRY = re.compile(r"(\w+)\s*=\s*\{([^}]*)\}")
LUA_STRING_FIELD = re.compile(r"(\w+)\s*=\s*\"([^\"]+)\"")


def parse_catalog_tables(ddl: str) -> dict[str, set[str]]:
    """Return {TABLE_NAME: {COLUMN, ...}} for every SYS_SEMANTIC table."""
    tables: dict[str, set[str]] = {}
    for match in CREATE_TABLE.finditer(ddl):
        columns: set[str] = set()
        for raw in match.group(2).splitlines():
            line = raw.strip()
            if not line or line.startswith("--"):
                continue
            if line.upper().startswith("PRIMARY KEY"):
                continue
            named = COLUMN_LINE.match(line)
            if named:
                columns.add(named.group(1))
        tables[match.group(1)] = columns
    return tables


def parse_lua_lookup(lua_source: str, constant: str) -> dict[str, dict[str, str]]:
    """Return {KEY: {field: string_value}} for a Lua table-of-tables constant."""
    block = re.search(
        r"local " + constant + r" = \{(.*?)\n\}", lua_source, re.S
    )
    assert block is not None, f"{constant} not found in Lua source"
    return {
        entry.group(1): dict(LUA_STRING_FIELD.findall(entry.group(2)))
        for entry in LUA_TABLE_ENTRY.finditer(block.group(1))
    }


class CatalogTableParsingTest(unittest.TestCase):
    """Guard the parser itself, so a silent no-op cannot pass as a green run."""

    def test_ddl_parses_into_tables_with_columns(self) -> None:
        tables = parse_catalog_tables(CATALOG_DDL)
        # 42 after CALCULATION_GROUPS, CALCULATION_ITEMS and OBJECT_PRIVILEGES
        # were dropped: each was declared for a feature that was never built.
        self.assertGreaterEqual(len(tables), 42)
        # Spot-check shapes the other tests depend on.
        self.assertIn("MODEL_ID", tables["MODELS"])
        self.assertIn("IDENTITY_ID", tables["SEMANTIC_IDENTITIES"])
        self.assertIn("IDENTITY_NAME", tables["SEMANTIC_IDENTITIES"])
        # A constraint clause must not be mistaken for a column.
        self.assertNotIn("PRIMARY", tables["UNIQUE_KEY_COLUMNS"])


class EvolutionTargetTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tables = parse_catalog_tables(CATALOG_DDL)
        self.targets = parse_lua_lookup(
            AGENT_RUNTIME, "EXISTING_EVOLUTION_TARGETS"
        )

    def test_every_target_is_parsed(self) -> None:
        """Fail loudly if the constant is renamed or reshaped."""
        self.assertGreaterEqual(len(self.targets), 8)
        for name, fields in self.targets.items():
            with self.subTest(target=name):
                self.assertIn("table_name", fields)
                self.assertIn("id_column", fields)
                self.assertIn("name_column", fields)

    def test_target_tables_exist(self) -> None:
        for name, fields in sorted(self.targets.items()):
            with self.subTest(target=name):
                schema, _, table = fields["table_name"].partition(".")
                self.assertEqual("SYS_SEMANTIC", schema)
                self.assertIn(
                    table,
                    self.tables,
                    f"{name} points at {fields['table_name']}, which 001 does "
                    f"not create",
                )

    def test_target_id_and_name_columns_exist(self) -> None:
        """The regression this file exists for.

        A name here is interpolated straight into `SELECT <id_column> FROM
        <table_name>`, so a column that does not exist surfaces only as a raw
        SQL error from the one branch that resolves that object type.
        """
        for name, fields in sorted(self.targets.items()):
            table = fields["table_name"].partition(".")[2]
            columns = self.tables[table]
            for field in ("id_column", "name_column"):
                with self.subTest(target=name, field=field):
                    self.assertIn(
                        fields[field],
                        columns,
                        f"{name}.{field} is {fields[field]!r}, which is not a "
                        f"column of {table}",
                    )

    def test_versioned_targets_can_satisfy_the_generated_lookup(self) -> None:
        """`evolution_target` builds one fixed WHERE clause for every target.

        MODEL returns earlier from `model.model_id` and never reaches that
        query; every other target is filtered on MODEL_ID, VERSION_ID and
        STATUS, so a target table lacking any of them would fail at runtime the
        same way a bad column name does.
        """
        for name, fields in sorted(self.targets.items()):
            if name == "MODEL":
                continue
            table = fields["table_name"].partition(".")[2]
            for required in ("MODEL_ID", "VERSION_ID", "STATUS"):
                with self.subTest(target=name, column=required):
                    self.assertIn(
                        required,
                        self.tables[table],
                        f"{name} resolves through {table}, which has no "
                        f"{required} column for the generated lookup",
                    )


if __name__ == "__main__":
    unittest.main(verbosity=2)
