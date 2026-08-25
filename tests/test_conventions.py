#!/usr/bin/env python3
"""The conventions this codebase holds itself to.

Three rules that cost nothing to follow and compound if they are not. None is a
correctness property, so nothing else will ever fail because one was broken --
which is exactly why they need a test. Each is a *ratchet*: the current state is
pinned, the pinned state may shrink, and it may not grow. Same discipline as
`tests/python_coverage_thresholds.py` and the Lua coverage floors.

  1. One condition, one rule code.
  2. Verifiers are named for the invariant they protect, not the ticket that
     prompted them.
  3. A catalog surface derives what it can look up instead of restating it.

Each rule records what it cost when it was broken, because a convention with no
story attached is the first thing dropped under deadline.

DB-free: reads the Lua sources, the install SQL, and the `tools/` directory.
"""

from __future__ import annotations

import collections
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


# ---------------------------------------------------------------------------
# 1. One condition, one rule code
# ---------------------------------------------------------------------------

# Two shapes carry a message alongside a code:
#   add_issue(ctx, SEVERITY, TYPE, NAME, "CODE", "message ...")
#   error("CODE: message ...")
# Both captures stop at the next quote, so a message assembled by concatenation
# contributes its static prefix. That is what "one condition" means here: the
# same prefix with different interpolated detail is one meaning; a different
# prefix is another.
CODE_WITH_MESSAGE = (
    re.compile(r'"(SEMANTIC_[A-Z]+_[A-Z]?\d+)"\s*,\s*"([^"]{4,})"'),
    re.compile(r'"(SEMANTIC_[A-Z]+_[A-Z]?\d+):\s*([^"]{4,})"'),
)

# Codes that already carry more than one meaning, with the count as it stands.
# A code may LOSE meanings -- split it, then lower or delete the entry. It may
# not gain one: a new condition gets a new code. There are three digits of room
# in every family and no cost to using them.
#
# What the worst entry cost. SEMANTIC_MODEL_047 reached fourteen distinct
# messages, and one of them -- an active representation with no identity binding
# at all -- is the *cause* of the key, expression and attribute failures reported
# against that same representation. Promoting it to the head of the report
# therefore could not test the code; it had to search the message text for "no
# binding for active representation", a sentence any editing pass could have
# reworded without noticing anything break. Splitting that condition out as
# SEMANTIC_MODEL_060 turned a string search into a comparison.
OVERLOADED_RULE_CODES = {
    "SEMANTIC_MODEL_047": 13,
    "SEMANTIC_MODEL_042": 11,
    "SEMANTIC_AGENT_001": 9,
    "SEMANTIC_MODEL_036": 8,
    "SEMANTIC_MODEL_029": 7,
    "SEMANTIC_MODEL_044": 7,
    "SEMANTIC_MODEL_049": 7,
    "SEMANTIC_MODEL_039": 6,
    "SEMANTIC_MODEL_023": 5,
    "SEMANTIC_MODEL_038": 5,
    "SEMANTIC_MODEL_016": 4,
    "SEMANTIC_MODEL_017": 4,
    "SEMANTIC_MODEL_027": 4,
    "SEMANTIC_MODEL_028": 4,
    "SEMANTIC_MODEL_032": 4,
    "SEMANTIC_MODEL_037": 4,
    "SEMANTIC_QUERY_008": 4,
    "SEMANTIC_REQUEST_004": 4,
    "SEMANTIC_AGENT_003": 3,
    "SEMANTIC_MODEL_004": 3,
    "SEMANTIC_MODEL_013": 3,
    "SEMANTIC_MODEL_040": 3,
    "SEMANTIC_MODEL_048": 3,
    "SEMANTIC_QUERY_033": 3,
    "SEMANTIC_REQUEST_020": 3,
    "SEMANTIC_AGENT_010": 2,
    "SEMANTIC_AGENT_011": 2,
    "SEMANTIC_AGENT_041": 2,
    "SEMANTIC_AGENT_043": 2,
    "SEMANTIC_DDL_080": 2,
    "SEMANTIC_DDL_090": 2,
    "SEMANTIC_MODEL_000": 2,
    "SEMANTIC_MODEL_007": 2,
    "SEMANTIC_MODEL_026": 2,
    "SEMANTIC_MODEL_053": 2,
    "SEMANTIC_MODEL_056": 2,
    "SEMANTIC_QUERY_005": 2,
    "SEMANTIC_QUERY_006": 2,
    "SEMANTIC_QUERY_030": 2,
    "SEMANTIC_QUERY_031": 2,
    "SEMANTIC_REQUEST_001": 2,
    "SEMANTIC_REQUEST_015": 2,
    "SEMANTIC_REQUEST_030": 2,
    "SEMANTIC_REQUEST_032": 2,
    "SEMANTIC_REQUEST_042": 2,
}

# The one string-match this rule was written to delete.
RETIRED_MESSAGE_MATCH = "no binding for active representation"


