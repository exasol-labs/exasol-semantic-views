#!/usr/bin/env python3
"""Regression tests for installer reset schema discovery."""

from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("semantic_install", ROOT / "tools/install.py")
INSTALL = importlib.util.module_from_spec(SPEC)  # type: ignore[arg-type]
SPEC.loader.exec_module(INSTALL)  # type: ignore[union-attr]


class Result:
    def __init__(self, rows):
        self.rows = rows

    def fetchall(self):
        return self.rows


class Connection:
    def __init__(self, catalog_exists=True, catalog_broken=False, orphans=()):
        self.catalog_exists = catalog_exists
        self.catalog_broken = catalog_broken
        self.orphans = list(orphans)
        self.sql = []

    def execute(self, sql):
        self.sql.append(sql)
        if "EXA_ALL_TABLES" in sql and "SEMANTIC_DISCOVERY" in sql:
            # The physical evidence of a published schema, which is how a reset
            # finds one whose catalog row is already gone.
            return Result([(name,) for name in self.orphans])
        if "EXA_ALL_VIEWS" in sql:
            return Result([(1 if self.catalog_exists else 0,)])
        if "SEMANTIC_CATALOG.MODELS" in sql:
            if self.catalog_broken:
                raise RuntimeError("catalog unavailable")
            return Result([
                ("SEMANTIC_ECOMMERCE",),
                ("semantic_sales",),
                (None,),
            ])
        raise AssertionError(f"unexpected SQL: {sql}")


class BuildProvenanceTest(unittest.TestCase):
    """A deployment must be able to say which build it is running."""

    def test_latest_release_version_reports_development_above_a_tag(self):
        changelog = "# Changelog\n\n## [Unreleased]\n\n### Fixed\n\n- something\n\n## [0.1] - 2026-08-19\n\n- first\n"
        self.assertEqual(INSTALL.latest_release_version(changelog), ("0.1", "DEVELOPMENT"))

    def test_latest_release_version_reports_released_on_an_empty_unreleased(self):
        changelog = "# Changelog\n\n## [Unreleased]\n\n## [0.2] - 2026-09-01\n\n- notes\n\n## [0.1] - 2026-08-19\n"
        self.assertEqual(INSTALL.latest_release_version(changelog), ("0.2", "RELEASED"))

    def test_latest_release_version_without_a_release_heading(self):
        self.assertEqual(INSTALL.latest_release_version("# Changelog\n"), ("UNKNOWN", "UNKNOWN"))

    def test_display_version_marks_development_builds(self):
        self.assertEqual(INSTALL.display_version("0.1", "DEVELOPMENT"), "0.1+dev")
        self.assertEqual(INSTALL.display_version("0.1", "RELEASED"), "0.1")

    def test_runtime_checksum_tracks_the_installed_sql(self):
        first = INSTALL.runtime_checksum(INSTALL.INSTALL_FILES)
        self.assertEqual(first, INSTALL.runtime_checksum(INSTALL.INSTALL_FILES))
        self.assertEqual(len(first), 64)
        # A different file set must not collide with the real one.
        self.assertNotEqual(first, INSTALL.runtime_checksum(INSTALL.INSTALL_FILES[:-1]))

    def test_git_provenance_reports_clean_dirty_and_unknown(self):
        def runner(argv, **kwargs):
            if argv[3] == "rev-parse":
                return _Completed(0, "abc1234def\n")
            return _Completed(0, "")

        self.assertEqual(INSTALL.git_provenance(ROOT, runner), ("abc1234def", "CLEAN"))

        def dirty_runner(argv, **kwargs):
            if argv[3] == "rev-parse":
                return _Completed(0, "abc1234def\n")
            return _Completed(0, " M tools/install.py\n")

        self.assertEqual(INSTALL.git_provenance(ROOT, dirty_runner), ("abc1234def", "DIRTY"))

        def no_repo(argv, **kwargs):
            return _Completed(128, "")

        self.assertEqual(INSTALL.git_provenance(ROOT, no_repo), (None, "UNKNOWN"))

        def no_git(argv, **kwargs):
            raise FileNotFoundError("git")

        self.assertEqual(INSTALL.git_provenance(ROOT, no_git), (None, "UNKNOWN"))

        def status_fails(argv, **kwargs):
            if argv[3] == "rev-parse":
                return _Completed(0, "abc1234def\n")
            return _Completed(1, "")

        self.assertEqual(INSTALL.git_provenance(ROOT, status_fails), ("abc1234def", "UNKNOWN"))

    def test_record_installation_escapes_and_inserts_one_row(self):
        connection = RecordingConnection()
        INSTALL.record_installation(connection, "0.1", "DEVELOPMENT", "abc", "DIRTY", "f" * 64)
        self.assertEqual(len(connection.sql), 1)
        self.assertIn("INSERT INTO SYS_SEMANTIC.PRODUCT_INSTALLATIONS", connection.sql[0])
        self.assertIn("'DEVELOPMENT'", connection.sql[0])

        INSTALL.record_installation(connection, "0.1", "RELEASED", None, "UNKNOWN", "f" * 64)
        self.assertIn("NULL", connection.sql[1])
        self.assertEqual(INSTALL.sql_literal("O'Reilly"), "'O''Reilly'")

    def test_catalog_publishes_the_recorded_row(self):
        catalog = (ROOT / "sql/install/001_create_semantic_catalog.sql").read_text(
            encoding="utf-8"
        )
        views = (ROOT / "sql/install/002_create_semantic_catalog_views.sql").read_text(
            encoding="utf-8"
        )
        self.assertIn("CREATE TABLE IF NOT EXISTS SYS_SEMANTIC.PRODUCT_INSTALLATIONS", catalog)
        self.assertIn("CREATE OR REPLACE VIEW SEMANTIC_CATALOG.PRODUCT_VERSION", views)
        self.assertIn("CREATE OR REPLACE VIEW SEMANTIC_CATALOG.PRODUCT_INSTALL_HISTORY", views)


class ExampleInstallSummaryTest(unittest.TestCase):
    """Loading a model does not publish it, and the summary must say so."""

    def test_publish_example_validates_before_publishing(self):
        connection = RecordingConnection()
        INSTALL.publish_example(connection)
        self.assertEqual(len(connection.sql), 2)
        self.assertIn("VALIDATE_MODEL('sales')", connection.sql[0])
        self.assertIn("PUBLISH_MODEL('sales')", connection.sql[1])

    def test_summary_does_not_claim_a_publish_that_did_not_happen(self):
        drafted = "\n".join(INSTALL.example_summary_lines(False))
        self.assertIn("DRAFT", drafted)
        self.assertIn("PUBLISH_MODEL('sales')", drafted)
        self.assertNotIn("published at", drafted)

        published = "\n".join(INSTALL.example_summary_lines(True))
        self.assertIn("SEMANTIC_SALES.SALES", published)
        self.assertNotIn("DRAFT", published)


