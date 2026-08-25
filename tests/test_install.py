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
            "SYS_SEMANTIC.AGENT_SUGGESTION_REVIEWS",
            "SYS_SEMANTIC.AGENT_SUGGESTION_TARGETS",
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
        self.assertIn("BINDINGS_JSON must not bind the primary representation", runtime)
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
                "tools/verify_bug27_published_multistep_declarations.py",
            "ADD_ENTITY_REPRESENTATION_WITH_AUTHORITY":
                "tools/verify_fusion_governance.py",
            "ADD_UNIQUE_KEY_WITH_COLUMNS":
                "tools/verify_bug27_published_multistep_declarations.py",
            "ADD_SEMANTIC_IDENTITY_WITH_BINDINGS":
                "tools/verify_bug30_published_identity_setup.py",
            "ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING":
                "tools/verify_bug31_representation_with_identity.py",
            "ADD_DIMENSION_WITH_BINDINGS":
                "tools/verify_bug37_attribute_with_bindings.py",
            "ADD_FACT_WITH_BINDINGS":
                "tools/verify_bug37_attribute_with_bindings.py",
        }
        compound_scripts = {name for name in add_scripts if "_WITH_" in name}
        self.assertEqual(compound_scripts, set(published_compound_reachability))
        for operation, relative_path in published_compound_reachability.items():
            verifier = (ROOT / relative_path).read_text(encoding="utf-8")
            self.assertIn(f"SEMANTIC_ADMIN.{operation}", verifier)
            self.assertIn("SEMANTIC_ADMIN.PUBLISH_MODEL", verifier)

        relationship_verifier = (
            ROOT / "tools/verify_bug32_relationship_types_and_removal.py"
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


if __name__ == "__main__":
    unittest.main()
