#!/usr/bin/env python3
"""Install Exasol Semantic Views into a running Exasol instance.

Usage:
    python3 tools/install.py                          # install the extension
    python3 tools/install.py --example                # also load the sales demo model
    python3 tools/install.py --example --publish      # ... and publish it as BI-visible views
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
import hashlib
import importlib.util
import os
import re
import ssl
import subprocess
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

RESET_SCHEMA_NAMES = {
    "SEMANTIC_SALES",
    "SEMANTIC_AGENT",
    "SEMANTIC_CATALOG",
    "SEMANTIC_ADMIN",
    "SYS_SEMANTIC",
    "MART",
}


# ── build provenance ──────────────────────────────────────────────────────────
#
# The runtime lives inside the database, so a deployment has to be able to say
# which build it is running. Without it, diagnosing "same catalog, different
# behaviour" means comparing schemas by hand and guessing from install
# timestamps. Recorded in SYS_SEMANTIC.PRODUCT_INSTALLATIONS and read back
# through SEMANTIC_CATALOG.PRODUCT_VERSION.

def latest_release_version(changelog: str) -> tuple[str, str]:
    """Return (version, release_state) from CHANGELOG.md text.

    The newest `## [x.y]` heading is the version. `DEVELOPMENT` means the tree
    carries unreleased changes on top of it, which is the common case for a
    deployment installed from a working checkout.
    """
    released = re.search(r"^## \[([^\]]+)\]", changelog, re.MULTILINE)
    versions = [
        match.group(1)
        for match in re.finditer(r"^## \[([^\]]+)\]", changelog, re.MULTILINE)
        if match.group(1).lower() != "unreleased"
    ]
    if not versions:
        return "UNKNOWN", "UNKNOWN"
    state = "RELEASED"
    if released is not None and released.group(1).lower() == "unreleased":
        unreleased = changelog[released.end():]
        next_heading = re.search(r"^## ", unreleased, re.MULTILINE)
        body = unreleased[: next_heading.start() if next_heading else None]
        if body.strip():
            state = "DEVELOPMENT"
    return versions[0], state


def runtime_checksum(files: list[Path]) -> str:
    """Hash the install SQL as executed.

    Git provenance is absent for a tarball, a vendored copy, or uncommitted
    edits; this is not, so it is the reliable discriminator between two
    deployments that claim the same version.
    """
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def git_provenance(root: Path, runner=subprocess.run) -> tuple[str | None, str]:
    """Return (commit, state) where state is CLEAN, DIRTY, or UNKNOWN."""
    def run(*args: str) -> str | None:
        try:
            result = runner(
                ["git", "-C", str(root), *args],
                capture_output=True, text=True, timeout=10, check=False,
            )
        except Exception:  # noqa: BLE001 - git may be missing entirely
            return None
        if result.returncode != 0:
            return None
        return result.stdout.strip()

    commit = run("rev-parse", "HEAD")
    if not commit:
        return None, "UNKNOWN"
    status = run("status", "--porcelain")
    if status is None:
        return commit, "UNKNOWN"
    return commit, "DIRTY" if status.strip() else "CLEAN"


def sql_literal(value: str | None) -> str:
    if value is None:
        return "NULL"
    return "'" + str(value).replace("'", "''") + "'"


def record_installation(con: object, version: str, state: str,
                        commit: str | None, git_state: str, checksum: str) -> None:
    con.execute(  # type: ignore[attr-defined]
        "INSERT INTO SYS_SEMANTIC.PRODUCT_INSTALLATIONS ("
        "PRODUCT_VERSION, RELEASE_STATE, GIT_COMMIT, GIT_STATE, RUNTIME_CHECKSUM"
        f") VALUES ({sql_literal(version)}, {sql_literal(state)}, "
        f"{sql_literal(commit)}, {sql_literal(git_state)}, {sql_literal(checksum)})"
    )


def publish_example(con: object) -> None:
    """Validate and publish the demo model.

    Loading a model does not create its published schema; PUBLISH_MODEL does.
    """
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")  # type: ignore[attr-defined]
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")  # type: ignore[attr-defined]


def example_summary_lines(published: bool) -> list[str]:
    """Summary lines describing what the demo install actually left behind.

    An unpublished model has no schema at all, and Semantic SQL works anyway,
    so saying "published" when nothing was published sends people looking for
    views that do not exist.
    """
    if published:
        return [
            "  Sales model " + bold("published") + " at " + bold("SEMANTIC_SALES.SALES")
            + dim(" (typed views, BI-discoverable)"),
        ]
    return [
        "  Sales model " + bold("loaded") + dim(" (DRAFT — no published schema yet)"),
        dim("    Publish it to expose typed views to BI metadata:"),
        dim("      EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales');"),
    ]


def display_version(version: str, state: str) -> str:
    return version + "+dev" if state == "DEVELOPMENT" else version


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
        # A slash on its own is Exasol's script terminator. Script bodies are
        # Lua, so SQL quote tracking is not meaningful there (escaped Lua
        # strings can otherwise leave in_double set and absorb the next
        # script into the current statement).
        if line.strip() == "/":
            statement = "\n".join(current).strip()
            if statement:
                statements.append(statement)
            current = []
            in_single = False
            in_double = False
            continue

        idx = 0
        start = 0
        while idx < len(line):
            char = line[idx]
            nxt = line[idx + 1] if idx + 1 < len(line) else ""
            if char == "-" and nxt == "-" and not in_single and not in_double:
                # SQL and Lua both use -- for line comments. Ignore comment
                # quotes and semicolons without treating -- inside a literal
                # as a comment opener.
                line = line[:idx]
                break
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


def quote_ident(name: str) -> str:
    return '"' + str(name).replace('"', '""') + '"'


def discover_published_schemas(con: object) -> list[str]:
    """Every schema a PUBLISH_MODEL created, from the catalog and from the database.

    The catalog is the primary source, but it cannot describe a schema whose
    model row is already gone — and a reset that only reads the catalog can
    never clean up such an orphan, which is how a fully typed, BI-discoverable
    surface outlives the model that defined it. Every published schema also
    carries the SEMANTIC_DISCOVERY table PUBLISH_MODEL always creates, so that
    table is the physical evidence a reset can act on.
    """
    schemas: list[str] = []

    def add(name: object) -> None:
        text = str(name)
        if text and text.upper() not in {s.upper() for s in schemas}:
            schemas.append(text)

    catalog_readable = False
    try:
        rows = con.execute(  # type: ignore[union-attr]
            "SELECT COUNT(*) FROM SYS.EXA_ALL_VIEWS "
            "WHERE VIEW_SCHEMA = 'SEMANTIC_CATALOG' AND VIEW_NAME = 'MODELS'"
        ).fetchall()
        if rows and int(rows[0][0]) > 0:
            for row in con.execute(  # type: ignore[union-attr]
                "SELECT DISTINCT PUBLISHED_SCHEMA FROM SEMANTIC_CATALOG.MODELS "
                "WHERE PUBLISHED_SCHEMA IS NOT NULL ORDER BY PUBLISHED_SCHEMA"
            ).fetchall():
                if row and row[0]:
                    add(row[0])
        catalog_readable = True
    except Exception as exc:  # noqa: BLE001 - reported, not swallowed
        # A damaged catalog is exactly when orphans are manufactured, so this
        # is reported rather than silently treated as "nothing was published".
        print(f"  ! catalog unreadable while discovering published schemas: {exc}")

    try:
        for row in con.execute(  # type: ignore[union-attr]
            "SELECT DISTINCT TABLE_SCHEMA FROM SYS.EXA_ALL_TABLES "
            "WHERE TABLE_NAME = 'SEMANTIC_DISCOVERY' ORDER BY TABLE_SCHEMA"
        ).fetchall():
            if row and row[0]:
                add(row[0])
    except Exception as exc:  # noqa: BLE001 - reported, not swallowed
        print(f"  ! could not scan for orphaned published schemas: {exc}")
        if not catalog_readable:
            raise RuntimeError(
                "--reset cannot enumerate published schemas: neither the semantic "
                "catalog nor SYS.EXA_ALL_TABLES could be read. Refusing to reset "
                "rather than leaving published schemas behind."
            ) from exc
    return schemas


# Tables that changed name, oldest first. `SYS_SEMANTIC` has no schema-version
# column and every table is created with `CREATE TABLE IF NOT EXISTS`, so a
# rename would otherwise leave an upgraded deployment with the old table holding
# the rows and a new empty one beside it.
#
# `RENAME TABLE` is the right instrument rather than create-and-copy: it carries
# the rows *and the identity counter*. Inserting explicit ids into an IDENTITY
# column does not advance the generator — verified against Exasol — so a copy
# migration would hand out ids that collide with the ones it just restored.
#
# Guarded on both sides, so this is a no-op on a fresh install (neither table
# exists) and on a re-install (only the new one does).
RENAMED_TABLES = [
    ("AGENT_SUGGESTIONS", "MODEL_EVOLUTION_SUGGESTIONS"),
    ("AGENT_SUGGESTION_REVIEWS", "MODEL_EVOLUTION_REVIEWS"),
    ("AGENT_SUGGESTION_TARGETS", "MODEL_EVOLUTION_TARGETS"),
]


def table_exists(con: object, schema: str, table: str) -> bool:
    rows = con.execute(
        "SELECT 1 FROM SYS.EXA_ALL_TABLES "
        f"WHERE TABLE_SCHEMA = '{schema}' AND TABLE_NAME = '{table}'"
    ).fetchall()
    return bool(rows)


# Columns added to a table that `CREATE TABLE IF NOT EXISTS` will not add to an
# existing catalog. Each is (table, column, DDL type/default).
ADDED_COLUMNS = [
    ("MODELS", "GOVERNANCE_MODE", "VARCHAR(16) DEFAULT 'OPEN' NOT NULL"),
]


def column_exists(con: object, schema: str, table: str, column: str) -> bool:
    rows = con.execute(
        "SELECT 1 FROM SYS.EXA_ALL_COLUMNS "
        f"WHERE COLUMN_SCHEMA = '{schema}' AND COLUMN_TABLE = '{table}' "
        f"AND COLUMN_NAME = '{column}'"
    ).fetchall()
    return bool(rows)


def migrate_added_columns(con: object) -> list[str]:
    """Add columns an existing catalog predates. Returns what it added.

    `001` creates tables with `CREATE TABLE IF NOT EXISTS`, so a table that is
    already there keeps its old shape however the file changes. Without this a
    reinstall over an existing catalog leaves the column missing and every read
    of it fails at runtime rather than at install.
    """
    added = []
    for table, column, ddl in ADDED_COLUMNS:
        if not table_exists(con, "SYS_SEMANTIC", table):
            continue
        if column_exists(con, "SYS_SEMANTIC", table, column):
            continue
        con.execute(f"ALTER TABLE SYS_SEMANTIC.{table} ADD COLUMN {column} {ddl}")
        added.append(f"{table}.{column}")
    return added


def migrate_renamed_tables(con: object) -> list[str]:
    """Carry an existing catalog across a table rename. Returns what it moved."""
    moved = []
    for old, new in RENAMED_TABLES:
        if not table_exists(con, "SYS_SEMANTIC", old):
            continue
        if table_exists(con, "SYS_SEMANTIC", new):
            # Both present: a previous run was interrupted between the rename and
            # the drop, or someone recreated the old name. The new table is
            # authoritative, so retire the predecessor rather than guess.
            con.execute(f"DROP TABLE IF EXISTS SYS_SEMANTIC.{old} CASCADE")
            moved.append(f"{old} (dropped; {new} already present)")
            continue
        con.execute(f"RENAME TABLE SYS_SEMANTIC.{old} TO {new}")
        moved.append(f"{old} -> {new}")
    return moved


def reset_statements(con: object) -> list[str]:
    dynamic = []
    seen = set(RESET_SCHEMA_NAMES)
    for schema_name in discover_published_schemas(con):
        normalized = schema_name.upper()
        if normalized not in seen:
            dynamic.append(f"DROP SCHEMA IF EXISTS {quote_ident(schema_name)} CASCADE")
            seen.add(normalized)
    return dynamic + RESET_STATEMENTS


# ── core steps ────────────────────────────────────────────────────────────────

# Every line tools/package_lua_scripts.py prints per file. Anything else it
# writes is an advisory and is passed through untouched.
PACKAGER_STATUSES = frozenset({"updated", "unchanged"})


def format_packager_line(line: str) -> str:
    """Align one line of packager output with the installer's other steps.

    The packager emits "<status> <path>", so the status is the *first* word --
    the previous reformatting read it as the last, which would have dimmed the
    path and labelled the row "unchanged" had it ever run. Anything that is not a
    known status is an advisory (the main-chunk local ceiling), already indented
    and with no status word to align on, so it passes through untouched.
    """
    status, separator, name = line.partition(" ")
    if separator and status in PACKAGER_STATUSES:
        return f"      {Path(name).name:<48} {dim(status)}"
    return line


def run_package_lua(quiet: bool = False) -> None:
    spec = importlib.util.spec_from_file_location(
        "package_lua_scripts", ROOT / "tools/package_lua_scripts.py"
    )
    mod = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    if quiet:
        import io, contextlib
        buf = io.StringIO()
        # main() has to be inside the redirect: it is what prints. Loading the
        # module only defines things, so capturing exec_module alone left `output`
        # permanently empty and the reformatting below permanently dead, which is
        # why the packager's own lines appeared unindented among the aligned ones.
        with contextlib.redirect_stdout(buf):
            spec.loader.exec_module(mod)  # type: ignore[union-attr]
            mod.main()
        # Trim only the surrounding blank lines: an advisory line carries its
        # own indentation and .strip() would eat the first one's.
        output = buf.getvalue().strip("\n")
    else:
        spec.loader.exec_module(mod)  # type: ignore[union-attr]
        mod.main()
        output = None

    if quiet and output:
        for line in output.splitlines():
            print(format_packager_line(line))


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
        "--publish", action="store_true",
        help="publish the demo model after loading it, creating the BI-discoverable "
             "views in SEMANTIC_SALES (implies --example)",
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

    # --publish implies --example: there is nothing else to publish.
    if args.publish:
        args.example = True
    total_steps = (3 + (1 if args.example else 0) + (1 if args.reset else 0)
                   + (1 if args.publish else 0))
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
        for stmt in reset_statements(con):
            con.execute(stmt)
        print(green("done"))

    # install
    step += 1
    print(f"\n[{step}/{total_steps}] Installing {len(INSTALL_FILES)} SQL files")
    t_install = time.monotonic()
    for moved in migrate_renamed_tables(con):
        print(f"      {dim('migrated ' + moved)}")
    run_sql_files(con, INSTALL_FILES, "install")
    # After the files, because the table has to exist before a column can be
    # added to it, and a fresh install creates it with the column already there.
    for added in migrate_added_columns(con):
        print(f"      {dim('added column ' + added)}")
    install_elapsed = time.monotonic() - t_install

    # record which build this deployment is now running, before the example
    # so the row exists even if the demo load fails.
    changelog = ROOT / "CHANGELOG.md"
    version, release_state = latest_release_version(
        changelog.read_text(encoding="utf-8") if changelog.exists() else ""
    )
    commit, git_state = git_provenance(ROOT)
    checksum = runtime_checksum(INSTALL_FILES)
    record_installation(con, version, release_state, commit, git_state, checksum)

    # optional: example
    if args.example:
        step += 1
        print(f"\n[{step}/{total_steps}] Loading sales example model")
        run_sql_files(con, EXAMPLE_FILES, "example")

    # Optional: publish. Loading the model does not create its published
    # schema -- PUBLISH_MODEL does. Semantic SQL works either way, because the
    # preprocessor rewrites from the catalog, so an unpublished model is easy
    # to miss until a BI client reads JDBC/ODBC metadata and finds nothing.
    # Left opt-in because a published model is a governed contract: authoring
    # against it requires compound declarations and passes prospective
    # validation, which is friction for a model people poke at while learning.
    if args.publish:
        step += 1
        print(f"\n[{step}/{total_steps}] Publishing the sales model", end="  ", flush=True)
        publish_example(con)
        print(green("done"))

    con.close()

    # summary
    print()
    print("─" * 42)
    provenance = display_version(version, release_state)
    if commit:
        provenance += f"  ·  git {commit[:7]}"
        if git_state != "CLEAN":
            provenance += f" ({git_state.lower()})"
    provenance += f"  ·  runtime {checksum[:12]}"
    if args.example:
        print(green("✓") + f" Installation complete  {dim(f'({install_elapsed:.1f}s)')}")
        print()
        print("  " + bold(f"Exasol Semantic Views {provenance}"))
        print(dim("  SELECT * FROM SEMANTIC_CATALOG.PRODUCT_VERSION;"))
        print()
        for line in example_summary_lines(args.publish):
            print(line)
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
        print("  " + bold(f"Exasol Semantic Views {provenance}"))
        print(dim("  SELECT * FROM SEMANTIC_CATALOG.PRODUCT_VERSION;"))
        print()
        print("  Next steps:")
        print(f"    Load the sales demo:  {dim('python3 tools/install.py --example')}")
        print(f"    Read the docs:        {dim('docs/creating-metrics.md')}")
        print(f"    Enable Semantic SQL:  {dim('EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL();')}")
    print()

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
