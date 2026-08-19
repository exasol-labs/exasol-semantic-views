#!/usr/bin/env python3
"""Extract one version's curated release notes from CHANGELOG.md."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def extract_release_notes(changelog: str, version: str) -> str:
    heading = re.compile(rf"^## \[{re.escape(version)}\](?:\s+-\s+.+)?$", re.MULTILINE)
    match = heading.search(changelog)
    if match is None:
        raise ValueError(f"CHANGELOG.md has no [{version}] release section")

    remainder = changelog[match.end() :]
    next_section = re.search(r"^## (?:\[|Notes on versioning)", remainder, re.MULTILINE)
    notes = remainder[: next_section.start() if next_section else None].strip()
    if not notes:
        raise ValueError(f"CHANGELOG.md [{version}] release section is empty")
    return notes + "\n"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("version", help="Release version without a leading v")
    parser.add_argument(
        "--changelog", type=Path, default=ROOT / "CHANGELOG.md", help="Changelog path"
    )
    args = parser.parse_args()
    print(
        extract_release_notes(args.changelog.read_text(encoding="utf-8"), args.version),
        end="",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
