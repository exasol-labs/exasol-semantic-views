"""Regressions for the defects the persona user studies reported.

Four simulated users (2026-05-13) and a follow-up round found these against
the sales model; reports are in reports/. Each test asserts the behaviour that
replaced the defect, and names it by its report id. A test that adds
`zz_repro_*` objects to the sales model takes the `repro` fixture, which
removes them and republishes afterwards.

BUG-010 is not here: it was a property of an external MCP server, not of this
layer, and needed that server running.
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from pathlib import Path
from typing import Any

import pytest

import verify_support as support

ROOT = Path(__file__).resolve().parents[2]
SALES_REQUEST = {"model": "sales", "object": "SALES", "metrics": ["total_revenue"],
                 "dimensions": ["order_month"]}


def doc(name: str) -> str:
    return (ROOT / "docs" / name).read_text(encoding="utf-8")


def rows(con: Any, sql: str) -> list[tuple[Any, ...]]:
    return [tuple(row) for row in con.execute(sql).fetchall()]


def script(con: Any, call: str) -> list[dict[str, Any]]:
    return support.named_rows(con.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{call}"))


def remove_repro_objects(con: Any) -> None:
    """Delete every zz_repro_* object; bindings before the rows they name."""
    repro = "UPPER({}) LIKE 'ZZ_REPRO_%'"
    metrics = f"SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE {repro.format('METRIC_NAME')}"
    for statement in (
        f"DELETE FROM SYS_SEMANTIC.METRIC_INPUTS WHERE METRIC_ID IN ({metrics})",
        f"DELETE FROM SYS_SEMANTIC.METRIC_FILTERS WHERE METRIC_ID IN ({metrics})",
        f"DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES WHERE METRIC_ID IN ({metrics})",
        f"DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE {repro.format('COLUMN_NAME')}",
        f"DELETE FROM SYS_SEMANTIC.SYNONYMS WHERE {repro.format('SYNONYM')}",
        "DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE ATTRIBUTE_TYPE = 'DIMENSION' AND ATTRIBUTE_ID IN"
        f" (SELECT DIMENSION_ID FROM SYS_SEMANTIC.DIMENSIONS WHERE {repro.format('DIMENSION_NAME')})",
        "DELETE FROM SYS_SEMANTIC.ATTRIBUTE_BINDINGS WHERE ATTRIBUTE_TYPE = 'FACT' AND ATTRIBUTE_ID IN"
        f" (SELECT FACT_ID FROM SYS_SEMANTIC.FACTS WHERE {repro.format('FACT_NAME')})",
        f"DELETE FROM SYS_SEMANTIC.FACTS WHERE {repro.format('FACT_NAME')}",
        f"DELETE FROM SYS_SEMANTIC.DIMENSIONS WHERE {repro.format('DIMENSION_NAME')}",
        f"DELETE FROM SYS_SEMANTIC.METRICS WHERE {repro.format('METRIC_NAME')}",
    ):
        con.execute(statement)


def republish(con: Any) -> None:
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")


@pytest.fixture(scope="module", autouse=True)
def published_sales() -> Iterator[None]:
    """The studies ran against the published sales model; so do these."""
    con = support.connect()
    try:
        remove_repro_objects(con)
        republish(con)
        yield
    finally:
        con.close()


@pytest.fixture
def repro(semantic_con: Any) -> Iterator[Any]:
    """A connection whose zz_repro_* objects are removed, and the model republished, after the test."""
    try:
        yield semantic_con
    finally:
        remove_repro_objects(semantic_con)
        republish(semantic_con)


# -- reading the published model ---------------------------------------------

def test_select_star_answers(semantic_con):  # BUG-001
    statement = semantic_con.execute("SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1")
    assert list(statement.columns())
    assert len(statement.fetchall()) == 1


def test_select_star_compiles(con):  # BUG-024
    assert support.compile_sql(con, "SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1")["status"] == "OK"


def test_order_by_a_select_alias_answers(semantic_con):  # BUG-027
    answer = rows(semantic_con, "SELECT customer_region, total_revenue AS rev FROM SEMANTIC_SALES.SALES"
                                " GROUP BY customer_region ORDER BY rev DESC")
    revenue = [float(row[1]) for row in answer]
    assert revenue and revenue == sorted(revenue, reverse=True)


def test_agent_fields_match_each_published_view(con):  # BUG-023
    # The study compared the model's fields with one view's columns; the
    # property is per object.
    fields = dict(rows(con, "SELECT OBJECT_NAME, COUNT(*) FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT"
                            " WHERE MODEL_NAME = 'sales' GROUP BY OBJECT_NAME"))
    columns = dict(rows(con, "SELECT COLUMN_TABLE, COUNT(*) FROM SYS.EXA_ALL_COLUMNS"
                             " WHERE COLUMN_SCHEMA = 'SEMANTIC_SALES' AND COLUMN_TABLE <> 'SEMANTIC_DISCOVERY'"
                             " GROUP BY COLUMN_TABLE"))
    assert fields == columns


def test_agent_fields_expose_metric_filters(con):  # BUG-020
    statement = con.execute("SELECT * FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE FIELD_NAME = 'completed_revenue'")
    assert any("FILTER" in column for column in statement.columns())


def test_validation_errors_are_queryable_for_agents(con):  # BUG-007
    con.execute("SELECT * FROM SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT WHERE MODEL_NAME = 'sales' LIMIT 1")


# -- the structured request ---------------------------------------------------

def test_a_filter_with_the_documented_alternate_keys_compiles(con):  # BUG-004
    result = support.compile_request(con, {
        "model": "sales", "object": "SALES", "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "filters": [{"dimension": "order_status", "operator": "=", "value": "COMPLETE"}]})
    assert result["status"] == "OK", result
    assert "COMPLETE" in result["generated_sql"]


def test_a_between_filter_compiles(con):  # BUG-018
    result = support.compile_request(con, {
        "model": "sales", "object": "SALES", "metrics": ["gross_margin"], "dimensions": ["customer_region"],
        "filters": [{"field": "order_month", "op": "BETWEEN", "value": ["2026-01-01", "2026-03-31"]}]})
    assert result["status"] == "OK", result


def test_a_request_without_metrics_compiles(con):  # BUG-006
    result = support.compile_request(con, {"model": "sales", "object": "SALES", "metrics": [],
                                           "dimensions": ["customer_region"]})
    assert result["status"] == "OK", result


# -- agent discovery ------------------------------------------------------------

def test_the_glossary_is_json(con):  # BUG-005
    glossary = script(con, "GET_BUSINESS_GLOSSARY('sales', 'SALES', 'STRUCTURED_REQUEST')")
    payload = next(value for value in glossary[0].values()
                   if isinstance(value, str) and value.startswith("{"))
    assert "resultrowaccessmetatable" not in payload
    assert json.loads(payload)["fields"]


def test_glossary_and_search_signatures_are_enforced_and_documented(con):  # BUG-021
    for call in ("GET_BUSINESS_GLOSSARY('sales')", "SEARCH_SEMANTIC_OBJECTS('revenue')"):
        with pytest.raises(Exception, match="script parameters"):
            script(con, call)
    contract = doc("agent-contract.md")
    for needle in ("GET_BUSINESS_GLOSSARY(", "SEARCH_SEMANTIC_OBJECTS(", "requires all three"):
        assert needle in contract


def test_a_multi_word_search_finds_matches(con):  # BUG-017
    assert script(con, "SEARCH_SEMANTIC_OBJECTS('revenue metrics', 'sales')")


def test_explain_names_the_valid_handle_types(con):  # BUG-025
    with pytest.raises(Exception, match="SEMANTIC_AGENT_003.*AGENT_REQUEST"):
        script(con, "EXPLAIN_COMPILED_SQL('VALIDATION_RUN', 1)")


def test_describing_an_unknown_model_says_it_is_not_visible(con):  # BUG-037
    with pytest.raises(Exception, match="SEMANTIC_AGENT_010: model not visible"):
        script(con, "DESCRIBE_SEMANTIC_OBJECT('nonexistent_model', 'SALES')")


def test_explain_semantic_metric_describes_its_definition(semantic_con):  # BUG-028
    answer = rows(semantic_con, "EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct")
    assert ("Definition", "expression", "gross_margin / NULLIF(total_revenue, 0)") in answer


# -- definitions and the catalog ----------------------------------------------

def test_export_covers_every_definition_kind(con):  # BUG-016
    kinds = {row["definition_kind"] for row in script(con, "EXPORT_SEMANTIC_DEFINITION('sales', NULL, NULL)")}
    assert {"DIMENSION", "ENTITY", "FACT", "METRIC", "RELATIONSHIP"} <= kinds


def test_export_filters_by_kind(con):  # P1-BUG-013
    exported = script(con, "EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', 'DIMENSION')")
    assert exported
    assert {row["definition_kind"] for row in exported} == {"DIMENSION"}


def test_refresh_semantic_surface_reports_each_object(con):  # BUG-034
    assert script(con, "REFRESH_SEMANTIC_SURFACE('sales')")


def test_compile_sql_is_documented(con):  # BUG-031
    assert support.compile_sql(con, "SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1")["status"] == "OK"
    compiler = doc("semantic-compiler.md")
    assert "COMPILE_SQL" in compiler and "generated SQL" in compiler


def test_the_catalog_docs_say_sys_semantic_is_internal():  # BUG-032
    assert "Direct `SYS_SEMANTIC` reads are for internal maintenance" in doc("semantic-catalog.md")


# -- authoring --------------------------------------------------------------------

def test_add_synonym_returns_a_result_set(repro):  # BUG-022
    added = script(repro, "ADD_SYNONYM('sales', 'METRIC', 'total_revenue', 'zz_repro_total_sales', 'MANUAL')")
    assert added[0]["synonym"] == "zz_repro_total_sales"


def test_add_synonym_names_a_wrong_object_type(repro):  # BUG-030
    with pytest.raises(Exception, match="SEMANTIC_ADMIN_003: invalid OBJECT_TYPE: SALES"):
        script(repro, "ADD_SYNONYM('sales', 'SALES', 'total_revenue', 'zz_repro_bad', 'MANUAL')")
    assert "second argument is the semantic object type" in doc("creating-metrics.md")


def test_add_dimension_returns_a_result_set(repro):  # BUG-033, P1-BUG-003
    added = script(repro, "ADD_DIMENSION('sales', 'SALES', 'order', 'zz_repro_signature_dim', 'o.order_status',"
                          " 'VARCHAR(32)', 'Signature Dimension', 'Signature test dimension', NULL, 0)")
    assert added[0]["dimension_name"] == "zz_repro_signature_dim"
    assert "ADD_DIMENSION" in doc("creating-metrics.md")


def test_add_metric_takes_its_documented_signature(repro):  # P1-BUG-002
    added = script(repro, "ADD_METRIC('sales', 'SALES', 'zz_repro_signature_metric', 'SUM(net_revenue)', NULL,"
                          " 'ADDITIVE', 'order_line', 'DECIMAL(18,2)', 'Signature Metric', 'Signature test metric',"
                          " 'currency', 0, 0)")
    assert added[0]["metric_name"] == "zz_repro_signature_metric"
    assert "`ADD_METRIC` takes:" in doc("creating-metrics.md")


@pytest.mark.parametrize("definition", [
    "ADD OR REPLACE DIMENSION zz_repro_alter_dim ON ENTITY order AS o.order_status RETURNS VARCHAR(32) PUBLIC",
    "ADD OR REPLACE METRIC zz_repro_alter_metric AS SUM(net_revenue) ON ENTITY order_line"
    " RETURNS DECIMAL(18,2) ADDITIVE PUBLIC",
], ids=["dimension", "metric"])
def test_alter_semantic_view_adds_to_a_published_model(repro, definition):  # BUG-035, BUG-012
    answer = rows(repro, f"ALTER SEMANTIC VIEW sales.SALES {definition}")
    assert answer[0][0] == "OK", answer


def test_a_fact_over_a_missing_column_is_refused(repro):  # BUG-013
    with pytest.raises(Exception, match="SEMANTIC_ADMIN_092"):
        script(repro, "ADD_FACT('sales', 'order_line', 'zz_repro_invalid_fact', 'ol.nonexistent_column_xyz',"
                      " 'DECIMAL(18,2)', 'ADDITIVE', 'Invalid Fact', '', 0, 0)")


def test_a_refused_fact_leaves_the_model_compiling(repro):  # BUG-002, -003, -008, -011, -029
    # The fact names a function that does not exist. It used to be accepted,
    # then failed every compile of the object and named the function wrongly
    # in the validation report. It is now refused at the door, and the model
    # it was refused from goes on answering.
    with pytest.raises(Exception, match="SEMANTIC_ADMIN_092.*PREDICT_LTV"):
        script(repro, "ADD_FACT('sales', 'order_line', 'zz_repro_predicted_ltv',"
                      " 'ML_SCHEMA.PREDICT_LTV(ol.order_id)', 'DECIMAL(18,2)', 'ADDITIVE', 'Predicted LTV', '', 0, 0)")
    assert support.compile_request(repro, SALES_REQUEST)["status"] == "OK"
    assert rows(repro, "SELECT product_category, gross_margin FROM SEMANTIC_SALES.SALES GROUP BY product_category")
    assert not any("ML_SCHEMA" in str(row) for row in script(repro, "VALIDATE_MODEL('sales')"))


def test_a_dimension_over_a_missing_column_is_refused(repro):  # BUG-014, BUG-009
    with pytest.raises(Exception, match="SEMANTIC_ADMIN_091"):
        script(repro, "ADD_DIMENSION('sales', 'SALES', 'order', 'zz_repro_bad_column_dim',"
                      " 'CASE WHEN o.nonexistent_column_xyz < 50 THEN ''Small'' ELSE ''Large'' END',"
                      " 'VARCHAR(20)', 'Bad Column Dim', '', NULL, 0)")
    assert not rows(repro, "SELECT * FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT"
                           " WHERE DIMENSION_NAME = 'zz_repro_bad_column_dim'")


def test_a_dimension_using_built_in_functions_validates(repro):  # BUG-036
    script(repro, "ADD_DIMENSION('sales', 'SALES', 'order', 'zz_repro_quarter_dim',"
                  " 'CONCAT(YEAR(o.order_date), ''-Q'', CEIL(MONTH(o.order_date) / 3.0))', 'VARCHAR(10)',"
                  " 'Quarter Dim', '', NULL, 0)")
    issues = script(repro, "VALIDATE_MODEL('sales')")
    assert not [issue for issue in issues if issue["severity"] == "ERROR"], issues


def test_a_function_exasol_does_not_have_is_named(repro):  # BUG-036
    # The study's own expression used QUARTER(), which Exasol does not provide.
    with pytest.raises(Exception, match="SEMANTIC_MODEL_016: Unsupported function in dimension expression: QUARTER"):
        script(repro, "ADD_DIMENSION('sales', 'SALES', 'order', 'zz_repro_quarter_dim',"
                      " 'CONCAT(YEAR(o.order_date), ''-Q'', QUARTER(o.order_date))', 'VARCHAR(10)',"
                      " 'Quarter Dim', '', NULL, 0)")


def test_warnings_alone_keep_the_model_usable_for_agents(repro):  # BUG-015
    script(repro, "ADD_METRIC('sales', 'SALES', 'zz_repro_warning_metric', 'SUM(net_revenue)', NULL, 'ADDITIVE',"
                  " 'order_line', 'DECIMAL(18,2)', 'Warning Metric', 'No format hint', NULL, 0, 0)")
    script(repro, "VALIDATE_MODEL('sales')")
    errors, readiness = rows(repro, "SELECT VALIDATION_ERROR_COUNT, AGENT_READINESS FROM SEMANTIC_AGENT.MODELS_FOR_AGENT"
                                    " WHERE MODEL_NAME = 'sales'")[0]
    assert int(errors) == 0
    assert readiness != "INVALID"


def test_an_ambiguous_synonym_asks_for_clarification(repro):  # BUG-019
    for metric in ("gross_margin", "gross_margin_pct"):
        script(repro, f"ADD_SYNONYM('sales', 'METRIC', '{metric}', 'zz_repro_profit', 'MANUAL')")
    result = support.compile_request(repro, {"model": "sales", "object": "SALES", "metrics": ["zz_repro_profit"],
                                             "dimensions": ["customer_region"]})
    assert result["status"] == "NEEDS_CLARIFICATION"
    assert set(json.loads(result["clarification_json"])["candidates"]) == {"gross_margin", "gross_margin_pct"}
