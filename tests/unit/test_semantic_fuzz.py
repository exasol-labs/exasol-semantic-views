"""Database-free contracts for the shared semantic fuzz runner."""

from __future__ import annotations

import dataclasses
import hashlib
import io
import json
import random
import shutil
import subprocess
import sys
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from tests.fuzz.cases import (CaseLabel, CaseResult, JsonTlpCase,  # noqa: E402
                              LabelledSqlCase, PairedCase, Profile)
from tests.fuzz.connection import ExasolBackend  # noqa: E402
from tests.fuzz.generators.handwritten import HandwrittenGenerator, gen_spec, gen_tlp_case  # noqa: E402
from tests.fuzz.lua_backend import CaseTimeout, LuaBackend  # noqa: E402
from tests.fuzz.oracles.contract_oracle import ContractOracle  # noqa: E402
from tests.fuzz.oracles.differential_oracle import DifferentialOracle  # noqa: E402
from tests.fuzz.oracles.tlp_oracle import TlpOracle  # noqa: E402
from tests.fuzz.run_semantic_fuzz import run_campaign, select_profile  # noqa: E402


class _Rows:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0]

    def fetchall(self):
        return self.rows


class _LiveBackend:
    def __init__(self):
        self.closed = False

    def execute(self, sql):
        if "PUBLISH_MODEL" in sql:
            return _Rows([])
        return _Rows([(1,)])

    def compile_json(self, payload):
        return {"status": "OK", "generated_sql": "SELECT 1"}

    def compile_sql(self, sql):
        return {"status": "OK", "generated_sql": "SELECT 1"}

    def close(self, disconnect=True):
        self.closed = True


class _FixedGenerator:
    name = "fixed"
    profiles = frozenset({Profile.PAIRED})

    def generate(self, rng, profile, seed, idx):
        return PairedCase(CaseLabel(seed, idx), {"model": "sales"},
                          "SELECT total_revenue FROM SEMANTIC_SALES.SALES")


class _MissingGenerator(_FixedGenerator):
    def generate(self, rng, profile, seed, idx):
        return PairedCase(CaseLabel(seed, idx), {}, "")


class _TestOracle:
    name = "test"
    accepted_profiles = (Profile.PAIRED,)
    database_free = True

    def run(self, backend, case, verbose):
        assert isinstance(case, PairedCase)
        return CaseResult(case.label.idx, "match")


class _TestBackend:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


