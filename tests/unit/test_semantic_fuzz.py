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
from tests.fuzz.oracles.accepted_differential_oracle import AcceptedDifferentialOracle  # noqa: E402
from tests.fuzz.oracles.contract_oracle import ContractOracle  # noqa: E402
from tests.fuzz.oracles.differential_oracle import DifferentialOracle  # noqa: E402
from tests.fuzz.oracles.paired_tlp_oracle import PairedTlpOracle  # noqa: E402
from tests.fuzz.oracles.reference_oracle import ReferenceOracle  # noqa: E402
from tests.fuzz.oracles.row_comparison import compare_typed_rows  # noqa: E402
from tests.fuzz.oracles.tlp_oracle import TlpOracle  # noqa: E402
from tests.fuzz.reporting import CampaignSummary, FailureRecord, print_summary  # noqa: E402
from tests.fuzz.run_semantic_fuzz import run_campaign, select_profile  # noqa: E402


class _Rows:
    def __init__(self, rows):
        self.rows = rows

    def fetchone(self):
        return self.rows[0]

    def fetchall(self):
        return self.rows

    def columns(self):
        return {name: None for name in
                ("STATUS", "ERROR_CODE", "ERROR_MESSAGE", "PLAN_JSON", "GENERATED_SQL")}


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
        self.assertEqual({case.label.rule for case in first if case.label.syntax_intent == "valid"},
                         {"documented-subset", "omitted-grouping-dimension",
                          "measure-dimension", "invalid-ordinal", "whole-grouping-key",
                          "missing-grouping-key", "or-join", "using-join",
                          "cross-object-composition"})
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

    def test_sqlglot_seed_varies_choices_within_a_scheduled_rule(self):
        generator = SqlglotGenerator()
        accepted = [generator.generate(random.Random(seed), Profile.LABELLED_SQL,
                                       seed, 0) for seed in range(5)]
        joins = [generator.generate(random.Random(seed), Profile.LABELLED_SQL,
                                    seed, 4) for seed in range(5)]
        self.assertEqual({case.label.rule for case in accepted}, {"documented-subset"})
        self.assertEqual({case.label.rule for case in joins}, {"whole-grouping-key"})
        self.assertGreater(len({case.sql for case in accepted}), 1)
        self.assertGreater(len({case.sql for case in joins}), 1)

    def test_malformed_sql_varies_with_seeded_generation(self):
        generator = SqlglotGenerator()
        rng = random.Random(42)
        malformed = [case for idx in range(500)
                     if (case := generator.generate(rng, Profile.LABELLED_SQL, 42, idx))
                     .label.syntax_intent == "invalid"]
        self.assertEqual(len(malformed), 50)
        self.assertGreaterEqual(len({case.sql for case in malformed}), 10)
        self.assertEqual({case.label.rule for case in malformed},
                         {"missing-predicate-value", "missing-having-value",
                          "missing-limit-value"})

    def test_sqlglot_joins_cover_every_grouping_key_and_distinct_metrics(self):
        generator = SqlglotGenerator()
        rng = random.Random(1)
        joins = [generator.generate(rng, Profile.LABELLED_SQL, 1, i)
                 for i in range(4, 304, 10)]
        self.assertTrue(any("INNER JOIN" in case.sql for case in joins))
        self.assertTrue(any("LEFT JOIN" in case.sql for case in joins))
        self.assertTrue(any(case.sql.startswith("WITH") for case in joins))
        for case in joins:
            self.assertEqual(case.label.shape, "grouped-join")
            self.assertEqual(case.label.syntax_intent, "valid")
            self.assertEqual(case.label.expected_status, "ACCEPT")
            self.assertIn("l.total_revenue, r.total_cost", case.sql)
            self.assertIn("total_revenue FROM SEMANTIC_SALES.SALES", case.sql)
            self.assertIn("total_cost FROM SEMANTIC_SALES.SALES", case.sql)
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
                 for i in (5, 6, 7, 8)]
        self.assertEqual({case.label.rule for case in cases},
                         {"missing-grouping-key", "or-join", "using-join",
                          "cross-object-composition"})
        for case in cases:
            self.assertEqual(case.label.syntax_intent, "valid")
            self.assertEqual(case.label.expected_status, "REJECT")
            self.assertEqual(case.label.expected_code, "SEMANTIC_QUERY_012")
        self.assertIn("ORDER_HEADER", cases[3].sql)
        self.assertEqual(len(re.findall(r"l\.([a-z_]+) = r\.\1", cases[0].sql)), 1)
        for case in cases:
            self.assertIsNotNone(case.control_sql)
            self.assertNotEqual(case.control_sql, case.sql)

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

    def test_sqlglot_accepted_refusal_fails_even_when_both_paths_refuse(self):
        case = PairedCase(CaseLabel(4, 0, expected_status="ACCEPT"),
                          {"dimensions": ["order_status"], "metrics": ["total_revenue"]},
                          "SELECT order_status, total_revenue FROM SEMANTIC_SALES.SALES")

        class Refusing:
            def compile_json(self, payload):
                return {"status": "ERROR", "error_code": "SEMANTIC_REQUEST_080"}

            def compile_sql(self, sql):
                return {"status": "ERROR", "error_code": "SEMANTIC_QUERY_080"}

        self.assertEqual(AcceptedDifferentialOracle().run(Refusing(), case, False).verdict,
                         "compile-error")

    def test_sqlglot_paired_projection_order_and_alias(self):
        case = PairedCase(CaseLabel(4, 0, expected_status="ACCEPT"),
                          {"dimensions": ["order_status"], "metrics": ["total_revenue"]},
                          "SELECT total_revenue AS amount, order_status AS state "
                          "FROM SEMANTIC_SALES.SALES")

        class Backend:
            def compile_json(self, payload):
                return {"status": "OK", "generated_sql": "json"}

            def compile_sql(self, sql):
                return {"status": "OK", "generated_sql": "sql"}

            def execute(self, sql):
                return _Rows([("COMPLETE", 2)] if sql == "json" else [(2, "COMPLETE")])

        self.assertEqual(AcceptedDifferentialOracle().run(Backend(), case, False).verdict,
                         "match")

    def test_typed_rows_keep_names_exact_and_tolerate_numeric_roundoff(self):
        from decimal import Decimal
        self.assertIsNone(compare_typed_rows([("North", Decimal("1.0000000"))],
                                              [("North", 1.0000001)]))
        self.assertIsNone(compare_typed_rows([("North", "1.0000000")],
                                              [("North", "1.0000001")]))
        self.assertIsNotNone(compare_typed_rows([("North", 1)], [("north", 1)]))
        self.assertIsNotNone(compare_typed_rows([("North", 1)], [("North", 1.01)]))

    def test_typed_rows_align_unordered_numeric_representations(self):
        from decimal import Decimal
        self.assertIsNone(compare_typed_rows([(2, "two"), (10, "ten")],
                                              [(Decimal("10.0"), "ten"),
                                               (Decimal("2.0"), "two")]))

    def test_paired_tlp_runs_all_four_variants_on_both_paths(self):
        label = CaseLabel(4, 0)
        variants = [PairedCase(label, {"variant": name}, name)
                    for name in ("base", "p", "not_p", "null")]
        case = PairedTlpCase(label, *variants)

        class Backend:
            calls = []

            def compile_json(self, payload):
                self.calls.append(("json", payload["variant"]))
                return {"status": "OK", "generated_sql": payload["variant"]}

            def compile_sql(self, sql):
                self.calls.append(("sql", sql))
                return {"status": "OK", "generated_sql": sql}

            def execute(self, sql):
                return _Rows([("North", {"base": 10, "p": 6,
                                         "not_p": 4, "null": 0}[sql])])

        backend = Backend()
        self.assertEqual(PairedTlpOracle().run(backend, case, False).verdict, "match")
        self.assertEqual(len(backend.calls), 8)

    def test_reference_oracle_checks_preprocessor_refusal_code(self):
        case = ReferenceCase(CaseLabel(4, 0), "unsafe join", "",
                             "SEMANTIC_QUERY_012")

        class Backend:
            def compile_sql(self, sql):
                return {"status": "ERROR", "error_code": "SEMANTIC_QUERY_012"}

            def execute_preprocessed(self, sql):
                raise RuntimeError("SEMANTIC_QUERY_012: unsafe join")

        self.assertEqual(ReferenceOracle().run(Backend(), case, False).verdict, "match")

    def test_reference_oracle_checks_each_execution_against_physical_rows(self):
        case = ReferenceCase(CaseLabel(4, 0), "semantic SQL", "physical SQL")

        class Backend:
            def __init__(self, compiled, preprocessed):
                self.compiled = compiled
                self.preprocessed = preprocessed

            def compile_sql(self, sql):
                return {"status": "OK", "generated_sql": "generated SQL"}

            def execute(self, sql):
                return _Rows([(self.compiled if sql == "generated SQL" else 10,)])

            def execute_preprocessed(self, sql):
                return _Rows([(self.preprocessed,)])

        oracle = ReferenceOracle()
        self.assertEqual(oracle.run(Backend(10, 10), case, False).verdict, "match")
        self.assertEqual(oracle.run(Backend(9, 10), case, False).stage, "compare-compiled")
        self.assertEqual(oracle.run(Backend(10, 9), case, False).stage, "compare-preprocessor")

    def test_live_oracles_propagate_case_timeout(self):
        label = CaseLabel(4, 0, expected_status="ACCEPT")
        paired = PairedCase(label, {"metrics": ["total_revenue"]},
                            "SELECT total_revenue FROM SEMANTIC_SALES.SALES")
        tlp = PairedTlpCase(label, paired, paired, paired, paired)
        reference = ReferenceCase(label, paired.sql, "SELECT 1")

        class TimedOut:
            def compile_json(self, payload):
                raise CaseTimeout

            def compile_sql(self, sql):
                raise CaseTimeout

        for oracle, case in ((AcceptedDifferentialOracle(), paired),
                             (PairedTlpOracle(), tlp), (ReferenceOracle(), reference)):
            backend = TimedOut()
            with self.subTest(oracle=oracle.name):
                with self.assertRaises(CaseTimeout):
                    oracle.run(backend, case, False)

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

    def test_contract_mutations_have_accepted_controls_and_exact_codes(self):
        generator = SqlglotGenerator()
        rng = random.Random(0)
        backend = LuaBackend(5)
        try:
            cases = [generator.generate(rng, Profile.LABELLED_SQL, 0, idx)
                     for idx in range(10)]
            self.assertEqual({case.label.rule for case in cases[1:4]},
                             {"omitted-grouping-dimension", "measure-dimension",
                              "invalid-ordinal"})
            self.assertEqual({case.label.rule for case in cases[5:9]},
                             {"missing-grouping-key", "or-join", "using-join",
                              "cross-object-composition"})
            self.assertEqual(cases[9].label.syntax_intent, "invalid")
            for case in cases:
                self.assertEqual(ContractOracle().run(backend, case, False).verdict,
                                 "match", case.label.rule)
            self.assertEqual(len(re.findall(r"GROUP BY [^)]*,", cases[5].sql)), 2)
        finally:
            backend.close()

    def test_short_contract_run_exercises_distinct_equivalent_variants(self):
        generator = SqlglotGenerator()
        rng = random.Random(0)
        accepted = [generator.generate(rng, Profile.LABELLED_SQL, 0, idx)
                    for idx in range(30) if idx % 10 == 0]
        self.assertEqual(len(accepted), 3)
        self.assertTrue(all(case.variant_sql and case.variant_sql != case.sql
                            for case in accepted))
        self.assertIn(" AS s", accepted[0].sql)
        self.assertNotIn(" GROUP BY ", accepted[1].sql)
        self.assertIn("MEASURE(", accepted[2].sql)
        self.assertTrue(all('"order_status"' in case.variant_sql for case in accepted))

    def test_variant_plan_mismatch_reports_both_queries_and_changed_fields(self):
        class Backend:
            def compile(self, idx, sql):
                dimensions = ["order_status"] if sql == "original" else ["customer_region"]
                return {"status": "OK", "generated_sql_present": True,
                        "plan_json": json.dumps({"dimensions": dimensions})}

        case = LabelledSqlCase(CaseLabel(7, 0, expected_status="ACCEPT"),
                               "original", variant_sql="variant")
        result = ContractOracle().run(Backend(), case, False)
        self.assertEqual(result.verdict, "contract-mismatch")
        self.assertIn("dimensions", result.detail)
        self.assertIn("order_status", result.expected)
        self.assertIn("customer_region", result.actual)
        self.assertEqual(result.sql_text, "original")
        self.assertEqual(result.variant_sql, "variant")
        output = io.StringIO()
        with redirect_stdout(output):
            print_summary(CampaignSummary({"contract-mismatch": 1}, {"ACCEPT": 1},
                                          {"documented-subset": 1},
                                          [FailureRecord(case.label, result)], 1, 7,
                                          "contract", True, "sqlglot"))
        self.assertIn("generator=sqlglot oracle=contract seed=7 case=0", output.getvalue())
        self.assertIn("original SQL:  original", output.getvalue())
        self.assertIn("variant SQL:   variant", output.getvalue())

    def test_variant_refusal_reports_both_queries_and_outcomes(self):
        class Backend:
            def compile(self, idx, sql):
                if sql == "original":
                    return {"status": "OK", "generated_sql_present": True}
                return {"status": "ERROR", "error_code": "SEMANTIC_QUERY_029",
                        "generated_sql_present": False}

        case = LabelledSqlCase(CaseLabel(7, 0, expected_status="ACCEPT"),
                               "original", variant_sql="variant")
        result = ContractOracle().run(Backend(), case, False)
        self.assertEqual(result.verdict, "contract-mismatch")
        self.assertEqual(result.expected, "OK/-")
        self.assertEqual(result.actual, "ERROR/SEMANTIC_QUERY_029")
        self.assertEqual(result.sql_text, "original")
        self.assertEqual(result.variant_sql, "variant")

    def test_supported_case_refusal_fails_and_shrinks(self):
        class Backend:
            def compile(self, idx, sql):
                return {"status": "ERROR", "error_code": "SEMANTIC_QUERY_029",
                        "generated_sql_present": False}

        case = SqlglotGenerator().generate(random.Random(0), Profile.LABELLED_SQL, 0, 0)
        result = ContractOracle().run(Backend(), case, False)
        self.assertEqual(result.verdict, "contract-mismatch")
        self.assertEqual(result.actual, "ERROR/SEMANTIC_QUERY_029")
        self.assertIsNotNone(result.minimized_sql)
        self.assertLess(len(result.minimized_sql), len(case.sql))
        self.assertNotIn("both-error", result.verdict)

    def test_shrink_keeps_the_clause_that_triggers_the_failure(self):
        class Backend:
            def compile(self, idx, sql):
                if " HAVING " in sql:
                    return {"status": "ERROR", "error_code": "SEMANTIC_QUERY_029",
                            "generated_sql_present": False}
                return {"status": "OK", "generated_sql_present": True}

        case = SqlglotGenerator().generate(random.Random(0), Profile.LABELLED_SQL, 0, 0)
        result = ContractOracle().run(Backend(), case, False)
        self.assertEqual(result.verdict, "contract-mismatch")
        self.assertIn(" HAVING ", result.minimized_sql)
        self.assertIn(" AS s", result.minimized_sql)
        self.assertNotIn(" LIMIT ", result.minimized_sql)
        self.assertNotIn(" ORDER BY ", result.minimized_sql)

    def test_rejected_case_wrongly_accepted_fails(self):
        class Backend:
            def compile(self, idx, sql):
                return {"status": "OK", "generated_sql_present": True}

        case = SqlglotGenerator().generate(random.Random(0), Profile.LABELLED_SQL, 0, 5)
        result = ContractOracle().run(Backend(), case, False)
        self.assertEqual(result.verdict, "contract-mismatch")
        self.assertEqual(result.expected, "REJECT/SEMANTIC_QUERY_012")
        self.assertEqual(result.actual, "OK/-")

    def test_custom_oracle_runs_existing_generator(self):
        backend = _TestBackend()
        with redirect_stdout(io.StringIO()):
            result = run_campaign(HandwrittenGenerator(), _TestOracle(), 3, 3, False,
                                  backend_factory=lambda: backend)
        self.assertEqual(result, 0)
        self.assertTrue(backend.closed)

    def test_runner_reports_failure_context_without_changing_result(self):
        result = CaseResult(0, "row-diff", detail="different rows", sql_text="SELECT 1")

        class FailingOracle:
            name = "failing"
            accepted_profiles = (Profile.PAIRED,)
            database_free = True

            def run(self, backend, case, verbose):
                return result

        output = io.StringIO()
        with redirect_stdout(output):
            status = run_campaign(_FixedGenerator(), FailingOracle(), 5, 1, False,
                                  backend_factory=_TestBackend)
        self.assertEqual(status, 1)
        self.assertIn("generator=fixed oracle=failing seed=5 case=0", output.getvalue())
        self.assertIsNone(result.seed)
        self.assertEqual(result.rule, "")

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
                 for i in (4, 14, 5, 6, 7, 8)]
        requests = "".join(json.dumps({"id": 100 + index, "sql": case.sql}) + "\n"
                           for index, case in enumerate(cases))
        completed = subprocess.run(
            [command, "tests/lua/semantic_fuzz_driver.lua"], input=requests,
            text=True, capture_output=True, cwd=ROOT, check=True,
        )
        replies = [json.loads(line) for line in completed.stdout.splitlines()]
        self.assertEqual([reply["id"] for reply in replies], list(range(100, 106)))
        self.assertEqual([(reply["status"], reply["generated_sql_present"])
                          for reply in replies],
                         [("OK", True), ("OK", True), ("ERROR", False),
                          ("ERROR", False), ("ERROR", False), ("ERROR", False)])
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
        class Stdout:
            def fileno(self):
                return 1

        class Process:
            stdin = io.BytesIO()
            stdout = Stdout()
            stderr = None

        backend = object.__new__(LuaBackend)
        backend.timeout = 1
        backend.case_deadline = None
        backend.pending = bytearray()
        backend.process = Process()
        with patch("tests.fuzz.lua_backend.select.select", return_value=([backend.process.stdout], [], [])), \
             patch("tests.fuzz.lua_backend.os.read", return_value=b'{"id":4,"status":"OK","generated_sql_present":true}\n'):
            with self.assertRaisesRegex(RuntimeError, "reply ID"):
                backend.compile(3, "SELECT 1")
        with patch("tests.fuzz.lua_backend.select.select", return_value=([], [], [])):
            with self.assertRaises(CaseTimeout):
                backend.compile(3, "SELECT 1")


if __name__ == "__main__":
    unittest.main()
