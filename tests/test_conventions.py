# Drained from seven to zero on 2026-08-31, in three steps.
#
#   replace_qualified_alias, strip_string_literals, token_upper -> shared/sql_text.lua
#   row_value, scalar, null_if_missing                          -> shared/rows.lua
#   physical_unique_key / physical_fusion_key                   -> shared/grain_graph.lua
#
# The first two mattered most: the validator proved an expression safe with one
# copy of `replace_qualified_alias` while the compiler emitted SQL with the
# other, and a divergence there is wrong SQL that validates. The last pair was
# one function under two names, which is how the compiler and the validator came
# to describe the same key check differently.
#
# The pin stays here, empty, because an empty pin is the strongest form of this
# rule: the next copy fails immediately rather than being grandfathered.

#!/usr/bin/env python3
"""The conventions this codebase holds itself to.

Six rules that cost nothing to follow and compound if they are not. None is a
correctness property, so nothing else will ever fail because one was broken --
which is exactly why they need a test. Each is a *ratchet*: the current state is
pinned, the pinned state may shrink, and it may not grow. Same discipline as
`tests/python_coverage_thresholds.py` and the Lua coverage floors.

  1. One condition, one rule code.
  2. Severity is carried by the channel, never by a code's spelling.
  3. Verifiers are named for the invariant they protect, not the ticket that
     prompted them.
  4. A catalog surface derives what it can look up instead of restating it.
  5. A routine is written once; a copy in a second module is pinned and shrinks.
  6. A verifier uses the shared host-side helpers, and the suite runs all of them.
  7. A term is defined once, in the glossary, and the glossary stays complete.

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
    "SEMANTIC_REQUEST_001": 2,
    "SEMANTIC_REQUEST_015": 2,
    "SEMANTIC_REQUEST_030": 2,
    "SEMANTIC_REQUEST_032": 2,
    "SEMANTIC_REQUEST_042": 2,
}

# The one string-match this rule was written to delete.
RETIRED_MESSAGE_MATCH = "no binding for active representation"

# A code carrying a severity letter -- SEMANTIC_ADMIN_W060 for an advisory --
# puts two numbering conventions in one namespace. Severity belongs to the
# channel: a refusal is raised, an advisory arrives in a column
# (`VALIDATE_MODEL`.SEVERITY, `SET_PRIMARY_REPRESENTATION`.WARNINGS). Nine
# SEMANTIC_MODEL_* codes are warnings and none is spelled with a W.
SEVERITY_PREFIXED_CODE = re.compile(r"SEMANTIC_[A-Z]+_[A-Z]\d+")

# SEMANTIC_QUERY_030, _031 and _033 left this list on 2026-08-31, when
# parse_where_filters and parse_having_filters became one function. Each had
# carried two or three "meanings" that were the same condition written twice,
# once per clause; the clause's noun now comes from a table beside the parser
# (WHERE_CLAUSE / HAVING_CLAUSE) instead of from a second copy of the code. This
# is the shape a pin is meant to shrink by: not by renumbering, but because the
# duplication that made one code look overloaded is gone.
#
# The overloading pins above are scoped to `lua/`, which is where the validator,
# compiler and agent runtimes emit from. The severity rule cannot be: the two
# codes that broke it lived in a *hand-written* admin script in the install SQL,
# so a scan of `lua/` alone would have passed them. Generated blocks are skipped
# because they are copies of `lua/`.
def codes_everywhere() -> set[str]:
    text = "\n".join(
        [path.read_text(encoding="utf-8") for path in sorted((ROOT / "lua").rglob("*.lua"))]
        + [path.read_text(encoding="utf-8").partition("-- BEGIN GENERATED")[0]
           for path in sorted((ROOT / "sql/install").glob("*.sql"))])
    # Comments explain the retired spelling, so they must not count as uses.
    lines = [line for line in text.split("\n") if not line.lstrip().startswith("--")]
    return set(re.findall(r"SEMANTIC_[A-Z]+_[A-Z]?\d+", "\n".join(lines)))


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

    def test_no_code_spells_its_severity(self):
        """Severity is the channel, not a letter in the code."""
        everywhere = codes_everywhere()
        self.assertGreater(len(everywhere), 150, "the whole-tree code scan broke")
        offenders = sorted(code for code in everywhere
                           if SEVERITY_PREFIXED_CODE.fullmatch(code))
        self.assertEqual(
            [], offenders,
            "these codes carry a severity letter; drop it and take a free "
            "number in the family (the plain number may already be a refusal, "
            "as SEMANTIC_ADMIN_060 was)")

    def test_the_advisory_pair_kept_its_meaning_after_renumbering(self):
        """The rename had to move numbers, so pin where they landed."""
        admin = (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
            encoding="utf-8")
        for code in ("SEMANTIC_ADMIN_220", "SEMANTIC_ADMIN_221"):
            self.assertIn(f'"{code}: representation', admin, code)
        self.assertNotIn("SEMANTIC_ADMIN_W06", admin.replace(
            "SEMANTIC_ADMIN_W060/W061", ""), "the W-prefixed codes are back")

    def test_the_severity_pattern_is_what_it_claims(self):
        for code in ("SEMANTIC_ADMIN_W060", "SEMANTIC_MODEL_E001"):
            self.assertRegex(code, SEVERITY_PREFIXED_CODE, code)
        for code in ("SEMANTIC_ADMIN_220", "SEMANTIC_MODEL_060"):
            self.assertNotRegex(code, SEVERITY_PREFIXED_CODE, code)

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

# Drained to empty on 2026-08-31. The 2026-08-25 review pinned 24 names and
# declined to rename them, for a good reason: a rename touches run_smoke.sh,
# tests/test_install.py and the docs for no behaviour change, and "carries real
# risk of silently dropping a verifier from the suite".
#
# That risk is checkable, so it is now checked -- see
# VerifiersShareTheirPlumbing, which requires every verifier to be wired into
# run_smoke.sh and run_smoke.sh to name no verifier that is gone. With both
# directions pinned, the rename stopped being a gamble and became a rename.
#
# Eighteen of the 24 needed only the ticket prefix removed: the rest of
# `verify_bug26_published_f3_batch` was already the invariant. The six
# `verify_milestoneN` files were named for a delivery phase and are now named for
# what they protect -- the catalog and seed, model validation, the structured
# request compiler, the SQL compiler and surfaces, agent context and feedback,
# materialization selection.
#
# The set stays here, empty, because an empty pin is the strongest form of this
# rule: any ticket-named verifier now fails.
LEGACY_TICKET_NAMED: set[str] = set()


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

    def test_the_grandfather_list_is_empty_and_stays_that_way(self):
        """It drained. Re-adding a name is a decision, not a default."""
        self.assertEqual(set(), LEGACY_TICKET_NAMED)

    def test_the_pattern_recognises_the_shapes_that_exist(self):
        # Illustrative names, not files -- the shapes the pattern has to catch.
        for name in ("verify_bug26_published_f3_batch.py", "verify_g04_x.py",
                     "verify_fb015_x.py", "verify_f13_x.py", "verify_milestone3.py"):
            self.assertRegex(name, TICKET_NAMED, name)
        # A feature or phase level inside a descriptive name is not a ticket id.
        for name in ("verify_fusion_f5.py", "verify_fanout_guardrails.py",
                     "verify_semantic_sql_phase1.py", "verify_grain_phase_c3.py"):
            self.assertNotRegex(name, TICKET_NAMED, name)


# ---------------------------------------------------------------------------
# Agent skills must not describe a surface that has moved on
# ---------------------------------------------------------------------------

SKILLS = sorted((ROOT / "skills").rglob("*.md"))


class SkillsMatchTheSurface(unittest.TestCase):
    """The skills are an interface contract, and a stale one misleads silently.

    `skills/exasol-semantic-modeler/SKILL.md` told agents that "`ALTER SEMANTIC
    VIEW ... ADD OR REPLACE DIMENSION` is not yet supported in DDL" for as long
    as that was true, and nothing failed when it stopped being true. An agent
    following it would reach for the ten-parameter script instead, or conclude a
    capability was missing.

    These checks are deliberately narrow: they pin the *claims* that go stale
    when a form is added or a code renumbered, not the prose around them.
    """

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = {path: path.read_text(encoding="utf-8") for path in SKILLS}
        cls.joined = "\n".join(cls.text.values())

    def test_the_skills_are_being_read(self):
        self.assertGreaterEqual(len(SKILLS), 6, [p.name for p in SKILLS])

    def test_no_skill_claims_a_supported_form_is_unsupported(self):
        """Every DDL form the parser accepts, stated as unsupported somewhere."""
        # The exact strings SEMANTIC_DDL_012 advertises.
        supported = ("REPLACE DIMENSIONS", "REPLACE FACTS", "REPLACE METRICS",
                     "ADD OR REPLACE DIMENSION", "ADD OR REPLACE FACT",
                     "ADD OR REPLACE METRIC", "DROP METRIC", "RENAME METRIC")
        denials = ("not yet supported", "is not supported", "not supported in DDL",
                   "has no DDL form")
        offenders = []
        for path, text in self.text.items():
            for line in text.split("\n"):
                if not any(denial in line for denial in denials):
                    continue
                for form in supported:
                    if form in line:
                        offenders.append(f"{path.name}: {line.strip()[:90]}")
        self.assertEqual(
            [], offenders,
            "a skill calls an accepted Semantic DDL form unsupported")

    def test_the_forms_the_parser_accepts_are_the_forms_the_docs_list(self):
        """SEMANTIC_DDL_012's own message is the source of truth."""
        parser = (ROOT / "lua/semantic_layer/admin/semantic_definition.lua").read_text(
            encoding="utf-8")
        advertised = parser.split('error("SEMANTIC_DDL_012: expected ', 1)[1]
        advertised = advertised.split('")', 1)[0]
        for form in ("REPLACE DIMENSIONS", "ADD OR REPLACE DIMENSION"):
            self.assertIn(form, advertised,
                          "SEMANTIC_DDL_012 stopped advertising a supported form")

    def test_no_skill_quotes_a_renumbered_code(self):
        """Codes that moved: keeping the old spelling sends readers nowhere."""
        for retired in ("SEMANTIC_ADMIN_W060", "SEMANTIC_ADMIN_W061"):
            self.assertNotIn(retired, self.joined,
                             f"{retired} was renumbered; skills still quote it")


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
    but discriminated in MATERIALIZATION_COLUMNS -- have to be excluded, and
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

    def test_the_library_exclusion_list_is_declared_once(self):
        """`NON_CALLABLE_SCRIPTS` lives in the packager and is read, not copied.

        `tools/verify_named_admin_api.py` used to carry a second copy with a
        comment claiming the two "cannot drift apart silently". They then did:
        FUSION_RUNTIME was added to the packager's set and not the copy, and
        nothing failed until a full smoke run reached that verifier.
        """
        verifier = (ROOT / "tools/verify_named_admin_api.py").read_text(
            encoding="utf-8")
        self.assertIn("_PACKAGER.NON_CALLABLE_SCRIPTS", verifier)
        for library in ("COMPILER_RUNTIME", "VALIDATOR_RUNTIME", "FUSION_RUNTIME"):
            self.assertNotIn(
                f'"{library}",', verifier,
                "the verifier restates a library name; read the packager's set")

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


# ---------------------------------------------------------------------------
# 5. A routine is written once
# ---------------------------------------------------------------------------

# What the copies cost, twice over.
#
# BUG-G03 was one defect -- a declared column name quoted verbatim, so a
# lower-case `account_id` rendered as `"account_id"` against a physical
# ACCOUNT_ID -- and it existed independently in five renderings of the same F5
# mapping join. Fixing it meant finding all five; the last was found by grepping
# after the fix looked complete. shared/identity_join.lua now owns that join.
#
# The JSON codec was the same story without the bug report. compiler/request_json.lua
# and admin/semantic_definition.lua carried a byte-identical 179-line block,
# agent/runtime.lua a third copy of its encoder half, admin/validator.lua a
# fourth parser. They had already drifted where it was hardest to see: the null
# sentinel is a bare table whose only meaning is its identity, so a null decoded
# by one module was an anonymous empty table to the others --
# compiler/query_spec.lua read it as an empty array, admin/fusion_declaration.lua
# as a present declaration that rendered as "table: 0x...". Nothing failed,
# because nothing compared the copies. shared/json.lua now owns it.
#
# This ratchet is the comparison. A body identical in two modules is pinned with
# the modules it appears in; the pin may shrink and may not grow.

LUA_SOURCES = sorted((ROOT / "lua").rglob("*.lua"))

# A body has to be substantial enough that sharing it is worth a module: two
# statements is a spelling, not a routine.
MIN_DUPLICATE_BODY_LINES = 3

# Every routine that currently exists in more than one module, with the modules.
# Fold one into lua/semantic_layer/shared/ and shrink the entry -- as
# identity_join.lua and json.lua both did. Adding an entry is the thing this
# test exists to stop.
#
# Drained from seven to four on 2026-08-31: `replace_qualified_alias`,
# `strip_string_literals` and `token_upper` moved to shared/sql_text.lua. The
# first two were the ones that mattered -- the validator proved an expression
# safe with one copy while the compiler emitted SQL with the other, and a
# divergence there is wrong SQL that validates.
#
# What is left is the four-line row prelude every runtime opens with. It is the
# cheapest kind of duplication and the least dangerous: `row_value`,
# `null_if_missing` and `scalar` read a driver result row, and a divergence
# produces a nil, not a wrong answer. Moving them needs a `shared/rows.lua` that
# also owns the `query` global each runtime binds differently, which is a larger
# change than the risk justifies today.
DUPLICATED_LUA_BODIES: dict[str, tuple[str, ...]] = {}

# Modules that must not grow a private JSON codec again. The sentinel makes this
# stricter than the body-identity rule above can be: a *reworded* second decoder
# would pass that check and still mint a second null nobody else recognises.
JSON_OWNER = "lua/semantic_layer/shared/json.lua"
JSON_PRIVATE_NAMES = re.compile(
    r"^local (?:function )?(json_encode|json_decode|json_escape|is_array"
    r"|parse_json_text)\b|^local JSON_NULL\s*=\s*\{", re.MULTILINE)

# Same rule for SQL text, for the same reason: a reworded second copy of
# `replace_qualified_alias` would pass the body check above and still let the
# validator prove an expression the compiler renders differently.
SQL_TEXT_OWNER = "lua/semantic_layer/shared/sql_text.lua"
SQL_TEXT_PRIVATE_NAMES = re.compile(
    r"^local function (quote_ident|quote_qualified|sql_literal|token_upper"
    r"|replace_qualified_alias|strip_string_literals|sql_tokens|tokenize"
    r"|decode_quoted_identifier)\b", re.MULTILINE)


def _lua_function_bodies():
    """(name, module) grouped by the exact text of the body.

    Comments and blank lines are dropped and each line is stripped, so a copy
    that was only re-indented or re-commented still counts as a copy.
    """
    opener = re.compile(r"^local function ([\w.]+)|^function ([\w.]+)")
    bodies = collections.defaultdict(set)
    for path in LUA_SOURCES:
        lines = path.read_text(encoding="utf-8").splitlines()
        index = 0
        while index < len(lines):
            match = opener.match(lines[index])
            if not match:
                index += 1
                continue
            name = match.group(1) or match.group(2)
            close = index
            while close < len(lines) and lines[close] != "end":
                close += 1
            body = [line.strip() for line in lines[index + 1:close]
                    if line.strip() and not line.strip().startswith("--")]
            if len(body) >= MIN_DUPLICATE_BODY_LINES:
                bodies["\n".join(body)].add((name, path.name))
            index = close
    return bodies


class RoutinesAreWrittenOnce(unittest.TestCase):
    """A function body identical in two modules is pinned, and the pin shrinks."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.measured = {}
        for occurrences in _lua_function_bodies().values():
            modules = {module for _, module in occurrences}
            if len(modules) > 1:
                label = "/".join(sorted({name for name, _ in occurrences}))
                cls.measured[label] = tuple(sorted(modules))

    def test_the_sources_are_being_read(self):
        self.assertGreater(len(LUA_SOURCES), 10, [p.name for p in LUA_SOURCES])

    def test_no_routine_is_newly_copied_into_a_second_module(self):
        self.maxDiff = None
        self.assertEqual(
            DUPLICATED_LUA_BODIES, self.measured,
            "a routine gained a copy, or a pinned copy was folded away without "
            "shrinking DUPLICATED_LUA_BODIES. Put it in "
            "lua/semantic_layer/shared/ and have both runtimes call it; "
            "tools/package_lua_scripts.py embeds shared modules into every "
            "script that needs them (see identity_join.lua, json.lua)")

    def test_the_json_codec_has_exactly_one_owner(self):
        """A reworded copy would pass the body check and still mint a second null.

        The sentinel's whole meaning is its identity, so a private `JSON_NULL`
        anywhere is a null that only its own file can recognise -- which is how
        compiler/query_spec.lua came to read an explicit null as an empty array
        while compiler/request_json.lua refused it.
        """
        offenders = {
            str(path.relative_to(ROOT)): sorted(
                m.group(1) for m in JSON_PRIVATE_NAMES.finditer(
                    path.read_text(encoding="utf-8")))
            for path in LUA_SOURCES
            if str(path.relative_to(ROOT)) != JSON_OWNER
            and JSON_PRIVATE_NAMES.search(path.read_text(encoding="utf-8"))
        }
        self.assertEqual(
            {}, offenders,
            f"JSON belongs to {JSON_OWNER}; use ESV_JSON rather than declaring "
            "a private codec or sentinel")

    def test_sql_text_has_exactly_one_owner(self):
        """The rendering half of the same rule the grain graph has for proofs.

        `CLAUDE.md` states that relationship proofs must delegate to
        shared/grain_graph.lua. Nothing stated it for SQL rendering, and BUG-G03
        was one defect living in five copies of the same join.
        """
        offenders = {
            str(path.relative_to(ROOT)): sorted(
                m.group(1) for m in SQL_TEXT_PRIVATE_NAMES.finditer(
                    path.read_text(encoding="utf-8")))
            for path in LUA_SOURCES
            if str(path.relative_to(ROOT)) != SQL_TEXT_OWNER
            and SQL_TEXT_PRIVATE_NAMES.search(path.read_text(encoding="utf-8"))
        }
        self.assertEqual(
            {}, offenders,
            f"SQL quoting, rewriting and lexing belong to {SQL_TEXT_OWNER}; "
            "use ESV_SQL_TEXT rather than declaring a private copy")

    def test_the_owner_actually_owns_it(self):
        """Deriving the rule from a module that had been emptied would pass silently."""
        owner = (ROOT / JSON_OWNER).read_text(encoding="utf-8")
        for exported in ("M.NULL", "function M.encode", "function M.decode",
                         "function M.is_valid", "function M.is_array"):
            self.assertIn(exported, owner)
        self.assertIn("ESV_JSON = M", owner)

        sql_owner = (ROOT / SQL_TEXT_OWNER).read_text(encoding="utf-8")
        for exported in ("function M.quote_ident", "function M.quote_qualified",
                         "function M.sql_literal", "function M.tokenize",
                         "function M.token_upper",
                         "function M.replace_qualified_alias",
                         "function M.strip_string_literals"):
            self.assertIn(exported, sql_owner)
        self.assertIn("ESV_SQL_TEXT = M", sql_owner)

    def test_every_runtime_that_uses_a_shared_module_carries_it(self):
        """A shared module only helps where the packager actually embeds it.

        Each runtime script is a separate Exasol chunk with no shared globals, so
        a `shared/` file one block forgets leaves that runtime asserting on a nil
        global at install time. Read from the generated SQL rather than from the
        packager's block functions: what matters is the artefact Exasol runs, and
        a check against the generator's source would pass on a block that
        assigned the source and forgot to interpolate it.
        """
        script = re.compile(
            r"^CREATE OR REPLACE (?:[A-Z]+ )*SCRIPT SEMANTIC_ADMIN\.([A-Z_0-9]+)"
            r"[^\n]*\n(.*?)^/$", re.S | re.M)
        consumers, providers = set(), set()
        for generated in (ROOT / "sql/install/003_create_semantic_admin_scripts.sql",
                          ROOT / "sql/install/006_create_semantic_agent_views.sql"):
            for match in script.finditer(generated.read_text(encoding="utf-8")):
                name, body = match.group(1), match.group(2)
                for global_name in ("ESV_JSON", "ESV_SQL_TEXT"):
                    if global_name not in body:
                        continue
                    consumers.add((global_name, name))
                    if f"{global_name} = M" in body:
                        providers.add((global_name, name))
        self.assertGreaterEqual(
            len(consumers), 5,
            f"only {sorted(consumers)} runtime/module pairs reference a shared "
            "global; the scan is not finding the generated scripts")
        self.assertEqual(
            set(), consumers - providers,
            "these generated scripts reference a shared global without "
            "embedding the module that defines it, so they would fail to "
            "install; add its source to their block in "
            "tools/package_lua_scripts.py")


# ---------------------------------------------------------------------------
# 6. Verifiers share their host-side plumbing, and the suite runs all of them
# ---------------------------------------------------------------------------

# `tools/semantic_client.py` has existed for a while: 119 lines, tested, and it
# reads an EXECUTE SCRIPT result *by column name* — the thing docs/known-issues.md
# says to do, after a documented column layout drifted and positional readers
# silently returned NULL. Exactly one of 59 verifiers imported it. The other 58
# each defined `connect()`, 29 of them character-for-character, and 26 defined
# their own `sql_string()`.
#
# A helper nobody imports is not a fix, so this is a ratchet rather than an
# announcement: the count of verifiers still rolling their own is pinned, may
# shrink, and may not grow. Convert one when you next touch it —
# `tools/verify_support.py` is the target and six verifiers already use it.
PRIVATE_CONNECT = 52

# The reason renaming a verifier used to be risky, removed.
#
# The 2026-08-25 review declined to drain LEGACY_TICKET_NAMED because a rename
# "carries real risk of silently dropping a verifier from the suite" — a file
# renamed but not renamed in run_smoke.sh simply stops running, and nothing says
# so. That is checkable, so it is checked here, and the rename stops being a
# gamble.
SMOKE_SUITE = ROOT / "tools/run_smoke.sh"


class VerifiersShareTheirPlumbing(unittest.TestCase):
    """Connection defaults and result reading belong to tools/verify_support.py."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.verifiers = {path.name: path.read_text(encoding="utf-8")
                         for path in (ROOT / "tools").glob("verify_*.py")
                         if path.name != "verify_support.py"}

    def test_the_directory_is_being_read(self):
        self.assertGreater(len(self.verifiers), 40, sorted(self.verifiers)[:5])

    def test_no_new_verifier_rolls_its_own_connection(self):
        private = sorted(name for name, text in self.verifiers.items()
                         if "def connect(" in text)
        self.assertLessEqual(
            len(private), PRIVATE_CONNECT,
            f"{len(private)} verifiers define their own connect() against a pin "
            f"of {PRIVATE_CONNECT}. Import tools/verify_support.py instead")
        self.assertEqual(
            PRIVATE_CONNECT, len(private),
            "the pin is stale — lower PRIVATE_CONNECT to "
            f"{len(private)} so the next copy is still caught")

    def test_the_shared_helpers_exist_and_read_results_by_name(self):
        """Deriving the rule from an empty module would pass silently."""
        support = (ROOT / "tools/verify_support.py").read_text(encoding="utf-8")
        for helper in ("def connect(", "def sql_string(", "def named_row(",
                       "def named_rows(", "def call_admin(", "def validate_model("):
            self.assertIn(helper, support)
        self.assertIn("statement.columns().keys()", support,
                      "named_rows must read the result set's own column names")

    def test_every_verifier_is_wired_into_the_smoke_suite(self):
        """A verifier nobody runs is a file, not a test.

        This is also what makes renaming one safe: a rename that misses
        run_smoke.sh fails here instead of quietly removing coverage.
        """
        smoke = SMOKE_SUITE.read_text(encoding="utf-8")
        unwired = sorted(name for name in self.verifiers if name not in smoke)
        self.assertEqual([], unwired,
                         "these verifiers are never run by tools/run_smoke.sh")

    def test_the_smoke_suite_names_no_verifier_that_is_gone(self):
        """The other half of a rename: a stale name is a step that cannot run."""
        smoke = SMOKE_SUITE.read_text(encoding="utf-8")
        named = set(re.findall(r"verify_[a-z0-9_]+\.py", smoke))
        missing = sorted(named - set(self.verifiers) - {"verify_support.py"})
        self.assertEqual([], missing,
                         "tools/run_smoke.sh names verifiers that do not exist")


# ---------------------------------------------------------------------------
# 7. A term is defined once, and the glossary stays complete
# ---------------------------------------------------------------------------

# What the missing glossary cost. `grain` -- what one row of a relation
# represents -- is the property every correctness rule in this layer is
# ultimately about: fan-out refusals, metric plannability, the object-root check,
# `STRICT_GRAIN` proof mode, half of docs/validation-rules.md. It appeared 130
# times across the documentation and was defined nowhere, and a modeller met it
# in their *second* call, as `ADD_ENTITY`'s GRAIN_DESCRIPTION.
#
# Meanwhile the one Vocabulary section that did exist -- in docs/data-fusion.md --
# defined nine terms, every one of them an advanced fusion concept. The glossary
# was inverted: the hard parts had one and the first steps did not.
#
# docs/glossary.md is now the single definitional home, and these tests keep it
# honest in the two ways it can rot: a core term quietly disappearing, and a
# refusal label appearing in the runtime that the glossary cannot decode.

GLOSSARY = ROOT / "docs/glossary.md"

# Terms that must always be defined. Not the whole glossary -- the entries a
# reader needs before their first model, plus the three collective nouns whose
# overlap is the thing most likely to be misread.
REQUIRED_TERMS = {
    "Grain", "Model", "Entity", "Semantic object", "Dimension", "Fact", "Metric",
    "Relationship", "Unique key", "Materialization",
    "Field", "Attribute", "Column",
    "Representation", "Attribute binding", "Semantic identity", "Authority",
}

# Where a term was defined before the glossary existed. These sections were
# lifted, not copied; if one comes back the product has two answers again.
LIFTED_FROM = {
    "docs/data-fusion.md": "glossary.md#the-nouns-fusion-adds",
}


class TermsAreDefinedOnce(unittest.TestCase):
    """docs/glossary.md is the single definitional home for the vocabulary."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.text = GLOSSARY.read_text(encoding="utf-8")
        # A definition is a bolded term leading a list item, a table row, or a
        # paragraph -- `grain` earns a paragraph of its own, which is the point.
        cls.defined = set(re.findall(r"^(?:[-|]\s*)?\*\*([^*]+)\*\*", cls.text, re.M))

    def test_the_glossary_is_being_read(self):
        self.assertGreater(len(self.defined), 20, sorted(self.defined))

    def test_every_required_term_is_defined(self):
        missing = sorted(REQUIRED_TERMS - self.defined)
        self.assertEqual(
            [], missing,
            f"docs/glossary.md no longer defines {missing}. These are the terms a "
            "reader needs before their first model; a term used across the "
            "product and defined nowhere is what this rule exists to prevent")

    def test_no_term_is_defined_twice(self):
        duplicated = sorted({term for term in self.defined
                             if len(re.findall(r"^(?:[-|]\s*)?\*\*" + re.escape(term)
                                               + r"\*\*", self.text, re.M)) > 1})
        self.assertEqual([], duplicated,
                         "a term with two definitions has none that can be trusted")

    def test_grain_is_actually_defined_and_not_merely_named(self):
        """The specific failure this rule was written about."""
        self.assertIn("**Grain** is", self.text)
        self.assertIn("what one row", self.text.lower().replace("*", ""))

    def test_the_lifted_sections_did_not_come_back(self):
        for path, target in LIFTED_FROM.items():
            text = (ROOT / path).read_text(encoding="utf-8")
            self.assertIn(
                target, text,
                f"{path} should point at the glossary for its vocabulary")
            body = text.split("## Vocabulary", 1)
            self.assertEqual(2, len(body), f"{path} lost its Vocabulary pointer")
            section = body[1].split("\n## ", 1)[0]
            self.assertNotIn(
                "\n- **", section,
                f"{path} is defining terms again; it was lifted into the glossary")

    def test_every_documentation_link_resolves(self):
        """A pointer to a deleted file is worse than no pointer.

        Three links to `architecture-decisions/001-grain-aware-result-semantics.md`
        outlived the file by nine days, and one of them was `architecture.md`
        saying "ADR 001 defines the grain-aware result contract" — the only place
        that promised to define grain at all.
        """
        heading = re.compile(r"^#{1,6}\s+(.*)")
        link = re.compile(r"\[[^\]]+\]\(([^)]+)\)")

        def anchors(path: Path) -> set[str]:
            found = set()
            for line in path.read_text(encoding="utf-8").splitlines():
                match = heading.match(line)
                if match:
                    slug = re.sub(r"[^\w\s-]", "", match.group(1).lower())
                    found.add(slug.strip().replace(" ", "-"))
            return found

        broken = []
        pages = list((ROOT / "docs").glob("*.md")) + [ROOT / "README.md", ROOT / "CLAUDE.md"]
        for page in pages:
            for target in link.findall(page.read_text(encoding="utf-8")):
                if target.startswith(("http", "mailto", "#!")):
                    continue
                file_part, _, anchor = target.partition("#")
                resolved = (page.parent / file_part).resolve() if file_part else page
                if not resolved.exists():
                    broken.append(f"{page.name} -> {target} (no such file)")
                elif anchor and anchor not in anchors(resolved):
                    broken.append(f"{page.name} -> {target} (no such heading)")
        self.assertEqual([], broken, "these documentation links go nowhere")

    def test_no_refusal_carries_a_bare_fusion_label(self):
        """`F3` in a refusal is a lookup the reader should not have to do.

        Nineteen runtime messages said things like "F5 semantic identity cannot
        be combined with F3 representation coverage", while the catalog used the
        numbers zero times and the only decode table lived in one document. The
        names say what the refusal is about; the numbers require a trip to the
        docs. They now read "a semantic identity cannot be combined with temporal
        representation coverage".
        """
        offenders = []
        for path in (ROOT / "lua").rglob("*.lua"):
            for number, line in enumerate(
                    path.read_text(encoding="utf-8").splitlines(), 1):
                # Per line, and excluding newlines from the literal, or the quote
                # pairing runs across statements and silently drops messages --
                # which it did on the first attempt at this test.
                for message in re.findall(r'"([^"\n]*)"', line):
                    if re.search(r"\bF[0-5](?:\.\d+)?\b", message):
                        offenders.append(f"{path.name}:{number}  {message[:60]}")
        self.assertEqual(
            [], offenders,
            "these runtime messages carry a bare fusion label; use the name — "
            "temporal coverage, semantic identity, partition fusion, attribute "
            "bindings — which is what docs/glossary.md and docs/data-fusion.md "
            "call them")

    def test_the_labels_the_docs_still_use_can_be_decoded(self):
        """The reference docs keep the numbers; the glossary has to decode them.

        `semantic-catalog.md` heads its sections `F3`/`F4`/`F5` and the modeller
        skill uses the labels throughout, so a reader still meets them — just not
        in a refusal any more. Derived from those files, so a new label cannot
        appear in the documentation without a row here.
        """
        used = set()
        for path in (list((ROOT / "docs").glob("*.md"))
                     + list((ROOT / "skills").rglob("*.md"))):
            if path.name == "glossary.md":
                continue
            used.update(re.findall(r"\bF([0-5])(?:\.\d+)?\b",
                                   path.read_text(encoding="utf-8")))
        self.assertGreaterEqual(len(used), 5,
                                f"only F{sorted(used)} found; the scan broke")
        rows = set(re.findall(r"^\| `F([0-5])`", self.text, re.M))
        self.assertEqual(
            [], sorted(used - rows),
            f"the documentation uses F{sorted(used - rows)} and the decode table "
            "in docs/glossary.md has no row for it")


if __name__ == "__main__":
    unittest.main(verbosity=2)