class SemanticFuzzTest(unittest.TestCase):
    def test_connection_wrapper_owns_compile_calls(self):
        class Connection:
            def __init__(self):
                self.sql = []
                self.disconnect = None

            def execute(self, sql):
                self.sql.append(sql)
                return _Rows([("OK", None, None, None, "SELECT 1")])

            def close(self, disconnect=True):
                self.disconnect = disconnect

        connection = Connection()
        backend = ExasolBackend(connection)
        self.assertEqual(backend.compile_json({"value": "O'Reilly"})["status"], "OK")
        self.assertEqual(backend.compile_sql("SELECT 'O'Reilly'")["generated_sql"], "SELECT 1")
        self.assertIn("O''Reilly", connection.sql[0])
        self.assertIn("O''Reilly", connection.sql[1])
        backend.close(disconnect=False)
        self.assertFalse(connection.disconnect)

    def test_handwritten_seeded_sequences_are_unchanged(self):
        expected = {
            (0, "differential"): "2b7b7d1f817cbbb4182e3995a6aa995a0fdbe362d0b2f62d258f4f7840d5af3c",
            (0, "tlp"): "e3cccef73467b3a6b570b367ecb392a918d9a732afd1fc78beda2a0ebd3cf8df",
            (42, "differential"): "56f807910f94300057b2ad57ee9bb31ab123320c9c1d501eaf44d428770a55e7",
            (42, "tlp"): "c10ada95fbc194fe0ae7c36cb18900222f4c8a558615b776601a2f342428bb8e",
        }
        for (seed, name), digest in expected.items():
            rng = random.Random(seed)
            generate = gen_spec if name == "differential" else gen_tlp_case
            cases = [dataclasses.asdict(generate(rng)) for _ in range(30)]
            observed = hashlib.sha256(json.dumps(cases, sort_keys=True).encode()).hexdigest()
            self.assertEqual(observed, digest)

    def test_custom_generator_runs_existing_oracle(self):
        backend = _LiveBackend()
        with redirect_stdout(io.StringIO()):
            result = run_campaign(_FixedGenerator(), DifferentialOracle(), 7, 1, False,
                                  backend_factory=lambda: backend)
        self.assertEqual(result, 0)
        self.assertTrue(backend.closed)

    def test_existing_differential_verdicts(self):
        case = _FixedGenerator().generate(random.Random(0), Profile.PAIRED, 0, 0)

        class Backend:
            def __init__(self, codes):
                self.codes = iter(codes)

            def compile_json(self, payload):
                return {"status": "ERROR", "error_code": next(self.codes),
                        "error_message": "refused"}

            def compile_sql(self, sql):
                return {"status": "ERROR", "error_code": next(self.codes),
                        "error_message": "refused"}

        oracle = DifferentialOracle()
        self.assertEqual(oracle.run(Backend(("SEMANTIC_REQUEST_080", "SEMANTIC_QUERY_080")),
                                    case, False).verdict, "both-error")
        self.assertEqual(oracle.run(Backend(("SEMANTIC_REQUEST_080", "SEMANTIC_QUERY_081")),
                                    case, False).verdict, "status-mismatch")

    def test_existing_tlp_verdict(self):
        case = JsonTlpCase(CaseLabel(0, 0), {"variant": "base"},
                           {"variant": "true"}, {"variant": "false"},
                           {"variant": "null"})

        class Backend:
            def compile_json(self, payload):
                return {"status": "OK", "generated_sql": payload["variant"]}

            def execute(self, sql):
                return _Rows([("North", {"base": 10, "true": 6, "false": 4,
                                         "null": 0}[sql])])

        self.assertEqual(TlpOracle().run(Backend(), case, False).verdict, "match")

    def test_contract_oracle_checks_expected_code(self):
        case = LabelledSqlCase(CaseLabel(0, 0, expected_status="REJECT",
                                         expected_code="SEMANTIC_QUERY_006"), "SELECT bad")

        class Backend:
            def __init__(self, code):
                self.code = code

            def compile(self, idx, sql):
                return {"status": "ERROR", "error_code": self.code,
                        "generated_sql_present": False}

        oracle = ContractOracle()
        self.assertEqual(oracle.run(Backend("SEMANTIC_QUERY_006"), case, False).verdict,
                         "match")
        self.assertEqual(oracle.run(Backend("SEMANTIC_QUERY_008"), case, False).verdict,
                         "contract-mismatch")

    def test_custom_oracle_runs_existing_generator(self):
        backend = _TestBackend()
        with redirect_stdout(io.StringIO()):
            result = run_campaign(HandwrittenGenerator(), _TestOracle(), 3, 3, False,
                                  backend_factory=lambda: backend)
        self.assertEqual(result, 0)
        self.assertTrue(backend.closed)

    def test_incompatible_and_incomplete_profiles_fail_before_backend(self):
        with self.assertRaisesRegex(ValueError, "no shared case profile"):
            select_profile(HandwrittenGenerator(), type("OnlySql", (), {
                "name": "sql", "accepted_profiles": (Profile.LABELLED_SQL,),
            })())
        called = False

        def factory():
            nonlocal called
            called = True
            return _LiveBackend()

        with self.assertRaisesRegex(ValueError, "paired case needs JSON and SQL"):
            run_campaign(_MissingGenerator(), DifferentialOracle(), 0, 1, False,
                         backend_factory=factory)
        self.assertFalse(called)

    def test_sqlglot_contract_never_needs_exasol(self):
        if shutil.which("lua") is None:
            self.skipTest("Lua unavailable")
        from tests.fuzz.run_semantic_fuzz import main

        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(["--generator", "sqlglot", "--cases", "3"]), 0)

    def test_lua_driver_reports_harness_errors(self):
        command = shutil.which("lua")
        if command is None:
            self.skipTest("Lua unavailable")
        completed = subprocess.run(
            [command, "tests/lua/semantic_fuzz_driver.lua"], input="bad JSON\n",
            text=True, capture_output=True, cwd=ROOT, check=True,
        )
        self.assertEqual(json.loads(completed.stdout)["status"], "HARNESS_ERROR")

    def test_lua_backend_rejects_wrong_id_and_timeout(self):
        class Process:
            stdin = io.StringIO()
            stdout = io.StringIO('{"id":4,"status":"OK","generated_sql_present":true}\n')
            stderr = io.StringIO()

        backend = object.__new__(LuaBackend)
        backend.timeout = 1
        backend.process = Process()
        with patch("tests.fuzz.lua_backend.select.select", return_value=([backend.process.stdout], [], [])):
            with self.assertRaisesRegex(RuntimeError, "reply ID"):
                backend.compile(3, "SELECT 1")
        with patch("tests.fuzz.lua_backend.select.select", return_value=([], [], [])):
            with self.assertRaises(CaseTimeout):
                backend.compile(3, "SELECT 1")


if __name__ == "__main__":
    unittest.main()
