"""Parse every maintained Lua source with the selected pinned compiler."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from tools.lua_runtime import ARCHIVE_SHA256, DEFAULT_VERSION, ensure_lua  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", choices=ARCHIVE_SHA256,
                        default=DEFAULT_VERSION, help="Lua release to check")
    args = parser.parse_args()
    _, compiler = ensure_lua(args.version)

    files = sorted(path for directory in (ROOT / "lua", ROOT / "tests/lua")
                   for path in directory.rglob("*.lua"))
    failed = False
    for source in files:
        result = subprocess.run([str(compiler), "-p", str(source)],
                                capture_output=True, text=True, check=False)
        if result.returncode:
            failed = True
            detail = result.stderr.strip() or result.stdout.strip()
            print(f"{source.relative_to(ROOT)}: {detail}", file=sys.stderr)

    if failed:
        return 1
    print(f"Lua {args.version}: parsed {len(files)} Lua source files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
