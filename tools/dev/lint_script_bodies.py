#!/usr/bin/env python3
"""Run luacheck over every script body in lua/semantic_layer/scripts/.

A script body is not a module: Exasol runs it as the main chunk of a script
whose parameters it binds as globals. Each signature is in the install SQL, so
this reads it there, declares the parameters (and any `import` alias) as the
globals Exasol makes them, and lints the body file in place with the
repository's .luacheckrc. The runtime modules elsewhere in lua/ are linted
directly by tools/run_static_checks.sh.

Exit status is luacheck's: 0 clean, 1 warnings, 2+ errors.
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "sql" / "install"
BODIES = ROOT / "lua" / "semantic_layer" / "scripts"

# A script declaration up to its AS, then its `-- @lua <path>` body line.
SCRIPT = re.compile(
    r"^CREATE OR REPLACE (?:LUA )?(?:(SCALAR|SET|PREPROCESSOR) )?SCRIPT\s+[A-Z_0-9]+\.([A-Z_0-9]+)"
    r"(.*?)\bAS\n-- @lua (\S+)\n/$",
    re.IGNORECASE | re.MULTILINE | re.DOTALL)


def scripts():
    """Yield (name, kind, parameters, body path) for every script in the sources."""
    for path in sorted(INSTALL.glob("*.sql")):
        for kind, name, header, body in SCRIPT.findall(path.read_text(encoding="utf-8")):
            params = re.search(r"\((.*?)\)", header, re.DOTALL)
            names = []
            if params and not kind:
                # Scripting scripts take bare names, optionally ARRAY-prefixed.
                names = [p.split()[-1] for p in params.group(1).split(",") if p.strip()]
            yield name.upper(), kind or None, names, ROOT / body


def main() -> int:
    luacheck = sys.argv[1] if len(sys.argv) > 1 else "luacheck"
    found = list(scripts())
    # A body this parser does not pair with a signature would go unlinted
    # without a word, so account for every file.
    unpaired = sorted({path.name for path in BODIES.glob("*.lua")} - {body.name for *_, body in found})
    if unpaired:
        print(f"no signature found for {', '.join(unpaired)}", file=sys.stderr)
        return 2
    status = 0
    for name, kind, params, body in found:
        command = [luacheck, "--config", str(ROOT / ".luacheckrc"),
                   "--formatter", "plain", "--codes", str(body.relative_to(ROOT))]
        # import(script, alias) binds the alias as a global, whether called
        # directly or through a helper that forwards both.
        aliases = re.findall(r"[\"']SEMANTIC_ADMIN\.\w+[\"']\s*,\s*[\"'](\w+)[\"']",
                             body.read_text(encoding="utf-8"))
        if params or aliases:
            command += ["--read-globals", *params, *aliases]
        if kind is not None:
            # A UDF defines its entry points as globals for Exasol to call.
            command += ["--globals", "run", "init", "cleanup", "default_output_columns"]
        result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
        if result.returncode >= 2 and not result.stdout:
            sys.stderr.write(result.stderr)
        status = max(status, result.returncode)
        for line in result.stdout.splitlines():
            print(f"{line} [{name}]")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