class OneConditionOneRuleCode(unittest.TestCase):
    """A new condition gets a new code; overloaded codes only get better."""

    @classmethod
    def setUpClass(cls) -> None:
        messages: dict[str, set[str]] = collections.defaultdict(set)
        for path in sorted((ROOT / "lua").rglob("*.lua")):
            text = path.read_text(encoding="utf-8")
            for pattern in CODE_WITH_MESSAGE:
                for code, message in pattern.findall(text):
                    messages[code].add(message.strip())
        cls.messages = dict(messages)

    def test_the_scan_finds_the_families_it_should(self):
        """A regex matching nothing would make every check below vacuous."""
        families = {code.rsplit("_", 1)[0] for code in self.messages}
        self.assertLessEqual(
            {"SEMANTIC_MODEL", "SEMANTIC_DDL", "SEMANTIC_REQUEST",
             "SEMANTIC_AGENT", "SEMANTIC_QUERY"}, families)
        self.assertGreater(len(self.messages), 100, "the code scan lost its grip")

    def test_no_code_gains_a_meaning(self):
        grown = {code: (len(seen), OVERLOADED_RULE_CODES.get(code, 1))
                 for code, seen in self.messages.items()
                 if len(seen) > OVERLOADED_RULE_CODES.get(code, 1)}
        self.assertEqual(
            {}, grown,
            "these codes gained a meaning (measured, pinned). A new condition "
            "gets a new code; if you deliberately widened an existing one, say "
            "so by raising its pin")

    def test_the_pins_are_not_stale(self):
        """A pin above the real count leaves room to regress into unnoticed."""
        stale = {code: (len(self.messages.get(code, ())), pinned)
                 for code, pinned in OVERLOADED_RULE_CODES.items()
                 if len(self.messages.get(code, ())) != pinned}
        self.assertEqual(
            {}, stale,
            "pinned counts no longer match (measured, pinned). If you split a "
            "code, lower or remove its entry")

    def test_the_split_condition_has_its_own_code(self):
        self.assertEqual(
            1, len(self.messages.get("SEMANTIC_MODEL_060", ())),
            "SEMANTIC_MODEL_060 is the worked example of this rule; it carries "
            "one condition and must keep carrying one")

    def test_the_promotion_is_a_comparison_not_a_string_search(self):
        validator = (ROOT / "lua/semantic_layer/admin/validator.lua").read_text(
            encoding="utf-8")
        ordering = validator.split("local function order_root_cause_first", 1)
        self.assertEqual(2, len(ordering), "order_root_cause_first is gone")
        body = ordering[1].split("\nend", 1)[0]
        self.assertIn('issue.rule_code == "SEMANTIC_MODEL_060"', body)
        self.assertNotIn(
            RETIRED_MESSAGE_MATCH, body,
            "the ordering recognises the cause by its wording again; that is "
            "the coupling splitting the code removed")


# ---------------------------------------------------------------------------
# 2. Verifiers are named for the invariant, not the ticket
# ---------------------------------------------------------------------------

# verify_bug26_..., verify_g04_..., verify_milestone3 -- names that say when a
# file was written, not what property it protects. The cost is not aesthetic:
# across 58 verifiers and a ~20 minute full run, nobody can tell from the
# listing whether a change is already covered, so coverage gets re-added under a
# new ticket name instead of extending the file that owns the behaviour.
TICKET_NAMED = re.compile(r"^verify_(?:bug\d+|g\d+|fb\d+|f\d+_|milestone\d+)")

# Grandfathered. This set may shrink -- fold a case into the file that owns the
# behaviour, as verify_fusion_f5.py did for BUG-G03's lower-case mapping column
# rather than growing a verify_g03_*.py of its own -- and it may not grow.
LEGACY_TICKET_NAMED = {
    "verify_bug20_published_authoring_isolation.py",
    "verify_bug24_promotion_gate.py",
    "verify_bug25_published_mutation_protection.py",
    "verify_bug26_published_f3_batch.py",
    "verify_bug27_published_multistep_declarations.py",
    "verify_bug28_composite_removal_and_recertification.py",
    "verify_bug30_published_identity_setup.py",
    "verify_bug31_representation_with_identity.py",
    "verify_bug32_relationship_types_and_removal.py",
    "verify_bug37_attribute_with_bindings.py",
    "verify_f13_verified_query_scope.py",
    "verify_f18_metric_grain_positions.py",
    "verify_fb015_replace_attribute_binding.py",
    "verify_fb018_agent_session_instructions.py",
    "verify_fb019_query_timeout_precondition.py",
    "verify_g01_partitioned_join_hop.py",
    "verify_g02_named_admin_api.py",
    "verify_g04_identity_binding_diagnostic.py",
    "verify_milestone1.py",
    "verify_milestone2.py",
    "verify_milestone3.py",
    "verify_milestone4.py",
    "verify_milestone5.py",
    "verify_milestone6.py",
}


