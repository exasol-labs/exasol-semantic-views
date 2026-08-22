#!/usr/bin/env python3
"""Property-based tests for the Python host tools.

These are DB-free and run in the standard runtime-tests CI job. They cover
invariants that example-based tests can only sample — string escaping under
adversarial inputs, JSON round-trips, and idempotence of cleaner functions.

Hypothesis picks random inputs, minimizes counterexamples, and stores a
regression database under `.hypothesis/`. New failures fail the CI job.
"""

from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path
from typing import Any

from hypothesis import given, strategies as st, settings


REPO_ROOT = Path(__file__).resolve().parent.parent


def _load(module_name: str, relative_path: str) -> Any:
    """Load a `tools/*.py` module by path (they aren't packaged)."""
    spec = importlib.util.spec_from_file_location(module_name, REPO_ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    sys.modules[module_name] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


osi = _load("_esv_osi", "tools/osi.py")
semantic_client = _load("_esv_semantic_client", "tools/semantic_client.py")


def _decode_sql_string(quoted: str) -> str:
    """Inverse of the `'...'`-with-doubled-quotes convention."""
    assert quoted.startswith("'") and quoted.endswith("'"), quoted
    return quoted[1:-1].replace("''", "'")


class SqlStringRoundTrip(unittest.TestCase):
    """Both wrappers implement the SQL single-quoted literal convention.

    Property: for any input string, the wrapper produces a well-formed
    `'...'` literal that round-trips exactly.
    """

    @given(st.text())
    @settings(max_examples=200, deadline=None)
    def test_osi_sql_string_roundtrip(self, s: str) -> None:
        self.assertEqual(_decode_sql_string(osi.sql_string(s)), s)

    @given(st.text())
    @settings(max_examples=200, deadline=None)
    def test_semantic_client_sql_string_roundtrip(self, s: str) -> None:
        # _sql_string is module-private; tests reach it directly on purpose.
        self.assertEqual(_decode_sql_string(semantic_client._sql_string(s)), s)

    @given(st.text())
    @settings(max_examples=200, deadline=None)
    def test_never_contains_unbalanced_quote(self, s: str) -> None:
        """Every `'` inside the wrapped literal must be part of a `''` pair.

        A stray single quote here would break the surrounding EXECUTE SCRIPT
        statement and is the classic SQL-injection footgun.
        """
        quoted = osi.sql_string(s)
        # Count internal (non-boundary) single quotes; they must be even in
        # count and appear only in `''` pairs.
        inner = quoted[1:-1]
        # There must be no odd-length run of `'` characters anywhere inside.
        run = 0
        for ch in inner:
            if ch == "'":
                run += 1
            else:
                self.assertEqual(run % 2, 0, f"odd-length quote run in {quoted!r}")
                run = 0
        self.assertEqual(run % 2, 0, f"odd trailing quote run in {quoted!r}")


json_primitive = st.one_of(
    st.none(), st.booleans(), st.integers(min_value=-(2**53), max_value=2**53),
    st.floats(allow_nan=False, allow_infinity=False, width=32),
    st.text(),
)
json_value = st.recursive(
    json_primitive,
    lambda children: st.one_of(
        st.lists(children, max_size=4),
        st.dictionaries(st.text(min_size=1, max_size=8), children, max_size=4),
    ),
    max_leaves=12,
)


class CompactJsonRoundTrip(unittest.TestCase):
    """`osi.compact_json` produces valid JSON that matches the cleaned form
    of the input. Cleaning drops None-valued keys from dicts (see
    `clean_json_value`), so the property is round-trip against the cleaned
    input, not the raw input.
    """

    @given(st.dictionaries(st.text(min_size=1, max_size=10), json_value, max_size=6))
    @settings(max_examples=100, deadline=None)
    def test_roundtrip_under_cleaning(self, data: dict) -> None:
        encoded = osi.compact_json(data)
        self.assertEqual(json.loads(encoded), osi.clean_json_value(data))

    @given(st.dictionaries(st.text(min_size=1, max_size=10), json_value, max_size=6))
    @settings(max_examples=100, deadline=None)
    def test_deterministic(self, data: dict) -> None:
        self.assertEqual(osi.compact_json(data), osi.compact_json(dict(data)))

    @given(st.dictionaries(st.text(min_size=1, max_size=10), json_value, max_size=6))
    @settings(max_examples=100, deadline=None)
    def test_clean_is_idempotent(self, data: dict) -> None:
        once = osi.clean_json_value(data)
        twice = osi.clean_json_value(once)
        self.assertEqual(once, twice)


class ColumnRefsExtraction(unittest.TestCase):
    """`osi.column_refs` extracts every `alias.column` pair present in an
    expression, in order. Property: an expression built by concatenating
    known `alias.column` pairs with arithmetic/string operators returns
    exactly that set of pairs (order-preserving, duplicates allowed).
    """

    identifier = st.text(alphabet="abcdefghijklmnopqrstuvwxyz_", min_size=1, max_size=8)

    @given(st.lists(st.tuples(identifier, identifier), min_size=1, max_size=6))
    @settings(max_examples=100, deadline=None)
    def test_extracts_all_pairs(self, pairs: list[tuple[str, str]]) -> None:
        expr = " + ".join(f"{a}.{c}" for a, c in pairs)
        extracted = osi.column_refs(expr)
        self.assertEqual(extracted, pairs)


if __name__ == "__main__":
    unittest.main()
