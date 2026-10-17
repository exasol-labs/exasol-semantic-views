#!/usr/bin/env python3
"""Run luacheck over every script body in lua/semantic_layer/scripts/.

A script body is not a module: Exasol runs it as the main chunk of a script
whose parameters it binds as globals. Each file's annotation block declares
them (`-- @param NAME`), so this reads them with the build's own parser,
declares them (and any `import` alias) as the globals Exasol makes them, and
lints the file in place with the repository's .luacheckrc. The runtime modules
elsewhere in lua/ are linted directly by tools/run_static_checks.sh.

Exit status is luacheck's: 0 clean, 1 warnings, 2+ errors.
"""

from __future__ import annotations

import importlib.util
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location("package_lua_scripts", ROOT / "tools/package_lua_scripts.py")
PACKAGER = importlib.util.module_from_spec(_SPEC)  # type: ignore[arg-type]
_SPEC.loader.exec_module(PACKAGER)  # type: ignore[union-attr]


def main() -> int:
    luacheck = sys.argv[1] if len(sys.argv) > 1 else "luacheck"
    status = 0
    for script in PACKAGER.script_registry().values():
        body = script.path.relative_to(ROOT)
        command = [luacheck, "--config", str(ROOT / ".luacheckrc"),
                   "--formatter", "plain", "--codes", str(body)]
        # import(script, alias) binds the alias as a global, whether called
        # directly or through a helper that forwards both.
        aliases = re.findall(r"[\"']SEMANTIC_ADMIN\.\w+[\"']\s*,\s*[\"'](\w+)[\"']",
                             script.path.read_text(encoding="utf-8"))
        params = [name for name, _ in script.params]
        if params or aliases:
            command += ["--read-globals", *params, *aliases]
        if script.kind != "scripting":
            # A UDF defines its entry points as globals for Exasol to call.
            command += ["--globals", "run", "init", "cleanup", "default_output_columns"]
        result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
        if result.returncode >= 2 and not result.stdout:
            sys.stderr.write(result.stderr)
        status = max(status, result.returncode)
        for line in result.stdout.splitlines():
            print(f"{line} [{script.name}]")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