class VerifiersNamedByInvariant(unittest.TestCase):
    """A new verifier is named for the behaviour it protects."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.verifiers = {path.name for path in (ROOT / "tools").glob("verify_*.py")}

    def test_the_directory_is_being_read(self):
        self.assertGreater(len(self.verifiers), 40, sorted(self.verifiers)[:5])

    def test_no_new_verifier_is_named_after_a_ticket(self):
        measured = {name for name in self.verifiers if TICKET_NAMED.match(name)}
        self.assertEqual(
            LEGACY_TICKET_NAMED, measured,
            "name a new verifier for the invariant it protects (compare "
            "verify_fanout_guardrails.py, verify_path_ambiguity.py); if you "
            "renamed or folded one in, drop it from LEGACY_TICKET_NAMED")

    def test_the_convention_is_already_the_local_majority(self):
        """So it is the norm to follow, not an aspiration to argue with."""
        self.assertGreater(len(self.verifiers) - len(LEGACY_TICKET_NAMED),
                           len(LEGACY_TICKET_NAMED))

    def test_the_pattern_recognises_the_shapes_that_exist(self):
        for name in ("verify_bug26_published_f3_batch.py", "verify_g04_x.py",
                     "verify_fb015_x.py", "verify_f13_x.py", "verify_milestone3.py"):
            self.assertRegex(name, TICKET_NAMED, name)
        # A feature or phase level inside a descriptive name is not a ticket id.
        for name in ("verify_fusion_f5.py", "verify_fanout_guardrails.py",
                     "verify_semantic_sql_phase1.py", "verify_grain_phase_c3.py"):
            self.assertNotRegex(name, TICKET_NAMED, name)


# ---------------------------------------------------------------------------
# 3. Derive a surface, do not restate it
# ---------------------------------------------------------------------------

CATALOG_VIEWS = (ROOT / "sql/install/002_create_semantic_catalog_views.sql").read_text(
    encoding="utf-8")


class DerivedNotDeclared(unittest.TestCase):
    """CATALOG_RELATIONSHIPS reads its own declarations instead of repeating them.

    The view infers view-to-table edges by matching a view's column name against
    the declared foreign-key columns, which only works for names that mean one
    thing. Polymorphic names -- OBJECT_ID is SEMANTIC_OBJECTS in OBJECT_COLUMNS
    but discriminated in OBJECT_PRIVILEGES -- have to be excluded, and that
    exclusion was a literal list of six names sitting a few lines above the
    `discriminated` table that already knew all six. Adding a discriminated
    column would have left its name asserting one bogus parent on every view
    that exposes it, silently, until someone followed the edge.

    `CATALOG_COLUMNS`, `ADMIN_SCRIPT_PARAMETERS` and the FOREIGN_KEY half of
    this same view are all derived from `EXA_ALL_*` and cannot drift. This is the
    same rule applied to the half that SQL cannot declare for itself.
    """

    def setUp(self) -> None:
        parts = CATALOG_VIEWS.split(
            "CREATE OR REPLACE VIEW SEMANTIC_CATALOG.CATALOG_RELATIONSHIPS AS", 1)
        self.assertEqual(2, len(parts), "the view is gone or was renamed")
        self.body = parts[1].split("\n;", 1)[0]
        self.key_columns = self.body.split("key_columns AS (", 1)[1].split("),", 1)[0]

    def test_the_polymorphic_exclusion_is_derived(self):
        self.assertIn("SELECT d.CHILD_COLUMN FROM discriminated", self.key_columns)

    def test_it_is_not_also_restated(self):
        restated = re.findall(r"'[A-Z_]*OBJECT_ID'|'ATTRIBUTE_ID'|'SCOPE_ID'",
                              self.key_columns)
        self.assertEqual(
            [], restated,
            "the exclusion names polymorphic columns literally again; read them "
            "out of `discriminated`, which is the one place they are declared")

    def test_discriminated_is_declared_before_it_is_read(self):
        """A WITH clause can only reference an earlier one, so order is load-bearing."""
        self.assertLess(self.body.index("discriminated AS ("),
                        self.body.index("key_columns AS ("))

    def test_the_declaration_it_reads_is_non_trivial(self):
        """Deriving from an empty set would exclude nothing and pass silently."""
        declared = self.body.split("discriminated AS (", 1)[1].split(") AS d (", 1)[0]
        columns = {match.group(1) for match in re.finditer(
            r"^\s*\('[A-Z_]+',\s*'([A-Z_]+)'", declared, re.MULTILINE)}
        self.assertGreaterEqual(
            len(columns), 6,
            f"only {sorted(columns)} discriminated columns parsed; the exclusion "
            "derives from this set, so a parse failure silently excludes nothing")
        self.assertIn("CHILD_COLUMN", self.body.split(") AS d (", 1)[1][:200],
                      "the column the subquery selects is not the one declared here")


if __name__ == "__main__":
    unittest.main(verbosity=2)
