"""Live-database integration tests, discovered and run by pytest.

Everything here runs against an installed deployment: tools/run_smoke.sh
installs the sales example and its materializations, then runs
`pytest tests/integration`. Run a single test the usual way, e.g.
`pytest tests/integration -k order_by`.

Two kinds of module live here:

- `test_*.py` -- pytest tests, using the fixtures below.
- `verify_*.py` -- scripts written before the move to pytest. Each is collected
  as one test that runs the script exactly as run_smoke.sh used to, in its own
  process, and fails on a non-zero exit. Convert one to `test_*.py` when you
  next touch it; tests/test_conventions.py pins how many remain, and the number
  only shrinks.

A test must establish the state it needs -- publish the model, register the
materialization -- rather than rely on a test that happened to run before it.
The one exception is `fresh_install/`: tests of what the installer itself
leaves behind, which only hold before anything else has run. run_smoke.sh runs
that directory straight after the install, and it is collected only when named
explicitly.
"""

from __future__ import annotations

import os
import subprocess
import sys
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))

import verify_support as support  # noqa: E402


# -- legacy verifier scripts ------------------------------------------------

class VerifierFailed(Exception):
    def __init__(self, result: subprocess.CompletedProcess[str]) -> None:
        super().__init__(f"exit status {result.returncode}")
        self.result = result


# A stuck script fails instead of stalling the suite. The slowest takes about a
# minute; override with VERIFIER_TIMEOUT (seconds) for a slow deployment.
VERIFIER_TIMEOUT = float(os.environ.get("VERIFIER_TIMEOUT", "600"))


class VerifierRun(pytest.Item):
    """One verify_*.py script, run in its own process."""

    def runtest(self) -> None:
        try:
            result = subprocess.run([sys.executable, str(self.path)], cwd=ROOT,
                                    capture_output=True, text=True, timeout=VERIFIER_TIMEOUT)
        except subprocess.TimeoutExpired as expired:
            output = "".join(part.decode() if isinstance(part, bytes) else part or ""
                             for part in (expired.stdout, expired.stderr))
            raise VerifierFailed(subprocess.CompletedProcess(
                expired.cmd, -1, output, f"timed out after {VERIFIER_TIMEOUT:.0f}s")) from None
        self.add_report_section("call", "stdout", result.stdout)
        self.add_report_section("call", "stderr", result.stderr)
        if result.returncode != 0:
            raise VerifierFailed(result)

    def repr_failure(self, excinfo: Any, style: Any = None) -> str:
        if isinstance(excinfo.value, VerifierFailed):
            result = excinfo.value.result
            tail = (result.stdout + result.stderr).strip().splitlines()[-40:]
            return f"{self.path.name} exited {result.returncode}:\n" + "\n".join(tail)
        return str(super().repr_failure(excinfo))

    def reportinfo(self) -> tuple[Path, int, str]:
        return self.path, 0, self.path.name


class VerifierScript(pytest.File):
    def collect(self) -> Iterator[VerifierRun]:
        yield VerifierRun.from_parent(self, name=self.path.stem)


def pytest_ignore_collect(collection_path: Path, config: pytest.Config) -> bool | None:
    if collection_path.name == "fresh_install" and not any(
            "fresh_install" in str(arg) for arg in config.args):
        return True
    return None


def pytest_collect_file(parent: pytest.Collector, file_path: Path) -> pytest.Collector | None:
    if (file_path.suffix == ".py" and file_path.name.startswith("verify_")
            and file_path.name != "verify_support.py"):
        return VerifierScript.from_parent(parent, path=file_path)
    return None


# -- fixtures -----------------------------------------------------------------

@pytest.fixture(scope="session", autouse=True)
def installed_example() -> None:
    """Every test reads the installed sales example; say so once, plainly."""
    con = support.connect()
    try:
        found = con.execute("SELECT COUNT(*) FROM SYS_SEMANTIC.MODELS"
                            " WHERE UPPER(MODEL_NAME) = 'SALES'").fetchone()[0]
    except Exception as exc:  # noqa: BLE001 -- any failure means not installed
        found, reason = 0, str(exc).splitlines()[0]
    else:
        reason = "no model named sales"
    finally:
        con.close()
    if not found:
        pytest.exit("integration tests need the sales example installed "
                    f"(python3 tools/install.py --example, or sh tools/run_smoke.sh): {reason}",
                    returncode=2)


@pytest.fixture
def con() -> Iterator[Any]:
    """A connection with no preprocessor, closed after the test."""
    connection = support.connect()
    try:
        yield connection
    finally:
        connection.close()


@pytest.fixture
def semantic_con(con: Any) -> Any:
    """A connection with the semantic preprocessor enabled for its session."""
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
    return con