class _Completed:
    def __init__(self, returncode, stdout):
        self.returncode = returncode
        self.stdout = stdout


class RecordingConnection:
    def __init__(self):
        self.sql = []

    def execute(self, sql):
        self.sql.append(sql)


class InstallerResetTest(unittest.TestCase):
    def test_expression_function_discovery_matches_validator_allow_list(self):
        validator = (
            ROOT / "lua/semantic_layer/admin/validator.lua"
        ).read_text(encoding="utf-8")
        allow_list = validator.split("local ALLOWED_FUNCTIONS = {", 1)[1].split(
            "}", 1
        )[0]
        allowed = set(re.findall(r"^\s+([A-Z_]+) = true,$", allow_list, re.MULTILINE))

        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/006_create_semantic_agent_views.sql").read_text(
                encoding="utf-8"
            )
        )
        discovery = next(
            sql
            for sql in statements
            if "SEMANTIC_AGENT.EXPRESSION_FUNCTIONS_FOR_AGENT AS" in sql
        )
        exposed = set(
            re.findall(r"(?:SELECT|UNION ALL SELECT) '([A-Z_]+)'", discovery)
        )

        self.assertEqual(allowed, exposed)
        self.assertTrue(
            {"UPPER", "LOWER", "TRIM", "LTRIM", "RTRIM", "SUBSTR", "REPLACE"}
            <= allowed
        )

    def test_admin_validation_gates_block_session_preconditions(self):
        admin_sql = (
            ROOT / "sql/install/003_create_semantic_admin_scripts.sql"
        ).read_text(encoding="utf-8")
        hand_authored = admin_sql.split("-- BEGIN GENERATED VALIDATOR_RUNTIME", 1)[0]
        error_only_checks = (
            'if tostring(row_value(validation_row, "SEVERITY", 1)) == "ERROR" then',
            'if tostring(row_value(row, "SEVERITY", 1)) == "ERROR" then',
            'if row_value(row, "SEVERITY", 1) == "ERROR" then',
            'if tostring(severity) == "ERROR" then',
        )
        for check in error_only_checks:
            self.assertNotIn(check, hand_authored)
        self.assertIn('or tostring(severity) == "PRECONDITION"', hand_authored)
        self.assertIn('validation_status = tostring(severity)', hand_authored)

    def test_agent_readiness_always_exposes_published_session_instructions(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/006_create_semantic_agent_views.sql").read_text(
                encoding="utf-8"
            )
        )
        models = next(
            sql
            for sql in statements
            if "SEMANTIC_AGENT.MODELS_FOR_AGENT AS" in sql
        )
        self.assertIn("SESSION_SETUP_REQUIRED", models)
        self.assertIn("SESSION_SETUP_SQL", models)
        self.assertIn("SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL", models)
        self.assertIn("m.STATUS <> 'PUBLISHED' THEN 'NOT_PUBLISHED'", models)
        self.assertIn("VALIDATION_PRECONDITION_COUNT", models)
        self.assertIn("THEN 'PRECONDITION'", models)

        instructions = next(
            sql
            for sql in statements
            if "SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT AS" in sql
        )
        self.assertIn("m.MODEL_STATUS = 'PUBLISHED'", instructions)
        self.assertIn("m.SESSION_SETUP_SQL", instructions)
        self.assertIn("m.PREPROCESSOR_QUALIFIED_NAME", instructions)
        self.assertIn("STRUCTURED_REQUEST does not require session setup", instructions)
        self.assertIn("ALTER SESSION SET QUERY_TIMEOUT=60", instructions)
        self.assertIn("'PRECONDITION' AS INSTRUCTION_KIND", instructions)
        self.assertIn("FROM SYS_SEMANTIC.AGENT_INSTRUCTIONS ai", instructions)

        validation_issues = next(
            sql
            for sql in statements
            if "SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT AS" in sql
        )
        self.assertIn("('ERROR', 'PRECONDITION')", validation_issues)

    def test_f7_model_evolution_surface_is_installable(self):
        statements = []
        for path in INSTALL.INSTALL_FILES:
            statements.extend(INSTALL.split_exasol_sql(path.read_text(encoding="utf-8")))
        expected_fragments = {
            "SYS_SEMANTIC.MODEL_EVOLUTION_REVIEWS",
            "SYS_SEMANTIC.MODEL_EVOLUTION_TARGETS",
            "SEMANTIC_CATALOG.MODEL_EVOLUTION_SUGGESTIONS",
            "SEMANTIC_CATALOG.MODEL_EVOLUTION_REVIEWS",
            "SEMANTIC_AGENT.MODEL_EVOLUTION_REVIEW_QUEUE",
            "SEMANTIC_ADMIN.PROPOSE_MODEL_EVOLUTION",
            "SEMANTIC_ADMIN.REVIEW_MODEL_EVOLUTION",
        }
        for fragment in expected_fragments:
            self.assertTrue(any(fragment in sql for sql in statements), fragment)

    def test_f2_binding_install_surface_is_split_into_statements(self):
        statements = []
        for path in INSTALL.INSTALL_FILES:
            statements.extend(INSTALL.split_exasol_sql(path.read_text(encoding="utf-8")))
        expected_fragments = {
            "SYS_SEMANTIC.ATTRIBUTE_BINDINGS",
            "SEMANTIC_CATALOG.ATTRIBUTE_BINDINGS",
            "SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING",
            "SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING",
            "SEMANTIC_ADMIN.REMOVE_ATTRIBUTE_BINDING",
        }
        for fragment in expected_fragments:
            self.assertTrue(any(fragment in sql for sql in statements), fragment)

        add_binding = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING(")
        )
        self.assertLess(
            add_binding.index("baseline_validation_rows"),
            add_binding.index("INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS"),
        )
        self.assertIn("if not baseline_errors[signature]", add_binding)

        replace_binding = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING(")
        )
        self.assertLess(
            replace_binding.index("baseline_validation_rows"),
            replace_binding.index("UPDATE SYS_SEMANTIC.ATTRIBUTE_BINDINGS"),
        )
        self.assertIn("previous_expression", replace_binding)
        self.assertIn("replacement rejected and restored", replace_binding)
        self.assertIn("if not baseline_errors[signature]", replace_binding)

    def test_representation_promotion_preserves_explicit_binding_precedence(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        promotion = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION(")
        )
        self.assertIn("stale_default_count", promotion)
        self.assertIn("stale default bindings were repaired", promotion)
        self.assertIn("explicit.IS_DEFAULT = FALSE", promotion)
        self.assertIn("explicit.REPRESENTATION_ID = :representation_id", promotion)
        self.assertIn("AND NOT EXISTS (", promotion)
        self.assertIn("target representation '", promotion)
        self.assertIn("cannot anchor declared unique-key column", promotion)
        self.assertIn("bare DIRECT identity binding", promotion)
        self.assertIn("STATUS = 'STALE' AND :allow_stale_recovery = TRUE", promotion)
        self.assertIn("recovery_from_invalid_primary", promotion)
        self.assertLess(
            promotion.index("cannot anchor declared unique-key column"),
            promotion.index("SET REPRESENTATION_ROLE = 'ALTERNATE'"),
        )
        self.assertLess(
            promotion.index("stale_default_count"),
            promotion.index("SET REPRESENTATION_ROLE = 'ALTERNATE'"),
        )

    def test_f3_coverage_admin_surface_is_installable(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        coverage = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE(")
        )
        self.assertIn("COVERAGE_PREDICATE = :coverage_predicate", coverage)
        self.assertIn("VALID_FROM = :valid_from", coverage)
        self.assertIn("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE", coverage)
        self.assertIn("STATUS = 'STALE'", coverage)
        self.assertIn('if tostring(model_status) == "PUBLISHED"', coverage)
        self.assertIn("previous_predicate", coverage)
        self.assertIn("published coverage change rejected and restored", coverage)
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", coverage)
        self.assertLess(
            coverage.index("SET COVERAGE_PREDICATE = :coverage_predicate"),
            coverage.index("published coverage change rejected and restored"),
        )
        self.assertLess(
            coverage.index("VALID_TO = :valid_to", coverage.index("candidate_validation")),
            coverage.index("published coverage change rejected and restored"),
        )

        batch = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH(")
        )
        self.assertIn("coverage batch must declare every active representation", batch)
        self.assertIn("for _, item in ipairs(prepared) do", batch)
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", batch)
        self.assertIn("published coverage batch rejected and restored", batch)
        self.assertIn('or "array is empty"', batch)
        self.assertLess(
            batch.index("for _, item in ipairs(prepared) do"),
            batch.index("candidate_validation"),
        )

        representation_batch = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE(")
        )
        self.assertIn("INSERT INTO SYS_SEMANTIC.ENTITY_REPRESENTATIONS", representation_batch)
        self.assertIn("SET_REPRESENTATION_COVERAGE_BATCH", representation_batch)
        self.assertIn("representation-plus-coverage candidate rejected", representation_batch)

    def test_f3_attribute_creation_seeds_every_partition(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        scripts = {
            name: next(
                sql for sql in statements if f"SEMANTIC_ADMIN.{name}(" in sql
            )
            for name in ("ADD_DIMENSION", "ADD_FACT", "ADD_OR_REPLACE_DIMENSION")
        }
        for script_name in ("ADD_DIMENSION", "ADD_FACT"):
            script = scripts[script_name]
            self.assertIn("uncovered_er.COVERAGE_PREDICATE IS NULL", script)
            self.assertIn("er.REPRESENTATION_ROLE = 'PRIMARY' OR", script)
            self.assertIn("er.REPRESENTATION_ID, :expression", script)

        replace_dimension = scripts["ADD_OR_REPLACE_DIMENSION"]
        self.assertIn("existing_binding.ATTRIBUTE_TYPE = 'DIMENSION'", replace_dimension)
        self.assertIn("er.REPRESENTATION_ROLE <> 'PRIMARY'", replace_dimension)

        semantic_source = (
            ROOT / "lua/semantic_layer/admin/semantic_definition.lua"
        ).read_text(encoding="utf-8")
        self.assertIn("existing_binding.ATTRIBUTE_TYPE = 'FACT'", semantic_source)
        self.assertIn("uncovered_er.COVERAGE_PREDICATE IS NULL", semantic_source)

    def test_heterogeneous_attributes_can_be_created_with_all_bindings_atomically(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        scripts = {
            sql.split("SEMANTIC_ADMIN.", 1)[1].split("(", 1)[0]: sql
            for sql in statements
            if sql.startswith("CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.")
        }
        runtime = scripts["ATTRIBUTE_WITH_BINDINGS"]
        self.assertIn("semantic_definition.decode_json", runtime)
        self.assertIn('string.sub(trim(BINDINGS_JSON), 1, 1) ~= "["', runtime)
        self.assertIn("no binding supplied for active alternate", runtime)
        # VP-002: a primary entry may set the binding's *role*, so the caller
        # can say "the placeholder EXPRESSION forced on me is the fallback".
        # It may not set the expression -- that still has exactly one home.
        self.assertIn("the primary binding takes its expression from", runtime)
        self.assertIn("binding_role = primary_role", runtime)
        self.assertIn("binding_priority = primary_priority", runtime)
        self.assertNotIn("'PREFER', 1, TRUE, 'ACTIVE'", runtime)
        self.assertIn("BINDINGS_JSON must not bind an F3 partition", runtime)
        self.assertIn("coverage_predicate", runtime)
        self.assertIn("for _, partition in ipairs(partitions) do", runtime)
        self.assertIn("source_expression", runtime)
        self.assertIn("binding_role", runtime)
        self.assertIn("binding_priority", runtime)
        self.assertIn("FALSE, 'ACTIVE'", runtime)
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", runtime)
        self.assertIn("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS", runtime)
        self.assertLess(
            runtime.index(
                "for _, item in ipairs(prepared) do",
                runtime.index("INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS"),
            ),
            runtime.index("local validation_rows"),
        )
        self.assertGreater(
            runtime.count("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL"), 1
        )

        dimension = scripts["ADD_DIMENSION_WITH_BINDINGS"]
        fact = scripts["ADD_FACT_WITH_BINDINGS"]
        self.assertIn("'DIMENSION'", dimension)
        self.assertIn("'FACT'", fact)
        self.assertIn("SEMANTIC_ADMIN.ATTRIBUTE_WITH_BINDINGS", dimension)
        self.assertIn("SEMANTIC_ADMIN.ATTRIBUTE_WITH_BINDINGS", fact)
        for wrapper in (dimension, fact):
            self.assertEqual(wrapper.count("local rows = query"), 1)
            self.assertLess(
                wrapper.index("SEMANTIC_ADMIN.ATTRIBUTE_WITH_BINDINGS"),
                wrapper.index("local rows = query"),
            )
            self.assertIn("COUNT(ab.ATTRIBUTE_BINDING_ID)", wrapper)
            self.assertIn("result[#result + 1]", wrapper)
            self.assertIn("exit(result, [[", wrapper)

    def test_relationship_mappings_accept_quoted_physical_columns(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        add_mapping = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING(")
        )
        self.assertIn("validate_physical_column", add_mapping)
        self.assertIn('string.find(value, "%c")', add_mapping)
        self.assertNotIn('^[A-Za-z_][A-Za-z0-9_]*$', add_mapping)

    def test_published_structural_mutations_are_prospective_and_reversible(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        scripts = {
            name: next(
                sql
                for sql in statements
                if f"CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.{name}(" in sql
            )
            for name in (
                "ADD_ENTITY_REPRESENTATION",
                "ADD_UNIQUE_KEY",
                "ADD_UNIQUE_KEY_COLUMN",
                "REMOVE_ATTRIBUTE_BINDING",
                "REMOVE_UNIQUE_KEY_COLUMN",
                "REMOVE_UNIQUE_KEY",
            )
        }
        for name, script in scripts.items():
            status_guard = (
                'tostring(model.status) == "PUBLISHED"'
                if name in ("ADD_UNIQUE_KEY", "ADD_UNIQUE_KEY_COLUMN")
                else 'tostring(model_status) == "PUBLISHED"'
            )
            self.assertIn(status_guard, script)
            self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", script)
            self.assertIn("SEMANTIC_ADMIN_094", script)
        self.assertIn(
            "DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS",
            scripts["ADD_ENTITY_REPRESENTATION"],
        )
        self.assertIn(
            "SET COLUMN_NAME = :column_name, EXPRESSION = :expression",
            scripts["ADD_UNIQUE_KEY_COLUMN"],
        )
        self.assertIn(
            "SET STATUS = 'ACTIVE'",
            scripts["REMOVE_ATTRIBUTE_BINDING"],
        )
        self.assertIn(
            "INSERT INTO SYS_SEMANTIC.UNIQUE_KEY_COLUMNS",
            scripts["REMOVE_UNIQUE_KEY_COLUMN"],
        )
        self.assertIn(
            "remove its unique-key columns first",
            scripts["REMOVE_UNIQUE_KEY"],
        )

        key_batch = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_UNIQUE_KEY_WITH_COLUMNS(")
        )
        self.assertIn("semantic_definition.decode_json", key_batch)
        self.assertIn("key-column ordinals must be contiguous from 1", key_batch)
        self.assertLess(
            key_batch.index("INSERT INTO SYS_SEMANTIC.UNIQUE_KEY_COLUMNS"),
            key_batch.index("candidate_validation"),
        )
        complete_key_remove = next(
            sql
            for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_WITH_COLUMNS(")
        )
        self.assertIn("SET STATUS = 'INACTIVE'", complete_key_remove)
        self.assertIn("published complete-key removal rejected", complete_key_remove)
        self.assertLess(
            complete_key_remove.index("candidate_validation"),
            complete_key_remove.index(
                "DELETE FROM SYS_SEMANTIC.UNIQUE_KEY_COLUMNS",
                complete_key_remove.index("candidate_validation"),
            ),
        )

    def test_stale_mutators_recertify_and_managed_lifecycles_are_exercised(self):
        statements = INSTALL.split_exasol_sql(
            (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
                encoding="utf-8"
            )
        )
        scripts = {
            sql.split("SEMANTIC_ADMIN.", 1)[1].split("(", 1)[0]: sql
            for sql in statements
            if sql.startswith("CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.")
        }
        self.assertIn("RECERTIFY_MODEL_IF_PUBLISHED", scripts)
        for name, script in scripts.items():
            if "STATUS = 'STALE'" not in script:
                continue
            self.assertTrue(
                "VALIDATE_MODEL" in script
                or "RECERTIFY_MODEL_IF_PUBLISHED" in script,
                f"{name} can stale a published model without recertifying",
            )

        inverse_overrides = {
            "ADD_ENTITY_REPRESENTATION_WITH_COVERAGE": "REMOVE_ENTITY_REPRESENTATION",
            "ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY": "REMOVE_ENTITY_REPRESENTATION",
            "ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING": "REMOVE_ENTITY_REPRESENTATION",
            # The collapsed form registers one representation whatever it declares
            # alongside it, so removing that representation undoes all of it.
            "ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS": "REMOVE_ENTITY_REPRESENTATION",
            "ADD_SEMANTIC_IDENTITY_WITH_BINDINGS": "REMOVE_SEMANTIC_IDENTITY",
            "ADD_OR_REPLACE_DIMENSION": "REMOVE_DIMENSION",
            "ADD_DIMENSION_WITH_BINDINGS": "REMOVE_DIMENSION",
            # Metrics use governed Semantic SQL rather than a standalone admin script.
            "ADD_METRIC": "DDL:DROP METRIC",
        }
        intentionally_permanent = {
            "ADD_CUSTOM_EXTENSION":
                "Extension removal is intentionally deferred until extension ownership semantics exist.",
            "ADD_ENTITY":
                "Entities own dependent model structure and are removed only with DROP_MODEL.",
            "ADD_FACT":
                "Fact removal is intentionally deferred until dependent metric rewrites are transactional.",
            "ADD_FACT_WITH_BINDINGS":
                "Fact removal is intentionally deferred until dependent metric rewrites are transactional.",
            "ADD_MATERIALIZATION_COLUMN":
                "Column removal is unsupported; deactivate the owning materialization instead.",
            "ADD_SEMANTIC_OBJECT":
                "Semantic objects are part of the published contract and currently require model rebuild.",
            "ADD_SYNONYM":
                "Synonym removal is intentionally deferred until ambiguity revalidation is transactional.",
        }
        add_scripts = {name for name in scripts if name.startswith("ADD_")}
        self.assertLessEqual(set(intentionally_permanent), add_scripts)
        self.assertTrue(all(reason.strip() for reason in intentionally_permanent.values()))
        for add_name in intentionally_permanent:
            self.assertNotIn(
                f"REMOVE_{add_name.removeprefix('ADD_')}",
                scripts,
                f"remove stale permanence exception for {add_name}",
            )
            self.assertNotIn(
                add_name,
                inverse_overrides,
                f"remove stale permanence exception for {add_name}",
            )
        semantic_definition = (
            ROOT / "lua/semantic_layer/admin/semantic_definition.lua"
        ).read_text(encoding="utf-8")
        for add_name in sorted(add_scripts):
            if add_name in intentionally_permanent:
                continue
            inverse = inverse_overrides.get(
                add_name, f"REMOVE_{add_name.removeprefix('ADD_')}"
            )
            if inverse == "DDL:DROP METRIC":
                self.assertIn('find_sequence(tokens, {"DROP", "METRIC"}', semantic_definition)
            else:
                self.assertIn(
                    inverse,
                    scripts,
                    f"{add_name} needs {inverse} or an explicit permanence reason",
                )

        published_compound_reachability = {
            "ADD_ENTITY_REPRESENTATION_WITH_COVERAGE":
                "tools/verify_published_multistep_declarations.py",
            "ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY":
                "tools/verify_fusion_governance.py",
            "ADD_UNIQUE_KEY_WITH_COLUMNS":
                "tools/verify_published_multistep_declarations.py",
            "ADD_SEMANTIC_IDENTITY_WITH_BINDINGS":
                "tools/verify_published_identity_setup.py",
            "ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING":
                "tools/verify_representation_with_identity.py",
            "ADD_ENTITY_REPRESENTATION_WITH_DECLARATIONS":
                "tools/verify_identity_binding_diagnostic.py",
            "ADD_DIMENSION_WITH_BINDINGS":
                "tools/verify_attribute_with_bindings.py",
            "ADD_FACT_WITH_BINDINGS":
                "tools/verify_attribute_with_bindings.py",
        }
        compound_scripts = {name for name in add_scripts if "_WITH_" in name}
        self.assertEqual(compound_scripts, set(published_compound_reachability))
        for operation, relative_path in published_compound_reachability.items():
            verifier = (ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn(f"SEMANTIC_ADMIN.{operation}", verifier)
            self.assertIn("SEMANTIC_ADMIN.PUBLISH_MODEL", verifier)

        relationship_verifier = (
            ROOT / "tools/verify_relationship_types_and_removal.py"
        ).read_text(encoding="utf-8")
        self.assertIn("SEMANTIC_ADMIN.ADD_RELATIONSHIP", relationship_verifier)
        self.assertIn("SEMANTIC_ADMIN.PUBLISH_MODEL", relationship_verifier)

        add_relationship = scripts["ADD_RELATIONSHIP"]
        self.assertIn("published relationship change rejected", add_relationship)
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", add_relationship)
        remove_mapping = scripts["REMOVE_RELATIONSHIP_KEY_MAPPING"]
        self.assertIn("published relationship-mapping removal rejected", remove_mapping)
        remove_relationship = scripts["REMOVE_RELATIONSHIP"]
        self.assertIn("cannot remove a relationship with active key mappings", remove_relationship)
        self.assertIn("published relationship removal rejected", remove_relationship)

    def test_f4_authority_and_reconciliation_surfaces_are_installable(self):
        statements = []
        for path in INSTALL.INSTALL_FILES:
            statements.extend(INSTALL.split_exasol_sql(path.read_text(encoding="utf-8")))
        expected_fragments = {
            "SYS_SEMANTIC.REPRESENTATION_AUTHORITIES",
            "SYS_SEMANTIC.ATTRIBUTE_FUSION_POLICIES",
            "SEMANTIC_CATALOG.REPRESENTATION_AUTHORITIES",
            "SEMANTIC_CATALOG.ATTRIBUTE_FUSION_POLICIES",
            "SEMANTIC_ADMIN.SET_REPRESENTATION_AUTHORITY",
            "SEMANTIC_ADMIN.SET_ATTRIBUTE_FUSION_POLICY",
        }
        for fragment in expected_fragments:
            self.assertTrue(any(fragment in sql for sql in statements), fragment)

    def test_f5_identity_graph_surfaces_are_installable(self):
        statements = []
        for path in INSTALL.INSTALL_FILES:
            statements.extend(INSTALL.split_exasol_sql(path.read_text(encoding="utf-8")))
        expected_fragments = {
            "SYS_SEMANTIC.SEMANTIC_IDENTITIES",
            "SYS_SEMANTIC.IDENTITY_BINDINGS",
            "SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS",
            "SEMANTIC_CATALOG.SEMANTIC_IDENTITIES",
            "SEMANTIC_CATALOG.IDENTITY_BINDINGS",
            "SEMANTIC_CATALOG.IDENTITY_MAPPING_RELATIONS",
            "SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY",
            "SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY_WITH_BINDINGS",
            "SEMANTIC_ADMIN.ADD_IDENTITY_BINDING",
            "SEMANTIC_ADMIN.ADD_IDENTITY_MAPPING_RELATION",
            "SEMANTIC_ADMIN.REMOVE_IDENTITY_MAPPING_RELATION",
            "SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING",
            "SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY",
        }
        for fragment in expected_fragments:
            self.assertTrue(any(fragment in sql for sql in statements), fragment)

        # Match the script definition itself: SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS
        # publishes every script's call template, so a bare substring search now
        # finds that view first.
        add_identity = next(
            sql for sql in statements
            if sql.startswith("CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY(")
        )
        self.assertIn("entity already has an active semantic identity", add_identity)
        self.assertIn('tostring(model_status) == "PUBLISHED"', add_identity)
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", add_identity)
        self.assertIn("published semantic-identity change rejected", add_identity)
        add_complete_identity = next(
            sql for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY_WITH_BINDINGS(")
        )
        self.assertIn("BINDINGS_JSON must be a non-empty JSON array", add_complete_identity)
        self.assertIn("no binding supplied for active representation", add_complete_identity)
        self.assertIn("published identity-with-bindings candidate rejected", add_complete_identity)
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS", add_complete_identity)
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_BINDINGS", add_complete_identity)
        self.assertIn("DELETE FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES", add_complete_identity)
        add_binding = next(
            sql for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_IDENTITY_BINDING(")
        )
        self.assertIn('if binding_kind == "DIRECT"', add_binding)
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS", add_binding)

        add_representation_binding = next(
            sql for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING(")
        )
        self.assertIn("MAPPED binding requires MAPPING_JSON", add_representation_binding)
        self.assertIn("published representation-with-identity candidate rejected", add_representation_binding)
        self.assertIn("INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS", add_representation_binding)
        self.assertIn("table.concat(validation_errors", add_representation_binding)
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS", add_representation_binding)
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_BINDINGS", add_representation_binding)
        self.assertIn("DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS", add_representation_binding)
        self.assertIn("DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS", add_representation_binding)
        self.assertIn("generated_binding_issues", add_representation_binding)
        self.assertIn("GENERATED_BINDING_ISSUE_COUNT", add_representation_binding)
        self.assertLess(
            add_representation_binding.index("candidate_validation"),
            add_representation_binding.index('if tostring(model_status) == "PUBLISHED"'),
        )

        remove_mapping = next(
            sql for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_MAPPING_RELATION(")
        )
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS", remove_mapping)
        remove_binding = next(
            sql for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING(")
        )
        self.assertIn("cannot remove an identity binding with an active mapping relation", remove_binding)
        remove_identity = next(
            sql for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY(")
        )
        self.assertIn("cannot remove a semantic identity with active bindings", remove_identity)
        remove_representation = next(
            sql for sql in statements
            if sql.startswith(
                "CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION(")
        )
        self.assertIn("cannot remove a representation with active identity bindings", remove_representation)
        self.assertIn("SET COVERAGE_PREDICATE = NULL", remove_representation)
        self.assertIn("published representation removal rejected", remove_representation)
        self.assertLess(
            remove_representation.index("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL"),
            remove_representation.index("DELETE FROM SYS_SEMANTIC.ENTITY_REPRESENTATIONS"),
        )

    def test_reset_discovers_non_example_published_schemas(self):
        statements = INSTALL.reset_statements(Connection())
        self.assertEqual(
            'DROP SCHEMA IF EXISTS "SEMANTIC_ECOMMERCE" CASCADE',
            statements[0],
        )
        self.assertEqual(1, sum("SEMANTIC_SALES" in sql for sql in statements))

    def test_reset_without_catalog_uses_fixed_managed_schemas(self):
        statements = INSTALL.reset_statements(Connection(catalog_exists=False))
        self.assertEqual(INSTALL.RESET_STATEMENTS, statements)

    def test_reset_recovers_from_broken_catalog(self):
        statements = INSTALL.reset_statements(Connection(catalog_broken=True))
        self.assertEqual(INSTALL.RESET_STATEMENTS, statements)

    def test_reset_drops_a_published_schema_the_catalog_has_forgotten(self):
        """An orphan is a fully typed, BI-discoverable surface with no model.

        Discovering published schemas only from the catalog meant no future
        reset could ever remove one, so it outlived every reinstall.
        """
        statements = INSTALL.reset_statements(
            Connection(catalog_exists=False, orphans=["SEMANTIC_GHOST"]))
        self.assertEqual('DROP SCHEMA IF EXISTS "SEMANTIC_GHOST" CASCADE', statements[0])

    def test_reset_finds_an_orphan_even_when_the_catalog_is_broken(self):
        statements = INSTALL.reset_statements(
            Connection(catalog_broken=True, orphans=["SEMANTIC_GHOST"]))
        self.assertEqual('DROP SCHEMA IF EXISTS "SEMANTIC_GHOST" CASCADE', statements[0])

    def test_reset_refuses_when_nothing_can_be_enumerated(self):
        """An unreadable catalog is when orphans are made, not a reason to guess.

        With neither the catalog nor the table scan available, dropping only the
        fixed managed schemas would manufacture exactly the orphan this test
        suite is about, so the reset refuses instead.
        """
        class Blind(Connection):
            def execute(self, sql):
                raise RuntimeError("no metadata access")

        with self.assertRaises(RuntimeError):
            INSTALL.reset_statements(Blind(catalog_broken=True))

    def test_identifier_quoting(self):
        self.assertEqual('"A""B"', INSTALL.quote_ident('A"B'))


PACKAGER_SPEC = importlib.util.spec_from_file_location(
    "package_lua_scripts", ROOT / "tools/package_lua_scripts.py")
PACKAGER = importlib.util.module_from_spec(PACKAGER_SPEC)  # type: ignore[arg-type]
PACKAGER_SPEC.loader.exec_module(PACKAGER)  # type: ignore[union-attr]


class AdminScriptSignatureCoverageTest(unittest.TestCase):
    """Every callable SEMANTIC_ADMIN script must publish a signature.

    `CALL_ADMIN_JSON` resolves script names from
    `SEMANTIC_CATALOG.ADMIN_SCRIPT_PARAMETERS` and nothing else, so a script
    missing from that view is unreachable through the named API — and the failure
    is a clean `SEMANTIC_ADMIN_100: unknown admin script`, which reads as though
    the script does not exist.

    That is how BUG-G02 hid: the signature pattern required a `RETURNS` clause,
    and the nine mutators that "complete without returning rows" are declared
    `) AS`. The omission was systematic rather than random — every script it hit
    was one that returns no rows — so `CALL_ADMIN_JSON` could not perform a single
    step of the documented bootstrap (`CREATE_MODEL`, `ADD_ENTITY`,
    `ADD_SEMANTIC_OBJECT`, `ADD_RELATIONSHIP`, ...) while looking healthy on
    every script that did return a table.
    """

    def setUp(self) -> None:
        self.declared: set[str] = set()
        self.published: set[str] = set()
        for path in sorted((ROOT / "sql/install").glob("*.sql"),
                           key=lambda candidate: candidate.name):
            if path.name.startswith("002_"):
                continue
            text = path.read_text(encoding="utf-8")
            self.declared.update(PACKAGER.ANY_SCRIPT_DECLARATION.findall(text))
            self.published.update(
                match.group(1) for match in PACKAGER.SCRIPT_SIGNATURE.finditer(text))

    def test_every_declared_script_is_published_or_explicitly_excluded(self):
        unaccounted = self.declared - self.published - PACKAGER.NON_CALLABLE_SCRIPTS
        self.assertEqual(
            set(), unaccounted,
            "declared but unreachable through CALL_ADMIN_JSON; add to "
            "NON_CALLABLE_SCRIPTS if it is a runtime library")

    def test_exclusions_are_all_real_scripts(self):
        """A stale exclusion would silently hide a future script of that name."""
        self.assertEqual(
            set(), PACKAGER.NON_CALLABLE_SCRIPTS - self.declared,
            "NON_CALLABLE_SCRIPTS lists scripts that no longer exist")

    def test_row_returning_and_silent_mutators_are_both_published(self):
        """The distinction that used to decide visibility must not matter."""
        # Declared `) RETURNS TABLE AS`.
        for script in ("ADD_FACT", "ADD_DIMENSION", "ADD_METRIC", "VALIDATE_MODEL"):
            self.assertIn(script, self.published, script)
        # Declared `) AS` -- the nine BUG-G02 omitted.
        for script in ("CREATE_MODEL", "ADD_ENTITY", "ADD_SEMANTIC_OBJECT",
                       "ADD_RELATIONSHIP", "ADD_RELATIONSHIP_KEY_MAPPING",
                       "CREATE_SEMANTIC_OBJECT", "REGISTER_MATERIALIZATION",
                       "SET_MATERIALIZATION_STATUS", "ADD_MATERIALIZATION_COLUMN"):
            self.assertIn(script, self.published, script)

    def test_runtime_libraries_are_not_published(self):
        """Publishing one would advertise an uncallable script as an API."""
        block = PACKAGER.admin_script_parameters_block()
        for library in PACKAGER.NON_CALLABLE_SCRIPTS:
            self.assertNotIn(f"  ('{library}',", block, library)

    def test_generated_block_carries_the_bootstrap_arity(self):
        """The signature is only useful if the parameter list is right."""
        block = PACKAGER.admin_script_parameters_block()
        # CREATE_MODEL(MODEL_NAME, PUBLISHED_SCHEMA, DESCRIPTION, OWNER_ROLE)
        self.assertIn("('CREATE_MODEL', 4, 1, 'MODEL_NAME'", block)
        self.assertIn("('ADD_RELATIONSHIP', 8, 6, 'CARDINALITY'", block)

    def test_the_block_generates_without_tripping_its_own_assertion(self):
        """The packaging guard must pass on the tree as committed."""
        self.assertTrue(
            PACKAGER.admin_script_parameters_block().startswith(
                PACKAGER.SCRIPT_PARAMETERS_BEGIN))


class NullNormalisationTest(unittest.TestCase):
    """An omitted parameter must not be normalised into a Lua address.

    `CALL_ADMIN_JSON` renders an absent key as SQL NULL, and SQL NULL reaches an
    Exasol Lua script as *userdata* rather than nil. Userdata is truthy, so the
    idiom `tostring(value or "")` yields "userdata: 0x..." -- a non-empty string
    that sails past the script's own `missing()` check and then gets reported to
    the caller as if it were the value the caller supplied.

    The idiom shipped in 19 hand-written scripts. Most were harmless because a
    different check fired first, but `REMOVE_RELATIONSHIP`, `REMOVE_UNIQUE_KEY`,
    `REMOVE_UNIQUE_KEY_WITH_COLUMNS` and `REMOVE_ATTRIBUTE_BINDING` answered an
    omitted name with "... not found: userdata: 0xffff..." instead of the
    SEMANTIC_ADMIN_001 each had already written the check for, and
    `RECERTIFY_MODEL_IF_PUBLISHED` reported "model not found" for the same
    reason. `DESCRIBE_SEMANTIC_METRIC` and `EXPLAIN_SEMANTIC_METRIC` were worse
    still: they concatenated the userdata and crashed.

    `tools/verify_named_admin_api.py` probes this live against every
    model-scoped script; this is the cheap static half, because the idiom is
    short enough to be retyped from memory.
    """

    # `tostring(X or "")` for any bare name X. Comments are stripped first, so
    # the explanations of why this is wrong do not count as instances of it.
    BAD_IDIOM = re.compile(r'tostring\(\s*[A-Za-z_][A-Za-z0-9_.]*\s+or\s+""\s*\)')

    def setUp(self) -> None:
        self.hand_written: dict[str, list[tuple[int, str]]] = {}
        for path in sorted((ROOT / "sql/install").glob("*.sql")):
            # Generated blocks come from `lua/`, which the Lua suite covers and
            # which does not receive Exasol script parameters.
            head, _, _ = path.read_text(encoding="utf-8").partition("-- BEGIN GENERATED")
            self.hand_written[path.name] = [
                (number, line) for number, line in enumerate(head.split("\n"), 1)
                if not line.lstrip().startswith("--")]

    def test_no_hand_written_script_normalises_null_by_truthiness(self):
        offenders = [f"{name}:{number}: {line.strip()}"
                     for name, lines in self.hand_written.items()
                     for number, line in lines if self.BAD_IDIOM.search(line)]
        self.assertEqual(
            [], offenders,
            "`X or \"\"` treats SQL NULL as a value, because NULL is truthy "
            "userdata; guard on `X == nil or X == null` first")

    def test_the_idiom_is_what_the_guard_thinks_it_is(self):
        """The regex must match the shape that shipped, and not its explanation."""
        self.assertRegex('local text = tostring(value or "")', self.BAD_IDIOM)
        self.assertRegex('tostring( MODEL_NAME  or  "" )', self.BAD_IDIOM)
        self.assertNotRegex('local text = tostring(value)', self.BAD_IDIOM)
        self.assertNotRegex('missing(value) and "" or tostring(value)', self.BAD_IDIOM)

    def test_the_replacement_names_null_where_it_is_used(self):
        """Avoiding the idiom is not enough; the guard has to test for `null`."""
        for name in ("003_create_semantic_admin_scripts.sql",
                     "005_create_semantic_surface_helpers.sql"):
            text = "\n".join(line for _, line in self.hand_written[name])
            self.assertIn('if value == nil or value == null then return "" end', text,
                          f"{name} has no null-guarded normaliser left")


class PackagerOutputFormattingTest(unittest.TestCase):
    """The installer realigns the packager's per-file lines.

    This reformatting was dead for as long as it existed: `mod.main()` -- the
    only thing that prints -- sat outside the `redirect_stdout` block, so the
    captured buffer was always empty. Nothing noticed, because nothing could
    test it, and the packager's own unindented lines appeared among the
    installer's aligned ones. It also parsed the wrong end of the line.
    """

    def test_a_status_line_puts_the_file_name_first(self):
        formatted = INSTALL.format_packager_line(
            "unchanged sql/install/003_create_semantic_admin_scripts.sql")
        self.assertIn("003_create_semantic_admin_scripts.sql", formatted)
        self.assertTrue(formatted.startswith("      "))
        # The status is the first word of the input and must not become the label.
        self.assertLess(formatted.index("003_create"), formatted.index("unchanged"))

    def test_both_statuses_are_recognised(self):
        for status in INSTALL.PACKAGER_STATUSES:
            formatted = INSTALL.format_packager_line(f"{status} sql/install/x.sql")
            self.assertIn("x.sql", formatted)
            self.assertIn(status, formatted)

    def test_an_advisory_passes_through_untouched(self):
        """The ceiling advisory carries its own indent and has no status word."""
        advisory = "      COMPILER_RUNTIME: 200/200 main-chunk locals, 0 left"
        self.assertEqual(advisory, INSTALL.format_packager_line(advisory))

    def test_an_advisory_is_not_mangled_by_path_parsing(self):
        """'200/200' would become a Path component if the line were parsed."""
        formatted = INSTALL.format_packager_line(
            "      COMPILER_RUNTIME: 200/200 main-chunk locals, 0 left")
        self.assertIn("200/200", formatted)

    def test_a_bare_line_is_left_alone(self):
        self.assertEqual("something", INSTALL.format_packager_line("something"))


class MainChunkLocalCeilingTest(unittest.TestCase):
    """Exasol allows 200 locals per function; a runtime script is one chunk.

    A generated runtime concatenates several source files into a single
    `CREATE ... AS` body, so the ceiling applies to the sum of their top-level
    locals. Crossing it fails at install time citing a line number in a generated
    artefact and no source file at all, which is a poor way to learn about it.
    COMPILER_RUNTIME sat at exactly 200 during the BUG-G03 fix and one added
    helper broke the install.
    """

    def test_counts_names_not_statements(self):
        body = "local a, b, c = 1, 2, 3\nlocal d\n"
        self.assertEqual(4, PACKAGER.main_chunk_local_count(body))

    def test_counts_local_functions(self):
        body = "local function one() end\nlocal function two() end\n"
        self.assertEqual(2, PACKAGER.main_chunk_local_count(body))

    def test_ignores_locals_inside_functions(self):
        """Only the main chunk has the budget; nested scopes have their own."""
        body = (
            "local function outer()\n"
            "    local inner_a = 1\n"
            "    local inner_b, inner_c = 2, 3\n"
            "    for _, item in ipairs({}) do local deep = item end\n"
            "end\n"
        )
        self.assertEqual(1, PACKAGER.main_chunk_local_count(body))

    def test_ignores_words_merely_starting_with_local(self):
        self.assertEqual(0, PACKAGER.main_chunk_local_count("locale = 1\n"))

    def test_refuses_a_body_over_the_ceiling(self):
        over = "".join(f"local n{index} = {index}\n"
                       for index in range(PACKAGER.MAIN_CHUNK_LOCAL_LIMIT + 1))
        text = f"CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.PROBE_RUNTIME AS\n{over}/\n"
        with self.assertRaises(SystemExit) as raised:
            PACKAGER.check_main_chunk_locals(Path("probe.sql"), text)
        message = str(raised.exception)
        # The message has to name the script, the numbers, and a way out.
        self.assertIn("PROBE_RUNTIME", message)
        self.assertIn(str(PACKAGER.MAIN_CHUNK_LOCAL_LIMIT + 1), message)
        self.assertIn("shared", message)

    def test_accepts_a_body_exactly_at_the_ceiling(self):
        """200 installs; 201 does not. The boundary is load-bearing."""
        exact = "".join(f"local n{index} = {index}\n"
                        for index in range(PACKAGER.MAIN_CHUNK_LOCAL_LIMIT))
        text = f"CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.PROBE_RUNTIME AS\n{exact}/\n"
        PACKAGER.check_main_chunk_locals(Path("probe.sql"), text)

    def test_the_committed_tree_installs(self):
        """Every generated script in the tree is within the ceiling."""
        for name in ("sql/install/003_create_semantic_admin_scripts.sql",
                     "sql/install/006_create_semantic_agent_views.sql"):
            path = ROOT / name
            PACKAGER.check_main_chunk_locals(path, path.read_text(encoding="utf-8"))

    def test_the_compiler_runtime_is_measured_at_all(self):
        """Guard the parser: a regex that stops matching would pass silently."""
        text = (ROOT / "sql/install/003_create_semantic_admin_scripts.sql").read_text(
            encoding="utf-8")
        counts = {match.group(1): PACKAGER.main_chunk_local_count(match.group(2))
                  for match in PACKAGER.SCRIPT_BODY.finditer(text)}
        self.assertIn("COMPILER_RUNTIME", counts)
        # It has historically sat at the ceiling; assert it is being counted in a
        # plausible range rather than silently returning zero.
        self.assertGreater(counts["COMPILER_RUNTIME"], 100)
        self.assertLessEqual(counts["COMPILER_RUNTIME"],
                             PACKAGER.MAIN_CHUNK_LOCAL_LIMIT)


class RenamedTableMigrationTest(unittest.TestCase):
    """An existing catalog survives a table rename with its rows and its ids.

    `SYS_SEMANTIC` has no schema-version column and every table is created with
    `CREATE TABLE IF NOT EXISTS`, so a rename with no migration would leave an
    upgraded deployment holding its rows in the old table and a new empty one
    beside it -- silently, because both would exist and only one would be read.

    `RENAME TABLE` rather than create-and-copy, because it carries the identity
    counter too: inserting explicit ids into an IDENTITY column does not advance
    the generator (verified against Exasol), so a copy migration hands out ids
    that collide with the ones it just restored.
    """

    class Catalog:
        def __init__(self, present):
            self.present = set(present)
            self.sql = []

        def execute(self, sql):
            self.sql.append(sql)
            if "EXA_ALL_TABLES" in sql:
                name = sql.split("TABLE_NAME = '", 1)[1].split("'", 1)[0]
                return Result([(1,)] if name in self.present else [])
            return Result([])

    def test_a_fresh_install_migrates_nothing(self):
        catalog = self.Catalog(present=[])
        self.assertEqual([], INSTALL.migrate_renamed_tables(catalog))
        self.assertNotIn("RENAME", " ".join(catalog.sql))

    def test_an_existing_catalog_is_renamed_in_place(self):
        catalog = self.Catalog(present=["AGENT_SUGGESTIONS",
                                        "AGENT_SUGGESTION_REVIEWS",
                                        "AGENT_SUGGESTION_TARGETS"])
        moved = INSTALL.migrate_renamed_tables(catalog)
        self.assertEqual(
            ["AGENT_SUGGESTIONS -> MODEL_EVOLUTION_SUGGESTIONS",
             "AGENT_SUGGESTION_REVIEWS -> MODEL_EVOLUTION_REVIEWS",
             "AGENT_SUGGESTION_TARGETS -> MODEL_EVOLUTION_TARGETS"], moved)
        renames = [s for s in catalog.sql if s.startswith("RENAME TABLE")]
        self.assertEqual(3, len(renames))
        # Renamed, never recreated-and-copied: the rows and the identity counter
        # travel with the table.
        self.assertNotIn("INSERT", " ".join(catalog.sql))

    def test_reinstalling_over_a_migrated_catalog_is_a_no_op(self):
        catalog = self.Catalog(present=["MODEL_EVOLUTION_SUGGESTIONS",
                                        "MODEL_EVOLUTION_REVIEWS",
                                        "MODEL_EVOLUTION_TARGETS"])
        self.assertEqual([], INSTALL.migrate_renamed_tables(catalog))
        self.assertNotIn("RENAME", " ".join(catalog.sql))
        self.assertNotIn("DROP", " ".join(catalog.sql))

    def test_a_run_interrupted_between_rename_and_drop_resolves_forward(self):
        """Both names present: the new one is authoritative, so retire the old."""
        catalog = self.Catalog(present=["AGENT_SUGGESTIONS",
                                        "MODEL_EVOLUTION_SUGGESTIONS"])
        moved = INSTALL.migrate_renamed_tables(catalog)
        self.assertEqual(
            ["AGENT_SUGGESTIONS (dropped; MODEL_EVOLUTION_SUGGESTIONS already present)"],
            moved)
        self.assertIn("DROP TABLE IF EXISTS SYS_SEMANTIC.AGENT_SUGGESTIONS CASCADE",
                      catalog.sql)
        self.assertNotIn("RENAME", " ".join(catalog.sql))

    def test_the_rename_map_matches_what_the_catalog_declares(self):
        """A pair left here after the DDL moved on would rename into nothing."""
        ddl = (ROOT / "sql/install/001_create_semantic_catalog.sql").read_text(
            encoding="utf-8")
        for old, new in INSTALL.RENAMED_TABLES:
            self.assertIn(f"CREATE TABLE IF NOT EXISTS SYS_SEMANTIC.{new} (", ddl,
                          f"{new} is a rename target but no longer declared")
            self.assertNotIn(f"SYS_SEMANTIC.{old} (", ddl,
                             f"{old} is both a rename source and still declared")


if __name__ == "__main__":
    unittest.main()
