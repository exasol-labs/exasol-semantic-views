#!/usr/bin/env python3
"""Run luacheck over the Lua script bodies embedded in sql/install/.

Most of the admin surface is Lua that exists only inside install SQL -- the
CREATE SCRIPT bodies in 003 before its generated blocks, the preprocessor in
004, the surface helpers in 005 -- so linting lua/ alone leaves it unchecked.
This extracts every body, declares the script's parameters as the globals
Exasol makes them, lints it with the repository's .luacheckrc, and reports each
warning against the install file and line it came from.

The *_RUNTIME scripts are skipped: they are lua/ sources concatenated by
tools/package_lua_scripts.py, and lua/ is linted directly.

Exit status is luacheck's: 0 clean, 1 warnings, 2+ errors.
"""

from __future__ import annotations

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
INSTALL = ROOT / "sql" / "install"

HEADER = re.compile(
    r"^CREATE OR REPLACE (?:LUA )?(?:(SCALAR|SET|PREPROCESSOR) )?SCRIPT\s+([A-Z_0-9]+\.[A-Z_0-9]+)",
    re.IGNORECASE)


def scripts(path: Path):
    """Yield (name, kind, parameters, first body line, body) for each script."""
    lines = path.read_text(encoding="utf-8").split("\n")
    index = 0
    while index < len(lines):
        match = HEADER.match(lines[index])
        if not match:
            index += 1
            continue
        kind, name = match.group(1), match.group(2).upper()
        # The header runs to the line ending in AS; the body to a lone "/".
        start = index
        while not re.search(r"\bAS\s*$", lines[index]):
            index += 1
        header = " ".join(lines[start:index + 1])
        body_start = index + 1
        end = body_start
        while lines[end].strip() != "/":
            end += 1
        index = end + 1
        params = re.search(r"\((.*?)\)\s*(?:RETURNS|EMITS|AS)", header)
        names = []
        if params and kind is None:
            # Scripting scripts take bare names, optionally ARRAY-prefixed.
            names = [p.split()[-1] for p in params.group(1).split(",") if p.strip()]
        yield name, kind, names, body_start + 1, "\n".join(lines[body_start:end])


def main() -> int:
    luacheck = sys.argv[1] if len(sys.argv) > 1 else "luacheck"
    status = 0
    with tempfile.TemporaryDirectory() as scratch:
        for path in sorted(INSTALL.glob("*.sql")):
            extracted = list(scripts(path))
            # A script whose header this parser does not recognise would go
            # unlinted without a word, so account for every one.
            declared = len(re.findall(r"^\s*CREATE\b[^\n]*\bSCRIPT\b", path.read_text(encoding="utf-8"), re.M))
            if declared != len(extracted):
                print(f"{path.relative_to(ROOT)}: {declared} CREATE SCRIPT statements,"
                      f" but only {len(extracted)} could be extracted for linting", file=sys.stderr)
                status = 2
            for name, kind, params, first_line, body in extracted:
                if name.endswith("_RUNTIME"):
                    continue
                target = Path(scratch) / f"{name}.lua"
                target.write_text(body, encoding="utf-8")
                command = [luacheck, "--config", str(ROOT / ".luacheckrc"),
                           "--formatter", "plain", "--codes", str(target)]
                # import(script, alias) binds the alias as a global, whether
                # called directly or through a helper that forwards both.
                aliases = re.findall(r"[\"']SEMANTIC_ADMIN\.\w+[\"']\s*,\s*[\"'](\w+)[\"']", body)
                if params or aliases:
                    command += ["--read-globals", *params, *aliases]
                if kind is not None:
                    # A UDF defines its entry points as globals for Exasol to call.
                    command += ["--globals", "run", "init", "cleanup", "default_output_columns"]
                result = subprocess.run(command, capture_output=True, text=True)
                if result.returncode >= 2 and not result.stdout:
                    sys.stderr.write(result.stderr)
                status = max(status, result.returncode)
                for line in result.stdout.splitlines():
                    found = re.match(r".*?:(\d+):(\d+): (.*)", line)
                    if found:
                        row = first_line + int(found.group(1)) - 1
                        relative = path.relative_to(ROOT)
                        print(f"{relative}:{row}:{found.group(2)}: [{name}] {found.group(3)}")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
