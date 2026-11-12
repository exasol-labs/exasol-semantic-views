#!/usr/bin/env python3
"""Fuzz the semantic compiler with interchangeable generators and oracles.

The default hand-written differential and TLP campaigns require the installed
sales seed model. SQLGlot's contract campaign runs against Lua without Exasol.

Usage:
    python3 tests/fuzz/run_semantic_fuzz.py
    python3 tests/fuzz/run_semantic_fuzz.py --oracle tlp
    python3 tests/fuzz/run_semantic_fuzz.py --generator sqlglot
    python3 tests/fuzz/run_semantic_fuzz.py --seed 42 --cases 200 --verbose
"""

from __future__ import annotations

import argparse
import os
import random
import signal
import sys
from pathlib import Path
from typing import Any, Callable

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
    __package__ = "tests.fuzz"

from .cases import Generator, Oracle, Profile, validate_case  # noqa: E402
from .connection import connect  # noqa: E402
from .generators.handwritten import HandwrittenGenerator  # noqa: E402
from .generators.sqlglot_generator import SqlglotGenerator  # noqa: E402
from .lua_backend import CaseTimeout, LuaBackend  # noqa: E402
from .oracles.contract_oracle import ContractOracle  # noqa: E402
from .oracles.differential_oracle import DifferentialOracle  # noqa: E402
from .oracles.tlp_oracle import TlpOracle  # noqa: E402
from .reporting import print_failures, print_result  # noqa: E402


# pyexasol 3 reports usage on connect; a test run never does.
os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "true")

CASE_TIMEOUT = int(os.environ.get("FUZZ_CASE_TIMEOUT", "120"))
GENERATORS: dict[str, Generator] = {
    "handwritten": HandwrittenGenerator(), "sqlglot": SqlglotGenerator(),
}
ORACLES: dict[str, Oracle] = {
    "differential": DifferentialOracle(), "tlp": TlpOracle(), "contract": ContractOracle(),
}
VERDICTS = ("match", "both-error", "status-mismatch", "row-diff", "exec-error",
            "compile-error", "contract-mismatch")


def _case_timed_out(signum: int, frame: Any) -> None:
    raise CaseTimeout


def select_profile(generator: Generator, oracle: Oracle) -> Profile:
    for profile in oracle.accepted_profiles:
        if profile in generator.profiles:
            return profile
    offered = ", ".join(sorted(p.value for p in generator.profiles))
    accepted = ", ".join(p.value for p in oracle.accepted_profiles)
    raise ValueError(f"{generator.name}+{oracle.name} has no shared case profile "
                     f"(generator: {offered}; oracle: {accepted})")


def run_campaign(generator: Generator, oracle: Oracle, seed: int, cases: int,
                 verbose: bool, backend_factory: Callable[[], Any] | None = None) -> int:
    profile = select_profile(generator, oracle)
    rng = random.Random(seed)
    generated = []
    for idx in range(cases):
        case = generator.generate(rng, profile, seed, idx)
        validate_case(case, profile)
        if case.label.idx != idx or case.label.seed != seed:
            raise ValueError(f"case {idx}: generator returned the wrong seed or index")
        generated.append(case)

    backend: Any = (backend_factory() if backend_factory is not None else
                    LuaBackend(CASE_TIMEOUT) if oracle.database_free else connect())
    stalled = False
    previous_alarm = None
    try:
        if not oracle.database_free:
            backend.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")
            previous_alarm = signal.signal(signal.SIGALRM, _case_timed_out)
        counts = dict.fromkeys(VERDICTS, 0)
        failures = []
        good = {"match"} if oracle.database_free else {"match", "both-error"}
        for idx, case in enumerate(generated):
            if not oracle.database_free:
                signal.alarm(CASE_TIMEOUT)
            try:
                result = oracle.run(backend, case, verbose)
            except CaseTimeout:
                stalled = True
                if oracle.database_free:
                    print(f"FAIL [{idx:03d}] no answer from Lua within {CASE_TIMEOUT}s")
                else:
                    print(f"FAIL [{idx:03d}] no answer from the database within {CASE_TIMEOUT}s; "
                          "it has probably stopped serving sessions (see docs/runtime-testing.md)")
                return 2
            finally:
                if not oracle.database_free:
                    signal.alarm(0)
            counts[result.verdict] = counts.get(result.verdict, 0) + 1
            print_result(result, good)
            if result.verdict not in good:
                failures.append(result)

        print()
        print("=" * 60)
        for verdict, count in counts.items():
            if verdict == "contract-mismatch" and not oracle.database_free:
                continue
            print(f"  {verdict:16s} {count}")
        if failures:
            print_failures(failures)
            return 1
        print(f"\nAll {cases} cases equivalent under seed={seed}, oracle={oracle.name}.")
        return 0
    finally:
        if previous_alarm is not None:
            signal.signal(signal.SIGALRM, previous_alarm)
        if oracle.database_free:
            backend.close()
        else:
            backend.close(disconnect=not stalled)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--cases", type=int, default=30)
    parser.add_argument("--generator", choices=tuple(GENERATORS), default="handwritten")
    parser.add_argument("--oracle", choices=tuple(ORACLES))
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args(argv)
    oracle_name = args.oracle or ("contract" if args.generator == "sqlglot" else "differential")
    try:
        return run_campaign(GENERATORS[args.generator], ORACLES[oracle_name],
                            args.seed, args.cases, args.verbose)
    except (ValueError, RuntimeError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
