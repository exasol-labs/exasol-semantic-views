#!/usr/bin/env python3
"""Run Exasol SQL files with semicolon and slash-delimited script blocks.

This is host-side development tooling. It is not part of the installed Exasol
runtime.
"""

from __future__ import annotations

import argparse
import os
import ssl
import sys
from pathlib import Path


def split_exasol_sql(text: str) -> list[str]:
    statements: list[str] = []
    current: list[str] = []
    in_single = False
    in_double = False

    for raw_line in text.splitlines():
        line = raw_line.rstrip()
        if not in_single and not in_double and line.strip() == "/":
            statement = "\n".join(current).strip()
            if statement:
                statements.append(statement)
            current = []
            continue

        idx = 0
        start = 0
        while idx < len(line):
            char = line[idx]
            nxt = line[idx + 1] if idx + 1 < len(line) else ""
            if char == "'" and not in_double:
                if in_single and nxt == "'":
                    idx += 2
                    continue
                in_single = not in_single
            elif char == '"' and not in_single:
                in_double = not in_double
            elif char == ";" and not in_single and not in_double:
                current.append(line[start:idx])
                statement = "\n".join(current).strip()
                if statement:
                    statements.append(statement)
                current = []
                start = idx + 1
            idx += 1
        current.append(line[start:])

    statement = "\n".join(current).strip()
    if statement:
        statements.append(statement)
    return statements


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument("--host", default=os.environ.get("EXASOL_HOST", "localhost"))
    parser.add_argument("--port", default=int(os.environ.get("EXASOL_PORT", "8563")), type=int)
    parser.add_argument("--user", default=os.environ.get("EXASOL_USER", "sys"))
    parser.add_argument("--password", default=os.environ.get("EXASOL_PASSWORD", "exasol"))
    parser.add_argument("--schema", default=os.environ.get("EXASOL_SCHEMA", "SYS"))
    parser.add_argument(
        "--tls-verify",
        action="store_true",
        default=os.environ.get("EXASOL_TLS_VERIFY", "").lower() in {"1", "true", "yes"},
        help="Verify the Exasol TLS certificate. Disabled by default for local Nano.",
    )
    args = parser.parse_args()

    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        return 2

    dsn = f"{args.host}:{args.port}"
    con = pyexasol.connect(
        dsn=dsn,
        user=args.user,
        password=args.password,
        schema=args.schema,
        encryption=True,
        websocket_sslopt=None if args.tls_verify else {"cert_reqs": ssl.CERT_NONE},
    )
    try:
        for path in args.files:
            text = path.read_text(encoding="utf-8")
            statements = split_exasol_sql(text)
            print(f"{path}: {len(statements)} statements")
            for statement in statements:
                con.execute(statement)
    finally:
        con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
