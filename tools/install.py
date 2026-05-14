#!/usr/bin/env python3
"""Install Exasol Semantic Views into a running Exasol instance.

Usage:
    python3 tools/install.py                          # install the extension
    python3 tools/install.py --example                # also load the sales demo model
    python3 tools/install.py --example --reset        # wipe and reinstall from scratch
    python3 tools/install.py --reset                  # wipe all schemas then reinstall
    python3 tools/install.py --skip-package           # skip Lua packaging (use existing SQL)

Connection is read from environment variables:
    EXASOL_HOST      (default: localhost)
    EXASOL_PORT      (default: 8563)
    EXASOL_USER      (default: sys)
    EXASOL_PASSWORD  (default: exasol)
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import ssl
import sys
import textwrap
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

INSTALL_FILES = [
    ROOT / "sql/install/000_create_schemas.sql",
    ROOT / "sql/install/001_create_semantic_catalog.sql",
    ROOT / "sql/install/002_create_semantic_catalog_views.sql",
    ROOT / "sql/install/003_create_semantic_admin_scripts.sql",
    ROOT / "sql/install/004_create_semantic_preprocessor.sql",
    ROOT / "sql/install/005_create_semantic_surface_helpers.sql",
    ROOT / "sql/install/006_create_semantic_agent_views.sql",
]

EXAMPLE_FILES = [
    ROOT / "sql/examples/sales_physical_model.sql",
    ROOT / "sql/examples/sales_model_seed.sql",
]

# Mirrors tools/reset_milestone1.sql — drops all managed schemas for a clean slate.
RESET_STATEMENTS = [
    "DROP SCHEMA IF EXISTS SEMANTIC_SALES CASCADE",
    "DROP SCHEMA IF EXISTS SEMANTIC_AGENT CASCADE",
    "DROP SCHEMA IF EXISTS SEMANTIC_CATALOG CASCADE",
    "DROP SCHEMA IF EXISTS SEMANTIC_ADMIN CASCADE",
    "DROP SCHEMA IF EXISTS SYS_SEMANTIC CASCADE",
    "DROP SCHEMA IF EXISTS MART CASCADE",
]


# ── output helpers ────────────────────────────────────────────────────────────

BOLD  = "\033[1m"
GREEN = "\033[32m"
RED   = "\033[31m"
DIM   = "\033[2m"
RESET = "\033[0m"


def _no_color() -> bool:
    return not sys.stdout.isatty() or os.environ.get("NO_COLOR")


def bold(s: str) -> str:
    return s if _no_color() else f"{BOLD}{s}{RESET}"


def green(s: str) -> str:
    return s if _no_color() else f"{GREEN}{s}{RESET}"


def red(s: str) -> str:
    return s if _no_color() else f"{RED}{s}{RESET}"


def dim(s: str) -> str:
    return s if _no_color() else f"{DIM}{s}{RESET}"


# ── SQL splitter (mirrors run_sql_files.py) ───────────────────────────────────

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


# ── core steps ────────────────────────────────────────────────────────────────

def run_package_lua(quiet: bool = False) -> None:
    spec = importlib.util.spec_from_file_location(
        "package_lua_scripts", ROOT / "tools/package_lua_scripts.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    if quiet:
        import io, contextlib
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
        mod.main()
        output = buf.getvalue().strip()
    else:
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        output = None

    if quiet and output:
        for line in output.splitlines():
            name, _, status = line.rpartition(" ")
            label = Path(name).name if name else line
            print(f"      {label:<48} {dim(status)}")


def run_sql_files(con: object, files: list[Path], label: str) -> None:
    import pyexasol  # type: ignore

    name_width = max(len(p.name) for p in files)

    for path in files:
        text = path.read_text(encoding="utf-8")
        statements = split_exasol_sql(text)
        count_str = f"{len(statements)} statement{'s' if len(statements) != 1 else ''}"
        t0 = time.monotonic()
        try:
            for i, stmt in enumerate(statements, 1):
                con.execute(stmt)  # type: ignore[union-attr]
        except Exception as exc:
            elapsed = time.monotonic() - t0
            print(f"      {path.name:<{name_width}}  {red('FAILED')}")
            print()
            snippet = "\n".join(stmt.splitlines()[:6])
            print(textwrap.indent(snippet, "        "))
            if len(stmt.splitlines()) > 6:
                print("        " + dim(f"... ({len(stmt.splitlines()) - 6} more lines)"))
            print()
            msg = str(exc)
            print(f"      {red('Error:')} {msg}")
            if "duplicate" in msg.lower() and "model" in msg.lower():
                print()
                print(f"      {dim('Hint: the example model already exists.')}")
                print(f"      {dim('Re-run with --reset to wipe and reinstall from scratch:')}")
                print(f"      {dim('  python3 tools/install.py --example --reset')}")
            print()
            raise SystemExit(1) from None

        elapsed = time.monotonic() - t0
        elapsed_str = f"{elapsed:.1f}s"
        print(f"      {path.name:<{name_width}}  {dim(count_str)}  {dim(elapsed_str)}")


# ── main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Install Exasol Semantic Views into a running Exasol instance.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent("""\
            Connection environment variables:
              EXASOL_HOST      host to connect to          (default: localhost)
              EXASOL_PORT      WebSocket port              (default: 8563)
              EXASOL_USER      database user               (default: sys)
              EXASOL_PASSWORD  database password           (default: exasol)
        """),
    )
    parser.add_argument(
        "--example", action="store_true",
        help="also load the sales demo model and materializations",
    )
    parser.add_argument(
        "--reset", action="store_true",
        help="drop all managed schemas before installing (clean slate)",
    )
    parser.add_argument(
        "--skip-package", action="store_true",
        help="skip Lua packaging step (use existing generated SQL)",
    )
    parser.add_argument("--host",     default=os.environ.get("EXASOL_HOST",     "localhost"))
    parser.add_argument("--port",     default=int(os.environ.get("EXASOL_PORT", "8563")), type=int)
    parser.add_argument("--user",     default=os.environ.get("EXASOL_USER",     "sys"))
    parser.add_argument("--password", default=os.environ.get("EXASOL_PASSWORD", "exasol"))
    parser.add_argument(
        "--tls-verify", action="store_true",
        default=os.environ.get("EXASOL_TLS_VERIFY", "").lower() in {"1", "true", "yes"},
    )
    args = parser.parse_args()

    try:
        import pyexasol  # type: ignore
    except ImportError:
        print(red("pyexasol is required:") + "  pip install pyexasol", file=sys.stderr)
        return 2

    total_steps = 3 + (1 if args.example else 0) + (1 if args.reset else 0)
    step = 0

    # header
    print()
    print(bold("Exasol Semantic Views") + " — installer")
    print("─" * 42)

    # step 1: package Lua
    if not args.skip_package:
        step += 1
        print(f"\n[{step}/{total_steps}] Packaging Lua scripts")
        try:
            run_package_lua(quiet=True)
        except SystemExit:
            print(red("      Packaging failed."))
            return 1
    else:
        total_steps -= 1

    # connect
    step += 1
    dsn = f"{args.host}:{args.port}"
    print(f"\n[{step}/{total_steps}] Connecting to {bold(dsn)} as {bold(args.user)}", end="  ", flush=True)
    try:
        con = pyexasol.connect(
            dsn=dsn,
            user=args.user,
            password=args.password,
            schema="SYS",
            encryption=True,
            websocket_sslopt=None if args.tls_verify else {"cert_reqs": ssl.CERT_NONE},
        )
    except Exception as exc:
        print(red("failed"))
        print(f"\n      {exc}", file=sys.stderr)
        return 1
    print(green("connected"))

    # optional reset
    if args.reset:
        step += 1
        print(f"\n[{step}/{total_steps}] Resetting all managed schemas", end="  ", flush=True)
        for stmt in RESET_STATEMENTS:
            con.execute(stmt)
        print(green("done"))

    # install
    step += 1
    print(f"\n[{step}/{total_steps}] Installing {len(INSTALL_FILES)} SQL files")
    t_install = time.monotonic()
    run_sql_files(con, INSTALL_FILES, "install")
    install_elapsed = time.monotonic() - t_install

    # optional: example
    if args.example:
        step += 1
        print(f"\n[{step}/{total_steps}] Loading sales example model")
        run_sql_files(con, EXAMPLE_FILES, "example")

    con.close()

    # summary
    print()
    print("─" * 42)
    if args.example:
        print(green("✓") + f" Installation complete  {dim(f'({install_elapsed:.1f}s)')}")
        print()
        print("  Sales model published at " + bold("SEMANTIC_SALES.SALES"))
        print()
        print("  Try it:")
        print(dim("    EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();"))
        print(dim("    SELECT customer_region, total_revenue"))
        print(dim("    FROM SEMANTIC_SALES.SALES"))
        print(dim("    GROUP BY customer_region"))
        print(dim("    ORDER BY total_revenue DESC LIMIT 5;"))
    else:
        print(green("✓") + f" Installation complete  {dim(f'({install_elapsed:.1f}s)')}")
        print()
        print("  Next steps:")
        print(f"    Load the sales demo:  {dim('python3 tools/install.py --example')}")
        print(f"    Read the docs:        {dim('docs/creating-metrics.md')}")
        print(f"    Enable Semantic SQL:  {dim('EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();')}")
    print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
