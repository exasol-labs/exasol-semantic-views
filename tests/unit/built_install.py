"""The install SQL as tools/package_lua_scripts.py builds it.

Built in memory, once per process, so a test reads exactly what the installer
would run and never a stale build/install/ left by an earlier run.
"""

from __future__ import annotations

import functools
import importlib.util
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "package_lua_scripts", ROOT / "tools/package_lua_scripts.py")
PACKAGER = importlib.util.module_from_spec(_SPEC)  # type: ignore[arg-type]
_SPEC.loader.exec_module(PACKAGER)  # type: ignore[union-attr]


@functools.cache
def files() -> dict[str, str]:
    """Every built install file's text, by file name."""
    return PACKAGER.assemble()


def text(name: str) -> str:
    """One built install file's text, e.g. text("003_create_semantic_admin_scripts.sql")."""
    return files()[name]
