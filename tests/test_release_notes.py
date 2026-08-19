#!/usr/bin/env python3
"""Regression tests for curated release-note extraction."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "release_notes", ROOT / "tools/release_notes.py"
)
RELEASE_NOTES = importlib.util.module_from_spec(SPEC)  # type: ignore[arg-type]
SPEC.loader.exec_module(RELEASE_NOTES)  # type: ignore[union-attr]


class ReleaseNotesTest(unittest.TestCase):
    def test_extracts_only_requested_version(self):
        changelog = """# Changelog

## [Unreleased]

Future work.

## [0.2] - 2026-09-01

Second release.

## [0.1] - 2026-08-19

### Added

- First release.

## Notes on versioning

Policy text.
"""
        self.assertEqual(
            RELEASE_NOTES.extract_release_notes(changelog, "0.1"),
            "### Added\n\n- First release.\n",
        )

    def test_rejects_missing_or_empty_versions(self):
        with self.assertRaises(ValueError):
            RELEASE_NOTES.extract_release_notes("## [0.1]\n", "0.1")
        with self.assertRaises(ValueError):
            RELEASE_NOTES.extract_release_notes("## [0.1]\n\nNotes.\n", "0.2")

    def test_v01_notes_match_the_curated_changelog(self):
        changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
        notes = RELEASE_NOTES.extract_release_notes(changelog, "0.1")
        self.assertIn("Fusion Phase F3", notes)
        self.assertIn("Semantic SQL: Phase 2", notes)
        self.assertNotIn("[Unreleased]", notes)
        self.assertNotIn("Notes on versioning", notes)


if __name__ == "__main__":
    unittest.main()
