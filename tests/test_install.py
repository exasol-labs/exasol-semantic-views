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
    def __init__(self, catalog_exists=True, catalog_broken=False):
        self.catalog_exists = catalog_exists
        self.catalog_broken = catalog_broken
        self.sql = []

    def execute(self, sql):
        self.sql.append(sql)
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
            if "SEMANTIC_ADMIN.ADD_ATTRIBUTE_BINDING" in sql
        )
        self.assertLess(
            add_binding.index("baseline_validation_rows"),
            add_binding.index("INSERT INTO SYS_SEMANTIC.ATTRIBUTE_BINDINGS"),
        )
        self.assertIn("if not baseline_errors[signature]", add_binding)

        replace_binding = next(
            sql
            for sql in statements
            if "SEMANTIC_ADMIN.REPLACE_ATTRIBUTE_BINDING" in sql
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
            if "SEMANTIC_ADMIN.SET_PRIMARY_REPRESENTATION" in sql
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
            if "SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE" in sql
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
            if "SEMANTIC_ADMIN.SET_REPRESENTATION_COVERAGE_BATCH" in sql
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
            if "SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_COVERAGE" in sql
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
            if "SEMANTIC_ADMIN.ADD_RELATIONSHIP_KEY_MAPPING" in sql
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
            if "SEMANTIC_ADMIN.ADD_UNIQUE_KEY_WITH_COLUMNS" in sql
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
            if "SEMANTIC_ADMIN.REMOVE_UNIQUE_KEY_WITH_COLUMNS" in sql
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

        add_identity = next(
            sql for sql in statements
            if "SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY" in sql
        )
        self.assertIn("entity already has an active semantic identity", add_identity)
        self.assertIn('tostring(model_status) == "PUBLISHED"', add_identity)
        self.assertIn("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL", add_identity)
        self.assertIn("published semantic-identity change rejected", add_identity)
        add_complete_identity = next(
            sql for sql in statements
            if "SEMANTIC_ADMIN.ADD_SEMANTIC_IDENTITY_WITH_BINDINGS" in sql
        )
        self.assertIn("BINDINGS_JSON must be a non-empty JSON array", add_complete_identity)
        self.assertIn("no binding supplied for active representation", add_complete_identity)
        self.assertIn("published identity-with-bindings candidate rejected", add_complete_identity)
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS", add_complete_identity)
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_BINDINGS", add_complete_identity)
        self.assertIn("DELETE FROM SYS_SEMANTIC.SEMANTIC_IDENTITIES", add_complete_identity)
        add_binding = next(
            sql for sql in statements
            if "SEMANTIC_ADMIN.ADD_IDENTITY_BINDING" in sql
        )
        self.assertIn('if binding_kind == "DIRECT"', add_binding)
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS", add_binding)

        add_representation_binding = next(
            sql for sql in statements
            if "SEMANTIC_ADMIN.ADD_ENTITY_REPRESENTATION_WITH_IDENTITY_BINDING" in sql
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
            if "SEMANTIC_ADMIN.REMOVE_IDENTITY_MAPPING_RELATION" in sql
        )
        self.assertIn("DELETE FROM SYS_SEMANTIC.IDENTITY_MAPPING_RELATIONS", remove_mapping)
        remove_binding = next(
            sql for sql in statements
            if "SEMANTIC_ADMIN.REMOVE_IDENTITY_BINDING" in sql
        )
        self.assertIn("cannot remove an identity binding with an active mapping relation", remove_binding)
        remove_identity = next(
            sql for sql in statements
            if "SEMANTIC_ADMIN.REMOVE_SEMANTIC_IDENTITY" in sql
        )
        self.assertIn("cannot remove a semantic identity with active bindings", remove_identity)
        remove_representation = next(
            sql for sql in statements
            if "SEMANTIC_ADMIN.REMOVE_ENTITY_REPRESENTATION" in sql
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

    def test_identifier_quoting(self):
        self.assertEqual('"A""B"', INSTALL.quote_ident('A"B'))


if __name__ == "__main__":
    unittest.main()
