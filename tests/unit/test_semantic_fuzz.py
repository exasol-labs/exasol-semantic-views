"""Database-free contracts for the shared semantic fuzz runner."""

from __future__ import annotations

import dataclasses
import hashlib
import io
import json
import random
import re
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
                              LabelledSqlCase, PairedCase, PairedTlpCase, Profile,
                              ReferenceCase, validate_case)
from tests.fuzz.connection import ExasolBackend  # noqa: E402
from tests.fuzz.generators.handwritten import (DIMENSIONS, METRICS,  # noqa: E402
                                               HandwrittenGenerator, gen_spec,
                                               gen_tlp_case)
from tests.fuzz.generators.sqlglot_generator import SqlglotGenerator  # noqa: E402
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
    def test_sqlglot_profiles_render_and_label_cases(self):
        from sqlglot import parse_one
        from sqlglot.errors import ErrorLevel, ParseError

        generator = SqlglotGenerator()
        first_rng, again_rng = random.Random(42), random.Random(42)
        first = [generator.generate(first_rng, Profile.LABELLED_SQL, 42, i)
                 for i in range(30)]
        again = [generator.generate(again_rng, Profile.LABELLED_SQL, 42, i)
                 for i in range(30)]
        self.assertEqual(first, again)
        self.assertEqual({case.label.syntax_intent for case in first}, {"valid", "invalid"})
        self.assertTrue(any(case.label.rule == "unknown-field" for case in first))
        for case in first:
            validate_case(case, Profile.LABELLED_SQL)
            if case.label.syntax_intent == "invalid":
                self.assertEqual(case.label.expected_status, "REJECT")
                with self.assertRaises(ParseError):
                    parse_one(case.sql, dialect="exasol", error_level=ErrorLevel.RAISE)
            else:
                parse_one(case.sql, dialect="exasol", error_level=ErrorLevel.RAISE)
        self.assertTrue(any("WHERE" in case.sql and "GROUP BY" in case.sql
                            and case.sql.index("WHERE") < case.sql.index("GROUP BY")
                            for case in first))

    def test_malformed_sql_varies_with_seeded_generation(self):
        generator = SqlglotGenerator()
        rng = random.Random(42)
        malformed = [case for idx in range(500)
                     if (case := generator.generate(rng, Profile.LABELLED_SQL, 42, idx))
                     .label.syntax_intent == "invalid"]
        self.assertEqual(len(malformed), 100)
        self.assertGreaterEqual(len({case.sql for case in malformed}), 20)
        self.assertEqual({case.label.rule for case in malformed},
                         {"SEMANTIC_QUERY_033", "SEMANTIC_QUERY_050"})

    def test_sqlglot_joins_cover_every_grouping_key(self):
        generator = SqlglotGenerator()
        joins = [generator.generate(random.Random(1), Profile.LABELLED_SQL, 1, i)
                 for i in (4, 11, 25, 32)]
        self.assertTrue(any("INNER JOIN" in case.sql for case in joins))
        self.assertTrue(any("LEFT JOIN" in case.sql for case in joins))
        self.assertTrue(any(case.sql.startswith("WITH") for case in joins))
        for case in joins:
            self.assertEqual(case.label.shape, "grouped-join")
            self.assertEqual(case.label.syntax_intent, "valid")
            self.assertEqual(case.label.expected_status, "ACCEPT")
            self.assertIn("l.", case.sql)
            self.assertIn(" = r.", case.sql)
            self.assertNotIn("SEMANTIC_OTHER", case.sql)
            grouping = re.search(r"GROUP BY ([a-z_, ]+)", case.sql)
            self.assertIsNotNone(grouping)
            keys = {key.strip() for key in grouping.group(1).split(",")}
            joined = set(re.findall(r"l\.([a-z_]+) = r\.\1", case.sql))
            self.assertEqual(keys, joined)

    def test_unsafe_joins_have_specific_safety_refusals(self):
        generator = SqlglotGenerator()
        cases = [generator.generate(random.Random(7), Profile.LABELLED_SQL, 7, i)
                 for i in (6, 16, 26)]
        self.assertEqual({case.label.rule for case in cases},
                         {"missing-grouping-key", "cross-object-composition",
                          "ungrouped-relation"})
        for case in cases:
            self.assertEqual(case.label.syntax_intent, "valid")
            self.assertEqual(case.label.expected_status, "REJECT")
            self.assertEqual(case.label.expected_code, "SEMANTIC_QUERY_012")
        self.assertIn("ORDER_HEADER", cases[1].sql)
        self.assertEqual(len(re.findall(r"l\.([a-z_]+) = r\.\1", cases[0].sql)), 1)

    def test_sqlglot_paired_and_tlp_profiles(self):
        generator = SqlglotGenerator()
        paired = generator.generate(random.Random(3), Profile.PAIRED, 3, 2)
        validate_case(paired, Profile.PAIRED)
        self.assertIn(paired.json_payload["dimensions"][0], paired.sql)
        self.assertIn("SEMANTIC_SALES.SALES", paired.sql)
        tlp = generator.generate(random.Random(4), Profile.PAIRED_TLP, 4, 0)
        self.assertIsInstance(tlp, PairedTlpCase)
        validate_case(tlp, Profile.PAIRED_TLP)
        self.assertEqual(tlp.base.json_payload["metrics"], tlp.predicate.json_payload["metrics"])
        self.assertEqual(tlp.base.json_payload["dimensions"], tlp.null.json_payload["dimensions"])
        self.assertNotIn("filters", tlp.base.json_payload)
        self.assertEqual(tlp.null.json_payload["filters"][0]["op"], "IS NULL")
        self.assertNotEqual(tlp.predicate.json_payload["filters"][0]["op"],
                            tlp.complement.json_payload["filters"][0]["op"])
        for variant in (tlp.base, tlp.predicate, tlp.complement, tlp.null):
            self.assertIn(variant.json_payload["metrics"][0], variant.sql)

    def test_sqlglot_reference_is_independent(self):
        case = SqlglotGenerator().generate(random.Random(0), Profile.REFERENCE, 0, 0)
        self.assertIsInstance(case, ReferenceCase)
        validate_case(case, Profile.REFERENCE)
        self.assertIn("SEMANTIC_SALES.SALES", case.sql)
        self.assertIn("MART.ORDERS", case.reference_sql)
        self.assertNotEqual(case.sql, case.reference_sql)

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
            (0, "differential"): "b9932cc87bd18838589220d92237aaa5ca70ad1585a52022f0e92f3814264d0c",
            (0, "tlp"): "118c26bf68e1f84111acf2aa49bfd0a358023762bedca2ebf01e2e3d5e646d04",
            (42, "differential"): "2aa261870b74380b93b5cd75b6f2322d29910a6edd9c846d0a91881a859fbfe5",
            (42, "tlp"): "d5cb1a7cacdf893c8d14e05ea0c1dbd5e8ec3ed2764eab609130af64f177a2f6",
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

    def test_runner_streams_cases_in_seed_order(self):
        events = []

        class Generator:
            name = "streaming"
            profiles = frozenset({Profile.PAIRED})

            def generate(self, rng, profile, seed, idx):
                if idx:
                    self.assertion(idx)
                events.append(("generate", idx, rng.randrange(1000)))
                return PairedCase(CaseLabel(seed, idx), {"model": "sales"}, "SELECT 1")

            def assertion(self, idx):
                self_test.assertEqual(events[-1][:2], ("run", idx - 1))

        class Oracle:
            name = "streaming"
            accepted_profiles = (Profile.PAIRED,)
            database_free = True

            def run(self, backend, case, verbose):
                events.append(("run", case.label.idx))
                return CaseResult(case.label.idx, "match")

        self_test = self
        backend = _TestBackend()
        with redirect_stdout(io.StringIO()):
            self.assertEqual(run_campaign(Generator(), Oracle(), 7, 3, False,
                                          backend_factory=lambda: backend), 0)
        self.assertEqual([item[:2] for item in events],
                         [("generate", 0), ("run", 0), ("generate", 1),
                          ("run", 1), ("generate", 2), ("run", 2)])
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
        handwritten = HandwrittenGenerator()
        only_sql = type("OnlySql", (), {
            "name": "sql", "accepted_profiles": (Profile.LABELLED_SQL,),
        })()
        with self.assertRaisesRegex(ValueError, "no shared case profile"):
            select_profile(handwritten, only_sql)
        called = False

        def factory():
            nonlocal called
            called = True
            return _LiveBackend()

        missing = _MissingGenerator()
        differential = DifferentialOracle()
        with self.assertRaisesRegex(ValueError, "paired case needs JSON and SQL"):
            run_campaign(missing, differential, 0, 1, False, backend_factory=factory)
        self.assertFalse(called)

    def test_tlp_profiles_reject_variants_with_the_wrong_shape(self):
        label = CaseLabel(0, 0)
        json_variant = {"model": "sales"}
        paired_variant = PairedCase(label, json_variant, "SELECT 1")
        with self.assertRaisesRegex(ValueError, "TLP variant base"):
            validate_case(PairedTlpCase(label, json_variant, paired_variant,
                                        paired_variant, paired_variant), Profile.PAIRED_TLP)
        with self.assertRaisesRegex(ValueError, "TLP variant base"):
            validate_case(JsonTlpCase(label, paired_variant, json_variant,
                                      json_variant, json_variant), Profile.JSON_TLP)
        validate_case(PairedTlpCase(label, paired_variant, paired_variant,
                                    paired_variant, paired_variant), Profile.PAIRED_TLP)
        validate_case(JsonTlpCase(label, json_variant, json_variant,
                                  json_variant, json_variant), Profile.JSON_TLP)

    def test_sqlglot_contract_never_needs_exasol(self):
        if shutil.which("lua") is None:
            self.skipTest("Lua unavailable")
        from tests.fuzz.run_semantic_fuzz import main

        with redirect_stdout(io.StringIO()):
            self.assertEqual(main(["--generator", "sqlglot", "--cases", "3"]), 0)

    def test_lua_driver_stream_preserves_ids_and_join_contracts(self):
        command = shutil.which("lua")
        if command is None:
            self.skipTest("Lua unavailable")
        generator = SqlglotGenerator()
        cases = [generator.generate(random.Random(3), Profile.LABELLED_SQL, 3, i)
                 for i in (4, 11, 6, 16, 26)]
        requests = "".join(json.dumps({"id": 100 + index, "sql": case.sql}) + "\n"
                           for index, case in enumerate(cases))
        completed = subprocess.run(
            [command, "tests/lua/semantic_fuzz_driver.lua"], input=requests,
            text=True, capture_output=True, cwd=ROOT, check=True,
        )
        replies = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], list(range(100, 105)))
        self.assertEqual([(reply["status"], reply["generated_sql_present"])
                          for reply in replies],
                         [("OK", True), ("OK", True), ("ERROR", False),
                          ("ERROR", False), ("ERROR", False)])
        self.assertEqual({reply["error_code"] for reply in replies[2:]},
                         {"SEMANTIC_QUERY_012"})

    def test_fuzz_fields_and_filter_samples_match_bundled_sales(self):
        sales_sql = (ROOT / "sql/examples/sales_physical_model.sql").read_text()
        self.assertEqual([name for name, _, _ in DIMENSIONS],
                         ["customer_region", "order_status", "product_category",
                          "order_month"])
        self.assertEqual(METRICS, ["total_revenue", "completed_revenue",
                                   "gross_margin", "total_cost"])
        for name, _, samples in DIMENSIONS:
            for sample in samples:
                if name == "order_month":
                    self.assertRegex(sales_sql, rf"DATE '{sample[:7]}-\d\d'")
                else:
                    self.assertIn(f"'{sample}'", sales_sql)
        if shutil.which("lua") is None:
            self.skipTest("Lua unavailable")
        backend = LuaBackend(5)
        try:
            for index, (name, _, _) in enumerate(DIMENSIONS):
                result = backend.compile(index,
                    f"SELECT {name}, total_revenue FROM SEMANTIC_SALES.SALES GROUP BY {name}")
                self.assertEqual(result["status"], "OK", name)
                self.assertTrue(result["generated_sql_present"], name)
            for index, name in enumerate(METRICS, start=len(DIMENSIONS)):
                result = backend.compile(index,
                    f"SELECT order_status, {name} FROM SEMANTIC_SALES.SALES GROUP BY order_status")
                self.assertEqual(result["status"], "OK", name)
                self.assertTrue(result["generated_sql_present"], name)
            for index, name in enumerate(("ship_mode", "customer_segment"),
                                         start=len(DIMENSIONS) + len(METRICS)):
                result = backend.compile(index,
                    f"SELECT {name}, total_freight FROM SEMANTIC_SALES.ORDER_HEADER "
                    f"GROUP BY {name}")
                self.assertEqual(result["status"], "OK", name)
                self.assertTrue(result["generated_sql_present"], name)
        finally:
            backend.close()

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
