#!/usr/bin/env python3
"""Package Lua runtime sources into Exasol CREATE SCRIPT install SQL."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALL_SQL = ROOT / "sql/install/003_create_semantic_admin_scripts.sql"
AGENT_INSTALL_SQL = ROOT / "sql/install/006_create_semantic_agent_views.sql"
COMPILER_SOURCE = ROOT / "lua/semantic_layer/compiler/request_json.lua"
MATERIALIZATIONS_SOURCE = ROOT / "lua/semantic_layer/compiler/materializations.lua"
VALIDATOR_SOURCE = ROOT / "lua/semantic_layer/admin/validator.lua"
SEMANTIC_DEFINITION_SOURCE = ROOT / "lua/semantic_layer/admin/semantic_definition.lua"
AGENT_SOURCE = ROOT / "lua/semantic_layer/agent/runtime.lua"

BEGIN = "-- BEGIN GENERATED COMPILER_RUNTIME"
END = "-- END GENERATED COMPILER_RUNTIME"
VALIDATOR_BEGIN = "-- BEGIN GENERATED VALIDATOR_RUNTIME"
VALIDATOR_END = "-- END GENERATED VALIDATOR_RUNTIME"
SEMANTIC_BEGIN = "-- BEGIN GENERATED SEMANTIC_DEFINITION_RUNTIME"
SEMANTIC_END = "-- END GENERATED SEMANTIC_DEFINITION_RUNTIME"
AGENT_BEGIN = "-- BEGIN GENERATED AGENT_RUNTIME"
AGENT_END = "-- END GENERATED AGENT_RUNTIME"


def validator_block() -> str:
    source = VALIDATOR_SOURCE.read_text(encoding="utf-8").rstrip()
    return f"""{VALIDATOR_BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.VALIDATOR_RUNTIME AS
{source}
/
{VALIDATOR_END}"""


def compiler_block() -> str:
    source = COMPILER_SOURCE.read_text(encoding="utf-8").rstrip()
    materializations_source = MATERIALIZATIONS_SOURCE.read_text(encoding="utf-8").rstrip()
    return f"""{BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.MATERIALIZATION_RUNTIME AS
{materializations_source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILER_RUNTIME AS
{source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(
  REQUEST_JSON
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_request_json(REQUEST_JSON)

exit({{
    {{
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.agent_request_id or null,
    }}
}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  ORIGINAL_SQL VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  CLARIFICATION_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  AGENT_REQUEST_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL(
  ORIGINAL_SQL
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_sql(ORIGINAL_SQL)

exit({{
    {{
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        ORIGINAL_SQL or null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.agent_request_id or null,
    }}
}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  ORIGINAL_SQL VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  CLARIFICATION_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  AGENT_REQUEST_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL_DEBUG(
  ORIGINAL_SQL,
  CLIENT_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.COMPILER_RUNTIME", "compiler")

local result = compiler.compile_sql_debug(ORIGINAL_SQL, CLIENT_NAME)

exit({{
    {{
        result.status or null,
        result.error_code or null,
        result.error_message or null,
        ORIGINAL_SQL or null,
        result.generated_sql or null,
        result.plan_json or null,
        result.clarification_json or null,
        result.validation_run_id or null,
        result.query_log_id or null,
    }}
}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  ORIGINAL_SQL VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  CLARIFICATION_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  QUERY_LOG_ID DECIMAL(18,0)
]])
/
{END}"""


def semantic_definition_block() -> str:
    source = SEMANTIC_DEFINITION_SOURCE.read_text(encoding="utf-8").rstrip()
    return f"""{SEMANTIC_BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME AS
{source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.APPLY_SEMANTIC_DEFINITION(
  DEFINITION_SQL,
  DRY_RUN
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_semantic_definition(DEFINITION_SQL, DRY_RUN)

exit(rows or {{}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  MESSAGE VARCHAR(2000000),
  NORMALIZED_JSON VARCHAR(2000000),
  OPERATION_COUNT DECIMAL(18,0),
  VALIDATION_RUN_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.APPLY_NORMALIZED_OSI_IMPORT(
  PLAN_JSON,
  VALIDATE_AFTER_APPLY,
  WARNINGS_AS_ERRORS
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.apply_normalized_osi_import(
    PLAN_JSON,
    VALIDATE_AFTER_APPLY,
    WARNINGS_AS_ERRORS
)

exit(rows or {{}}, [[
  STATUS VARCHAR(32),
  OPERATION_INDEX DECIMAL(18,0),
  OPERATION_NAME VARCHAR(128),
  TARGET VARCHAR(512),
  SOURCE_PATH VARCHAR(2000000),
  ROW_COUNT DECIMAL(18,0),
  WARNING_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0),
  MESSAGE VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.IMPORT_DATABRICKS_METRIC_VIEW(
  YAML_TEXT,
  MODEL_NAME,
  PUBLISHED_SCHEMA,
  APPLY_IMPORT
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.import_databricks_metric_view(
    YAML_TEXT,
    MODEL_NAME,
    PUBLISHED_SCHEMA,
    APPLY_IMPORT
)

exit(rows or {{}}, [[
  STATUS VARCHAR(32),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  MODEL_NAME VARCHAR(256),
  GENERATED_DDL VARCHAR(2000000),
  DIAGNOSTICS_JSON VARCHAR(2000000),
  VALIDATION_RUN_ID DECIMAL(18,0)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_METRIC(
  MODEL_NAME,
  OBJECT_NAME,
  METRIC_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.describe_semantic_metric(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {{}}, [[
  SECTION_NAME VARCHAR(128),
  PROPERTY_NAME VARCHAR(256),
  PROPERTY_VALUE VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.EXPLAIN_SEMANTIC_METRIC(
  MODEL_NAME,
  OBJECT_NAME,
  METRIC_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.explain_semantic_metric(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {{}}, [[
  SECTION_NAME VARCHAR(128),
  ITEM_NAME VARCHAR(256),
  DETAIL_TEXT VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION(
  MODEL_NAME,
  OBJECT_NAME,
  METRIC_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.SEMANTIC_DEFINITION_RUNTIME", "semantic_definition")

local rows = semantic_definition.export_semantic_definition(MODEL_NAME, OBJECT_NAME, METRIC_NAME)

exit(rows or {{}}, [[
  DEFINITION_KIND VARCHAR(64),
  DEFINITION_REF VARCHAR(1024),
  DEFINITION_SQL VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()
RETURNS TABLE AS
query("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR")
exit({{{{"OK", "SESSION", "SEMANTIC_ADMIN.SEMANTIC_PREPROCESSOR", "Semantic SQL enabled for this session."}}}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(512),
  MESSAGE VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()
RETURNS TABLE AS
query("ALTER SESSION SET SQL_PREPROCESSOR_SCRIPT = NULL")
exit({{{{"OK", "SESSION", null, "Semantic SQL disabled for this session."}}}}, [[
  STATUS VARCHAR(32),
  ACTIVATION_SCOPE VARCHAR(32),
  PREPROCESSOR_SCRIPT VARCHAR(512),
  MESSAGE VARCHAR(2000000)
]])
/
{SEMANTIC_END}"""


def agent_block() -> str:
    source = AGENT_SOURCE.read_text(encoding="utf-8").rstrip()
    return f"""{AGENT_BEGIN}
CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.AGENT_RUNTIME AS
{source}
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  MODEL_NAME,
  SCOPE_TYPE,
  SCOPE_NAME,
  INSTRUCTION_KIND,
  INSTRUCTION_TEXT,
  APPLIES_TO_ROLE,
  PRIORITY
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.add_agent_instruction(
    MODEL_NAME,
    SCOPE_TYPE,
    SCOPE_NAME,
    INSTRUCTION_KIND,
    INSTRUCTION_TEXT,
    APPLIES_TO_ROLE,
    PRIORITY
)

exit(rows or {{}}, [[
  INSTRUCTION_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  SCOPE_TYPE VARCHAR(64),
  SCOPE_NAME VARCHAR(512),
  INSTRUCTION_KIND VARCHAR(64),
  STATUS VARCHAR(32)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.ADD_VERIFIED_QUERY(
  MODEL_NAME,
  OBJECT_NAME,
  QUERY_NAME,
  NATURAL_LANGUAGE_TEXT,
  REQUEST_JSON,
  EXPECTED_RESULT_SHAPE,
  IS_ONBOARDING_EXAMPLE
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.add_verified_query(
    MODEL_NAME,
    OBJECT_NAME,
    QUERY_NAME,
    NATURAL_LANGUAGE_TEXT,
    REQUEST_JSON,
    EXPECTED_RESULT_SHAPE,
    IS_ONBOARDING_EXAMPLE
)

exit(rows or {{}}, [[
  VERIFIED_QUERY_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  QUERY_NAME VARCHAR(512),
  STATUS VARCHAR(32),
  GENERATED_SQL VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS(
  QUERY_TEXT,
  MODEL_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.search_semantic_objects(QUERY_TEXT, MODEL_NAME)

exit(rows or {{}}, [[
  RESULT_TYPE VARCHAR(64),
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  FIELD_KIND VARCHAR(64),
  FIELD_NAME VARCHAR(256),
  DISPLAY_NAME VARCHAR(512),
  DESCRIPTION VARCHAR(2000000),
  MATCH_TEXT VARCHAR(2000000),
  SCORE DECIMAL(18,0),
  IS_CERTIFIED BOOLEAN
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT(
  MODEL_NAME,
  OBJECT_NAME
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.describe_semantic_object(MODEL_NAME, OBJECT_NAME)

exit(rows or {{}}, [[
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  ROW_KIND VARCHAR(64),
  FIELD_KIND VARCHAR(64),
  FIELD_NAME VARCHAR(256),
  SQL_COLUMN_NAME VARCHAR(256),
  DATA_TYPE VARCHAR(128),
  DESCRIPTION VARCHAR(2000000),
  DETAILS_JSON VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY(
  MODEL_NAME,
  OBJECT_NAME,
  QUERY_MODE
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.get_business_glossary(MODEL_NAME, OBJECT_NAME, QUERY_MODE)

exit(rows or {{}}, [[
  MODEL_NAME VARCHAR(256),
  OBJECT_NAME VARCHAR(256),
  QUERY_MODE VARCHAR(64),
  GLOSSARY_TEXT VARCHAR(2000000),
  GLOSSARY_JSON VARCHAR(2000000)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL(
  HANDLE_TYPE,
  HANDLE_ID
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.explain_compiled_sql(HANDLE_TYPE, HANDLE_ID)

exit(rows or {{}}, [[
  HANDLE_TYPE VARCHAR(64),
  HANDLE_ID DECIMAL(18,0),
  MODEL_NAME VARCHAR(256),
  VERSION_ID DECIMAL(18,0),
  STATUS VARCHAR(64),
  ERROR_CODE VARCHAR(128),
  ERROR_MESSAGE VARCHAR(2000000),
  REQUEST_TEXT VARCHAR(2000000),
  GENERATED_SQL VARCHAR(2000000),
  PLAN_JSON VARCHAR(2000000),
  REQUESTED_DIMENSIONS VARCHAR(2000000),
  REQUESTED_METRICS VARCHAR(2000000),
  SELECTED_MATERIALIZATION VARCHAR(512)
]])
/

CREATE OR REPLACE SCRIPT SEMANTIC_ADMIN.RECORD_AGENT_FEEDBACK(
  HANDLE_TYPE,
  HANDLE_ID,
  VERDICT,
  COMMENT_TEXT,
  PROPOSED_CHANGE_JSON
)
RETURNS TABLE AS
import("SEMANTIC_ADMIN.AGENT_RUNTIME", "agent")

local rows = agent.record_agent_feedback(
    HANDLE_TYPE,
    HANDLE_ID,
    VERDICT,
    COMMENT_TEXT,
    PROPOSED_CHANGE_JSON
)

exit(rows or {{}}, [[
  FEEDBACK_ID DECIMAL(18,0),
  SUGGESTION_ID DECIMAL(18,0),
  HANDLE_TYPE VARCHAR(64),
  HANDLE_ID DECIMAL(18,0),
  VERDICT VARCHAR(64),
  REVIEW_STATUS VARCHAR(64)
]])
/
{AGENT_END}"""


def replace_between_markers(text: str, block: str, begin: str, end: str) -> str:
    if begin in text and end in text:
        before = text[: text.index(begin)]
        after = text[text.index(end) + len(end) :]
        return before.rstrip() + "\n\n" + block + after
    return text.rstrip() + "\n\n" + block + "\n"


def main() -> int:
    original = INSTALL_SQL.read_text(encoding="utf-8")
    updated = replace_between_markers(original, validator_block(), VALIDATOR_BEGIN, VALIDATOR_END)
    updated = replace_between_markers(updated, semantic_definition_block(), SEMANTIC_BEGIN, SEMANTIC_END)
    updated = replace_between_markers(updated, compiler_block(), BEGIN, END)
    if updated != original:
        INSTALL_SQL.write_text(updated, encoding="utf-8")
        print(f"updated {INSTALL_SQL.relative_to(ROOT)}")
    else:
        print(f"unchanged {INSTALL_SQL.relative_to(ROOT)}")

    original_agent = AGENT_INSTALL_SQL.read_text(encoding="utf-8")
    updated_agent = replace_between_markers(original_agent, agent_block(), AGENT_BEGIN, AGENT_END)
    if updated_agent != original_agent:
        AGENT_INSTALL_SQL.write_text(updated_agent, encoding="utf-8")
        print(f"updated {AGENT_INSTALL_SQL.relative_to(ROOT)}")
    else:
        print(f"unchanged {AGENT_INSTALL_SQL.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
