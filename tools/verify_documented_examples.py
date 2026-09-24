#!/usr/bin/env python3
"""Every statement a doc prints next to an expected code is run, verbatim.

`docs/bi-tools.md` §4 printed a join together with `SEMANTIC_QUERY_012`, and
`QUERY_CAPABILITIES` published the same code for the same shape. Run verbatim,
that statement returned `SEMANTIC_QUERY_003` -- "FROM must reference one
published semantic object", which is not true of a statement that references
exactly one. `tools/verify_query_capabilities_contract.py` did not catch it
because it demonstrates the join *without* the aggregation, and the aggregation
is what changed the answer. A contract verified with a statement the verifier
chose is testing the implementation; the statement a reader will copy is the one
that has to hold.

So the docs themselves are the fixture here. Any fenced SQL block whose body is
followed by a `-- SEMANTIC_..._NNN` comment is extracted, executed in the lane
its first word implies, and every code named in that comment must appear in the
refusal. Nothing is transcribed into this file, so the two cannot drift: editing
the statement in the doc edits the test, and editing the expected code there
edits the assertion.

`EXPECTED_EXAMPLES` pins how many such blocks exist. It is a ratchet in the
direction that matters: the count may rise freely, and lowering it is how you
would notice an annotation being deleted to make a failure go away.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from verify_support import connect  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
PREPROCESSOR = "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR"
BLOCK = re.compile(r"```sql\n(.*?)```", re.S)
EXPECTATION = re.compile(r"^\s*--\s*(SEMANTIC_[A-Z]+_\d+)")
CODE = re.compile(r"SEMANTIC_[A-Z]+_\d+")

# Raise this when you add a documented example; never lower it to pass.
EXPECTED_EXAMPLES = 2

failures: list[str] = []


def ok(name: str, detail: str = "") -> None:
    print(f"ok {name}" + (f": {detail}" if detail else ""))


def fail(name: str, detail: str) -> None:
    failures.append(name)
    print(f"FAIL {name}: {detail}")


def examples():
    """(source, statement, expected codes) for every annotated doc block."""
    for path in sorted((ROOT / "docs").glob("*.md")):
        for block in BLOCK.findall(path.read_text(encoding="utf-8")):
            lines = block.split("\n")
            first = next((i for i, line in enumerate(lines)
                          if EXPECTATION.match(line)), None)
            if first is None:
                continue
            statement = "\n".join(lines[:first]).strip().rstrip(";").strip()
            # Every code the comment names, including ones a refusal nests: the
            # example in docs/examples.md prints the admin code *and* the
            # validation rule that caused it, and both are the claim.
            expected = CODE.findall("\n".join(lines[first:]))
            if statement:
                yield path.name, statement, expected


def main() -> int:
    admin = connect()
    admin.execute("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
    lane = connect()
    lane.execute(f"ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = {PREPROCESSOR}")

    found = list(examples())
    if len(found) < EXPECTED_EXAMPLES:
        fail("no documented example lost its expected code",
             f"{len(found)} annotated blocks, expected at least {EXPECTED_EXAMPLES}")
    else:
        ok(f"{len(found)} documented examples carry an expected code")

    for source, statement, expected in found:
        # An admin script is a mutation and runs as itself; anything else is a
        # query a reader would send through a preprocessor-enabled session.
        connection = admin if statement.upper().startswith("EXECUTE SCRIPT") else lane
        name = f"{source}: {statement.splitlines()[0][:56]}…"
        try:
            connection.execute(statement).fetchall()
            fail(name, f"expected {expected}, but the statement was accepted")
            continue
        except Exception as exception:  # noqa: BLE001 -- the refusal is the result
            returned = " ".join(str(exception).split())
        missing = [code for code in expected if code not in returned]
        if missing:
            got = CODE.findall(returned) or ["no code"]
            fail(name, f"expected {missing}, got {sorted(set(got))}")
        else:
            ok(name, " ".join(expected))

    # The docs/examples.md case claims the catalog is restored. If the refusal
    # ever stops rolling back, the model is left carrying a metric that makes
    # every later verifier's model different from the shipped one.
    leftover = admin.execute(
        "SELECT METRIC_NAME FROM SYS_SEMANTIC.METRICS"
        " WHERE METRIC_NAME = 'freight_in_sales'").fetchall()
    if leftover:
        fail("a refused authoring example leaves nothing behind",
             "freight_in_sales survived; the catalog was not restored")
    else:
        ok("a refused authoring example leaves nothing behind")

    if failures:
        print(f"\n{len(failures)} documented example(s) do not hold: "
              + ", ".join(failures))
        return 1
    print("\ndocumented examples verified.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
