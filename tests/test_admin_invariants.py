#!/usr/bin/env python3
"""Static invariants across all admin scripts.

Every mutation admin script has to invalidate cached compile output, or the
next COMPILE_REQUEST_JSON call may return stale SQL. The catalog-mutation
policy — "clear the compile cache or delegate to RECERTIFY_MODEL_IF_PUBLISHED"
— is documented in `docs/semantic-compiler.md`; this test enforces it at
install-SQL parse time so a future refactor cannot silently drop the invalidation
from a new mutator.

The suite is DB-free: it reads `sql/install/003_create_semantic_admin_scripts.sql`,
extracts one body per `CREATE OR REPLACE SCRIPT`, and asserts the invariant
per script. Fails fast with the specific script name.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALL_SQL = (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text()


SCRIPT_START = re.compile(r"^CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN\.([A-Z_]+)", re.MULTILINE)
BODY_END = re.compile(r"^/\s*$", re.MULTILINE)


def split_scripts(sql_text: str) -> dict[str, str]:
    """Return {script_name: body}. Body is the full CREATE...end-of-script text."""
    starts = list(SCRIPT_START.finditer(sql_text))
    bodies: dict[str, str] = {}
    for i, m in enumerate(starts):
        name = m.group(1)
        end_pos = starts[i + 1].start() if i + 1 < len(starts) else len(sql_text)
        bodies[name] = sql_text[m.start():end_pos]
    return bodies


# Runtime library modules — these are library imports (`import(...)`), not
# admin entry points, so the mutator rule does not apply to them.
LIBRARY_MODULES = {
    "COMPILER_RUNTIME",
    "FUSION_RUNTIME",
    "MATERIALIZATION_RUNTIME",
    "SEMANTIC_DEFINITION_RUNTIME",
    "VALIDATOR_RUNTIME",
    "AGENT_RUNTIME",
}

# Read-only scripts — they emit metadata, drive validation, or route through
# other mutators — so they legitimately need no cache clear of their own.
READ_ONLY_OR_INDIRECT = {
    "VALIDATE_MODEL",                   # writes validation logs only; does not touch model definition
    "RECERTIFY_MODEL_IF_PUBLISHED",     # delegates to VALIDATE_MODEL
    "SUGGEST_GRAIN_METADATA",           # dry-run suggester
    "PROPOSE_MODEL_EVOLUTION",          # writes to MODEL_EVOLUTION_SUGGESTIONS (F7 audit)
    "REVIEW_MODEL_EVOLUTION",           # writes to MODEL_EVOLUTION_REVIEWS (F7 audit)
    "EXPORT_SEMANTIC_DEFINITION",       # read-only
    "DESCRIBE_SEMANTIC_METRIC",         # read-only
    "EXPLAIN_SEMANTIC_METRIC",          # read-only
    "COMPILE_REQUEST_JSON",             # read-only (writes to QUERY_LOG only)
    "COMPILE_SQL",                      # read-only (writes to QUERY_LOG only)
    "COMPILE_SQL_DEBUG",                # read-only
    "ENABLE_SEMANTIC_SQL",              # session-level, no catalog write
    "DISABLE_SEMANTIC_SQL",             # session-level, no catalog write
    "REGISTER_VERIFIED_QUERY",          # writes VERIFIED_QUERIES; cache is model-version-keyed, no stale risk
    "REGISTER_AGENT_FEEDBACK",          # writes AGENT_FEEDBACK; no stale risk
    "REGISTER_AGENT_SUGGESTION",        # writes AGENT_SUGGESTIONS; no stale risk
    "REGISTER_AGENT_INSTRUCTION",       # writes AGENT_INSTRUCTIONS; agent-scope only
    "REMOVE_AGENT_INSTRUCTION",         # writes AGENT_INSTRUCTIONS; agent-scope only
    "PUT_CUSTOM_EXTENSION",             # writes CUSTOM_EXTENSIONS; metadata only, doesn't affect compile
    "REMOVE_CUSTOM_EXTENSION",          # symmetric with PUT_CUSTOM_EXTENSION
    "GET_CUSTOM_EXTENSIONS",            # read-only
    "GRANT_MODEL_ROLE",                 # grants; doesn't change compile output shape
    "REVOKE_MODEL_ROLE",                # symmetric with GRANT_MODEL_ROLE
    "PUBLISH_MODEL",                    # activates the version; the compile cache is keyed on model_version_id, so a new version is a natural miss
    "UNPUBLISH_MODEL",                  # symmetric with PUBLISH_MODEL
}


# Every script here mutates something under SYS_SEMANTIC and therefore
# MUST clear the compile cache or delegate to RECERTIFY_MODEL_IF_PUBLISHED
# (which itself delegates to VALIDATE_MODEL). If a new mutator lands
# without either, this test fails and points at the offending script.
def _is_mutator(body: str) -> bool:
    return bool(
        re.search(r"\b(INSERT|UPDATE|DELETE|MERGE)\b[\s\S]{0,120}SYS_SEMANTIC\.", body, re.IGNORECASE)
    )


def _invalidates_cache(body: str) -> bool:
    if "DELETE FROM SYS_SEMANTIC.COMPILE_CACHE" in body:
        return True
    if "RECERTIFY_MODEL_IF_PUBLISHED" in body:
        return True
    return False


# Snapshot of admin scripts that mutate SYS_SEMANTIC.* but don't clear the
# compile cache. Recorded 2026-08-22. These are legitimate cases: CREATE_MODEL
# has no ACTIVE_VERSION_ID yet; DRAFT-only DDL mutators run before publish so
# there's nothing to invalidate. If a new script joins this list, review why
# — the default assumption should be "invalidate on mutation."
KNOWN_NO_CACHE_CLEAR = {
    "ADD_CUSTOM_EXTENSION",
    "ADD_DIMENSION",
    "ADD_ENTITY",
    "ADD_FACT",
    "ADD_METRIC",
    "ADD_OR_REPLACE_DIMENSION",
    "ADD_SEMANTIC_OBJECT",
    "ADD_SYNONYM",
    "CREATE_MODEL",
    "REMOVE_DIMENSION",
}

# Snapshot of admin scripts that mark validation STALE but don't call
# RECERTIFY_MODEL_IF_PUBLISHED. Recorded 2026-08-22. Commit 2bcfaaf added
# recertification to identity-binding / mapping / removal mutators; the
# scripts below predate that commit and haven't been converted. Documenting
# the current set as a snapshot lets us detect regressions without forcing a
# refactor here. Related runtime finding: for scripts in this set, a
# PUBLISHED model needs a manual VALIDATE_MODEL after the mutation before
# COMPILE_REQUEST_JSON returns OK — see verify_grain_phase_b.py for how
# tests should set that up.
KNOWN_STALE_WITHOUT_RECERTIFY = {
    "ADD_ENTITY_REPRESENTATION",
    "ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING",
    "ADD_RELATIONSHIP",
    "ADD_SEMANTIC_IDENTITY",
    "ADD_SEMANTIC_IDENTITY_WITH_BINDINGS",
    "ADD_UNIQUE_KEY",
    "ADD_UNIQUE_KEY_COLUMN",
    "ADD_UNIQUE_KEY_WITH_COLUMNS",
    "REMOVE_ATTRIBUTE_BINDING",
    "REMOVE_ENTITY_REPRESENTATION",
    "REMOVE_RELATIONSHIP",
    "REMOVE_RELATIONSHIP_KEY_MAPPING",
    "REMOVE_UNIQUE_KEY",
    "REMOVE_UNIQUE_KEY_COLUMN",
    "REMOVE_UNIQUE_KEY_WITH_COLUMNS",
    "REPLACE_ATTRIBUTE_BINDING",
    "SET_PRIMARY_REPRESENTATION",
    "SET_REPRESENTATION_COVERAGE",
    "SET_REPRESENTATION_COVERAGE_BATCH",
}


class AdminMutationInvariants(unittest.TestCase):
    def setUp(self) -> None:
        self.scripts = split_scripts(INSTALL_SQL)
        self.assertGreater(len(self.scripts), 40, "sanity — should find dozens of admin scripts")

    def test_every_mutator_invalidates_cache(self) -> None:
        """Watchdog: no new mutator may skip cache invalidation without
        being reviewed and explicitly added to `KNOWN_NO_CACHE_CLEAR`."""
        skippers: set[str] = set()
        for name, body in self.scripts.items():
            if name in LIBRARY_MODULES or name in READ_ONLY_OR_INDIRECT:
                continue
            if not _is_mutator(body):
                continue
            if _invalidates_cache(body):
                continue
            skippers.add(name)
        new_skippers = skippers - KNOWN_NO_CACHE_CLEAR
        stale_entries = KNOWN_NO_CACHE_CLEAR - skippers
        self.assertEqual(
            new_skippers, set(),
            f"new admin script(s) mutate SYS_SEMANTIC.* without clearing the "
            f"compile cache: {sorted(new_skippers)}. Either add "
            f"`DELETE FROM SYS_SEMANTIC.COMPILE_CACHE ...` / delegate to "
            f"RECERTIFY_MODEL_IF_PUBLISHED, or (if the exemption is intentional) "
            f"add the name to `KNOWN_NO_CACHE_CLEAR` with a one-line comment."
        )
        self.assertEqual(
            stale_entries, set(),
            f"snapshot outdated: {sorted(stale_entries)} used to skip cache "
            f"invalidation but now invalidate. Remove them from "
            f"`KNOWN_NO_CACHE_CLEAR`."
        )

    def test_cache_invalidation_floor(self) -> None:
        """Absolute floor: the count of cache-clearing scripts should not
        drop below the level reached at 2026-08-22. Ratcheting-only, per
        project convention (docs/runtime-testing.md)."""
        FLOOR = 33
        clearing = [n for n, b in self.scripts.items()
                    if "DELETE FROM SYS_SEMANTIC.COMPILE_CACHE" in b]
        self.assertGreaterEqual(
            len(clearing), FLOOR,
            f"cache-clearing script count regressed: was ≥{FLOOR}, now {len(clearing)}. "
            f"If a mutator was removed, lower the floor; if invalidation was "
            f"dropped by mistake, restore it. Current set: {sorted(clearing)}"
        )


class RecertifyDelegation(unittest.TestCase):
    """Watchdog for scripts that mark validation STALE. The intended
    contract (commit 2bcfaaf) is that they also call
    RECERTIFY_MODEL_IF_PUBLISHED so the compile cache stays useful on
    PUBLISHED models. `KNOWN_STALE_WITHOUT_RECERTIFY` snapshots the
    pre-2bcfaaf mutators that haven't been converted yet — a new script
    joining that set fails this test.
    """

    def test_mutators_that_mark_stale_also_recertify(self) -> None:
        scripts = split_scripts(INSTALL_SQL)
        marks_stale_without_recertify: set[str] = set()
        for name, body in scripts.items():
            if name in LIBRARY_MODULES:
                continue
            if not ("VALIDATION_RUNS" in body and "'STALE'" in body):
                continue
            if "RECERTIFY_MODEL_IF_PUBLISHED" in body:
                continue
            if name in {"UNPUBLISH_MODEL", "DROP_MODEL"}:
                continue
            marks_stale_without_recertify.add(name)
        new_offenders = marks_stale_without_recertify - KNOWN_STALE_WITHOUT_RECERTIFY
        cured = KNOWN_STALE_WITHOUT_RECERTIFY - marks_stale_without_recertify
        self.assertEqual(
            new_offenders, set(),
            f"new admin script(s) mark validation STALE without recertifying: "
            f"{sorted(new_offenders)}. Add "
            f"`EXECUTE SCRIPT SEMANTIC_ADMIN.RECERTIFY_MODEL_IF_PUBLISHED(:model_name)` "
            f"after the STALE update, or explicitly add the name to "
            f"`KNOWN_STALE_WITHOUT_RECERTIFY` with justification."
        )
        self.assertEqual(
            cured, set(),
            f"snapshot outdated: {sorted(cured)} used to skip RECERTIFY but "
            f"now delegate correctly. Remove them from "
            f"`KNOWN_STALE_WITHOUT_RECERTIFY`."
        )


if __name__ == "__main__":
    unittest.main()
