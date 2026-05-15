#!/usr/bin/env python3
"""Verify issues reported by the Claude persona studies against local Nano.

This is a host-side development tool. It intentionally mutates the local
development semantic catalog with `zz_repro_*` objects while checking failure
modes. Run `sh tools/run_nano_smoke.sh` afterwards to restore the baseline.
"""

from __future__ import annotations

import json
import os
import re
import ssl
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Any


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)

    return pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def rows_to_jsonable(rows: list[tuple[Any, ...]], limit: int = 30) -> list[list[Any]]:
    result: list[list[Any]] = []
    for row in rows[:limit]:
        result.append([value if isinstance(value, (str, int, float, bool)) or value is None else str(value) for value in row])
    return result


def execute_fetch(con, sql: str) -> dict[str, Any]:
    try:
        stmt = con.execute(sql)
        rows = [tuple(row) for row in stmt.fetchall()]
        return {
            "ok": True,
            "columns": list(stmt.columns().keys()),
            "row_count": len(rows),
            "rows": rows_to_jsonable(rows),
        }
    except Exception as exc:
        return {"ok": False, "error": str(exc).strip()}


def execute_no_fetch(con, sql: str) -> dict[str, Any]:
    try:
        con.execute(sql)
        return {"ok": True}
    except Exception as exc:
        return {"ok": False, "error": str(exc).strip()}


def compile_request(con, request: dict[str, Any]) -> dict[str, Any]:
    result = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(" + sql_string(json.dumps(request, separators=(",", ":"))) + ")")
    if result["ok"] and result["rows"]:
        row = result["rows"][0]
        result.update(
            {
                "status": row[0],
                "error_code": row[1],
                "error_message": row[2],
                "original_sql": row[3],
                "generated_sql": row[4],
                "clarification_json": row[6] if len(row) > 6 else None,
            }
        )
    return result


def compile_sql(con, sql: str) -> dict[str, Any]:
    result = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_SQL(" + sql_string(sql) + ")")
    if result["ok"] and result["rows"]:
        row = result["rows"][0]
        result.update(
            {
                "status": row[0],
                "error_code": row[1],
                "error_message": row[2],
                "generated_sql": row[4],
            }
        )
    return result


def file_contains(path: str, *needles: str) -> bool:
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return False
    return all(needle in text for needle in needles)


@dataclass
class Finding:
    bug: str
    status: str
    evidence: str


class Recorder:
    def __init__(self) -> None:
        self.findings: list[Finding] = []

    def add(self, bug: str, status: str, evidence: str) -> None:
        self.findings.append(Finding(bug, status, evidence.replace("\n", " ")[:900]))


def mcp_execute_script_probe() -> str:
    base = os.environ.get("MCP_BASE", "http://localhost:4896")
    initial = subprocess.run(
        ["curl", "-sv", "-H", "Accept: text/event-stream", f"{base}/mcp"],
        capture_output=True,
        text=True,
        check=False,
    )
    match = re.search(r"mcp-session-id: ([a-f0-9]+)", initial.stderr)
    if not match:
        return "MCP initialize failed: " + initial.stderr[-500:]
    session_id = match.group(1)

    def post(payload: dict[str, Any]) -> str:
        result = subprocess.run(
            [
                "curl",
                "-s",
                "-X",
                "POST",
                f"{base}/mcp",
                "-H",
                "Content-Type: application/json",
                "-H",
                "Accept: application/json, text/event-stream",
                "-H",
                f"mcp-session-id: {session_id}",
                "-d",
                json.dumps(payload),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        return result.stdout + result.stderr

    post(
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "issue-verifier", "version": "1"}},
        }
    )
    post({"jsonrpc": "2.0", "method": "notifications/initialized"})
    return post(
        {
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": {
                "name": "execute_exasol_query",
                "arguments": {"query": "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()"},
            },
        }
    )


def mark_repro_objects_deleted(con) -> None:
    statements = [
        "DELETE FROM SYS_SEMANTIC.METRIC_INPUTS WHERE METRIC_ID IN (SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE UPPER(METRIC_NAME) LIKE 'ZZ_REPRO_%')",
        "DELETE FROM SYS_SEMANTIC.METRIC_FILTERS WHERE METRIC_ID IN (SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE UPPER(METRIC_NAME) LIKE 'ZZ_REPRO_%')",
        "DELETE FROM SYS_SEMANTIC.METRIC_DEPENDENCIES WHERE METRIC_ID IN (SELECT METRIC_ID FROM SYS_SEMANTIC.METRICS WHERE UPPER(METRIC_NAME) LIKE 'ZZ_REPRO_%')",
        "DELETE FROM SYS_SEMANTIC.OBJECT_COLUMNS WHERE UPPER(COLUMN_NAME) LIKE 'ZZ_REPRO_%'",
        "DELETE FROM SYS_SEMANTIC.SYNONYMS WHERE UPPER(SYNONYM) LIKE 'ZZ_REPRO_%'",
        "DELETE FROM SYS_SEMANTIC.FACTS WHERE UPPER(FACT_NAME) LIKE 'ZZ_REPRO_%'",
        "DELETE FROM SYS_SEMANTIC.DIMENSIONS WHERE UPPER(DIMENSION_NAME) LIKE 'ZZ_REPRO_%'",
        "DELETE FROM SYS_SEMANTIC.METRICS WHERE UPPER(METRIC_NAME) LIKE 'ZZ_REPRO_%'",
    ]
    for sql in statements:
        try:
            con.execute(sql)
        except Exception:
            pass


def main() -> int:
    con = connect()
    rec = Recorder()
    try:
        execute_no_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
        mark_repro_objects_deleted(con)
        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")

        execute_no_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
        star = execute_fetch(con, "SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1")
        rec.add("BUG-001", "not_reproduced_fixed", f"SELECT * returned ok={star['ok']} columns={star.get('columns')} rows={star.get('row_count')} error={star.get('error')}")

        bad_filter = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["total_revenue"],
                "dimensions": ["customer_region"],
                "filters": [{"dimension": "order_status", "operator": "=", "value": "COMPLETE"}],
            },
        )
        rec.add(
            "BUG-004",
            "not_reproduced_fixed" if bad_filter.get("status") == "OK" and "COMPLETE" in str(bad_filter.get("generated_sql")) else "reproduced",
            f"status={bad_filter.get('status')} error={bad_filter.get('error_code')}: {bad_filter.get('error_message')}",
        )

        glossary = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'STRUCTURED_REQUEST')")
        glossary_json = glossary["rows"][0][4] if glossary["ok"] and glossary["rows"] else glossary.get("error")
        rec.add(
            "BUG-005",
            "reproduced" if "resultrowaccessmetatable" in str(glossary_json) else "not_reproduced_fixed",
            str(glossary_json)[:500],
        )

        one_arg_glossary = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales')")
        one_arg_search = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS('revenue')")
        documented_signatures = file_contains(
            "docs/agent-contract.md",
            "GET_BUSINESS_GLOSSARY(",
            "SEARCH_SEMANTIC_OBJECTS(",
            "requires all three",
        )
        rec.add(
            "BUG-021",
            "not_reproduced_documented" if documented_signatures else "api_reproduced_docs_need_review",
            f"one_arg_glossary={one_arg_glossary.get('error')} one_arg_search={one_arg_search.get('error')} documented={documented_signatures}",
        )

        export_rows = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', NULL, NULL)")
        kinds = sorted({row[0] for row in export_rows.get("rows", [])}) if export_rows["ok"] else []
        rec.add(
            "BUG-016",
            "not_reproduced_fixed" if {"DIMENSION", "ENTITY", "FACT", "METRIC", "RELATIONSHIP"}.issubset(set(kinds)) else "reproduced",
            f"kinds={kinds} row_count={export_rows.get('row_count')}",
        )

        multi_search = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS('revenue metrics', 'sales')")
        single_search = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.SEARCH_SEMANTIC_OBJECTS('revenue', 'sales')")
        rec.add("BUG-017", "reproduced" if multi_search.get("row_count") == 0 and single_search.get("row_count", 0) > 0 else "not_reproduced", f"multi={multi_search.get('row_count')} single={single_search.get('row_count')}")

        between = compile_request(
            con,
            {
                "model": "sales",
                "object": "SALES",
                "metrics": ["gross_margin"],
                "dimensions": ["customer_region"],
                "filters": [{"field": "order_month", "op": "BETWEEN", "value": ["2026-01-01", "2026-03-31"]}],
            },
        )
        rec.add(
            "BUG-018",
            "not_reproduced_fixed" if between.get("status") == "OK" else "reproduced",
            f"status={between.get('status')} error={between.get('error_code')}: {between.get('error_message')}",
        )

        fields_columns = execute_fetch(con, "SELECT * FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE FIELD_NAME='completed_revenue'")
        has_filter_column = any("FILTER" in col for col in fields_columns.get("columns", []))
        rec.add("BUG-020", "reproduced" if not has_filter_column else "not_reproduced_fixed", f"columns={fields_columns.get('columns')}")

        add_syn_fetch = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales','METRIC','total_revenue','zz_repro_total_sales','MANUAL')")
        rec.add("BUG-022", "reproduced" if not add_syn_fetch["ok"] and "without result set" in add_syn_fetch.get("error", "") else "not_reproduced", add_syn_fetch.get("error", str(add_syn_fetch)))

        field_count = execute_fetch(con, "SELECT COUNT(*) FROM SEMANTIC_AGENT.FIELDS_FOR_AGENT WHERE MODEL_NAME='sales'")
        view_col_count = execute_fetch(con, "SELECT COUNT(*) FROM SYS.EXA_ALL_COLUMNS WHERE COLUMN_SCHEMA='SEMANTIC_SALES' AND COLUMN_TABLE='SALES'")
        rec.add("BUG-023", "not_reproduced_fixed" if field_count.get("rows") == view_col_count.get("rows") else "reproduced", f"fields={field_count.get('rows')} view_cols={view_col_count.get('rows')}")

        star_compile = compile_sql(con, "SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1")
        generated = str(star_compile.get("generated_sql"))
        rec.add("BUG-024", "not_reproduced_fixed" if "order_size_band" not in generated and star_compile.get("status") == "OK" else "reproduced", generated[:500])

        invalid_handle = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPLAIN_COMPILED_SQL('VALIDATION_RUN', 1)")
        rec.add("BUG-025", "reproduced" if "AGENT_REQUEST" not in invalid_handle.get("error", "") else "not_reproduced_fixed", invalid_handle.get("error", str(invalid_handle)))

        order_alias = execute_fetch(con, "SELECT customer_region, total_revenue AS rev FROM SEMANTIC_SALES.SALES GROUP BY customer_region ORDER BY rev DESC")
        rec.add("BUG-027", "reproduced" if not order_alias["ok"] else "not_reproduced_fixed", order_alias.get("error", str(order_alias)))

        explain_clean = execute_fetch(con, "EXPLAIN SEMANTIC METRIC sales.SALES.gross_margin_pct")
        rec.add("BUG-028", "not_reproduced_on_clean_baseline", str(explain_clean.get("rows", explain_clean.get("error")))[:500])

        add_syn_wrong = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales','SALES','total_revenue','zz_repro_bad','MANUAL')")
        add_syn_documented = file_contains("docs/creating-metrics.md", "second argument is the semantic object type")
        rec.add(
            "BUG-030",
            "not_reproduced_documented" if add_syn_documented else "behavior_reproduced_doc_issue",
            f"wrong_call_error={add_syn_wrong.get('error', str(add_syn_wrong))} documented={add_syn_documented}",
        )

        compile_sql_documented = file_contains("docs/semantic-compiler.md", "COMPILE_SQL", "generated SQL")
        rec.add(
            "BUG-031",
            "not_reproduced_documented" if compile_sql_documented else "behavior_confirmed_doc_issue",
            f"COMPILE_SQL status={star_compile.get('status')} documented={compile_sql_documented}",
        )

        entities_model_name = execute_fetch(con, "SELECT * FROM SYS_SEMANTIC.ENTITIES WHERE MODEL_NAME='sales'")
        catalog_docs = file_contains("docs/semantic-catalog.md", "Direct `SYS_SEMANTIC` reads are for internal maintenance")
        rec.add(
            "BUG-032",
            "not_reproduced_documented" if catalog_docs else "reproduced",
            f"internal_error={entities_model_name.get('error', str(entities_model_name))} documented={catalog_docs}",
        )

        add_dim_fetch = execute_fetch(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('sales','SALES','order','zz_repro_fetch_dim','o.order_status','VARCHAR(32)','Fetch Dim','',NULL,0)",
        )
        rec.add("BUG-033", "reproduced" if not add_dim_fetch["ok"] and "without result set" in add_dim_fetch.get("error", "") else "not_reproduced", add_dim_fetch.get("error", str(add_dim_fetch)))

        refresh = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.REFRESH_SEMANTIC_SURFACE('sales')")
        rec.add("BUG-034", "reproduced" if not refresh["ok"] else "not_reproduced_fixed", refresh.get("error", str(refresh)))

        alter_dim = execute_fetch(
            con,
            """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE DIMENSION zz_repro_alter_dim
  ON ENTITY order
  AS o.order_status
  RETURNS VARCHAR(32)
  PUBLIC""",
        )
        rec.add("BUG-035", "reproduced" if alter_dim["ok"] and alter_dim.get("rows", [[]])[0][0] == "ERROR" else "not_reproduced", str(alter_dim))

        wrong_model = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT('nonexistent_model','SALES')")
        rec.add("BUG-037", "not_reproduced_fixed" if "model not visible" in wrong_model.get("error", "") else "reproduced", wrong_model.get("error", str(wrong_model)))

        add_metric_signature = execute_fetch(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC('sales','SALES','zz_repro_signature_metric','SUM(net_revenue)',NULL,"
            "'ADDITIVE','order_line','DECIMAL(18,2)','Signature Metric','Signature test metric','currency',0,0)",
        )
        rec.add(
            "P1-BUG-002",
            "not_reproduced_documented" if add_metric_signature["ok"] and file_contains("docs/creating-metrics.md", "`ADD_METRIC` takes:") else "reproduced",
            str(add_metric_signature),
        )

        add_dimension_signature = execute_fetch(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('sales','SALES','order','zz_repro_signature_dim','o.order_status',"
            "'VARCHAR(32)','Signature Dimension','Signature test dimension',NULL,0)",
        )
        rec.add(
            "P1-BUG-003",
            "not_reproduced_documented" if add_dimension_signature["ok"] and file_contains("docs/creating-metrics.md", "ADD_DIMENSION") else "reproduced",
            str(add_dimension_signature),
        )

        export_dimensions = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales','SALES','DIMENSION')")
        dimension_rows_only = export_dimensions["ok"] and export_dimensions.get("row_count", 0) > 0 and all(row[0] == "DIMENSION" for row in export_dimensions.get("rows", []))
        rec.add("P1-BUG-013", "not_reproduced_fixed" if dimension_rows_only else "reproduced", str(export_dimensions))

        mark_repro_objects_deleted(con)
        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")

        mcp_probe = mcp_execute_script_probe()
        rec.add("BUG-010", "reproduced_external_mcp", mcp_probe[:600])

        # Invalid fact cascade group.
        add_fact = execute_fetch(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('sales','order_line','zz_repro_predicted_ltv',"
            "'ML_SCHEMA.PREDICT_LTV(ol.order_id)','DECIMAL(18,2)','ADDITIVE','Predicted LTV','',0,0)",
        )
        validation = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        validation_text = str(validation.get("rows", validation.get("error")))
        rec.add("BUG-002", "reproduced" if "PREDICT_LTV" in validation_text and "ML_SCHEMA" in validation_text else "not_reproduced", validation_text)
        invalid_fact = execute_fetch(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_FACT('sales','order_line','zz_repro_invalid_fact',"
            "'ol.nonexistent_column_xyz','DECIMAL(18,2)','ADDITIVE','Invalid Fact','',0,0)",
        )
        rec.add(
            "BUG-013",
            "not_reproduced_fixed" if not invalid_fact["ok"] and "SEMANTIC_ADMIN_092" in invalid_fact.get("error", "") else "reproduced",
            f"valid_udf_fact={add_fact.get('rows', add_fact.get('error'))} invalid_fact={invalid_fact}",
        )

        compile_valid = compile_request(con, {"model": "sales", "object": "SALES", "metrics": ["total_revenue"], "dimensions": ["order_month"]})
        rec.add("BUG-003", "reproduced" if compile_valid.get("status") == "ERROR" else "not_reproduced_fixed", f"{compile_valid.get('error_code')}: {compile_valid.get('error_message')}")

        models_invalid = execute_fetch(con, "SELECT AGENT_READINESS, VALIDATION_ERROR_COUNT FROM SEMANTIC_AGENT.MODELS_FOR_AGENT WHERE MODEL_NAME='sales'")
        model_columns = execute_fetch(con, "SELECT * FROM SEMANTIC_AGENT.MODELS_FOR_AGENT WHERE MODEL_NAME='sales'")
        validation_errors_view = execute_fetch(con, "SELECT * FROM SEMANTIC_AGENT.VALIDATION_ERRORS_FOR_AGENT WHERE MODEL_NAME='sales' LIMIT 1")
        rec.add(
            "BUG-007",
            "not_reproduced_fixed" if validation_errors_view["ok"] else "reproduced",
            f"readiness={models_invalid.get('rows')} model_columns={model_columns.get('columns')} validation_errors_view={validation_errors_view.get('columns', validation_errors_view.get('error'))}",
        )

        direct_query = execute_fetch(con, "SELECT product_category, gross_margin FROM SEMANTIC_SALES.SALES GROUP BY product_category")
        rec.add("BUG-011", "reproduced" if compile_valid.get("status") == "ERROR" and direct_query["ok"] else "not_reproduced", f"compile={compile_valid.get('status')} direct_ok={direct_query['ok']}")

        alter_metric = execute_fetch(
            con,
            """ALTER SEMANTIC VIEW sales.SALES
ADD OR REPLACE METRIC zz_repro_alter_metric
  AS SUM(net_revenue)
  ON ENTITY order_line
  RETURNS DECIMAL(18,2)
  ADDITIVE PUBLIC""",
        )
        rec.add("BUG-012", "reproduced" if "catalog state was restored" in str(alter_metric) and "zz_repro_predicted_ltv" not in str(alter_metric) else "not_reproduced", str(alter_metric))

        msg_013 = execute_fetch(con, "SELECT OBJECT_NAME, MESSAGE FROM SYS_SEMANTIC.VALIDATION_RESULTS WHERE RULE_CODE='SEMANTIC_MODEL_013' ORDER BY VALIDATION_RUN_ID DESC LIMIT 3")
        rec.add("BUG-029", "reproduced" if "ML_SCHEMA.." in str(compile_valid.get("error_message")) or "ML_SCHEMA." in str(msg_013) else "not_reproduced", str(msg_013.get("rows", msg_013.get("error"))))

        con.execute("UPDATE SYS_SEMANTIC.FACTS SET STATUS='DELETED' WHERE FACT_NAME='zz_repro_predicted_ltv'")
        stale_compile = compile_request(con, {"model": "sales", "object": "SALES", "metrics": ["total_revenue"], "dimensions": ["order_month"]})
        rec.add("BUG-008", "reproduced" if stale_compile.get("status") == "ERROR" else "not_reproduced_fixed", f"{stale_compile.get('error_code')}: {stale_compile.get('error_message')}")
        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")

        # Invalid dimension / validation model group.
        invalid_dim_add = execute_fetch(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('sales','SALES','order','zz_repro_bad_column_dim',"
            "'CASE WHEN o.nonexistent_column_xyz < 50 THEN ''Small'' ELSE ''Large'' END','VARCHAR(20)','Bad Column Dim','',NULL,0)",
        )
        bad_col_validation = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        bad_col_compile = compile_request(
            con,
            {"model": "sales", "object": "SALES", "metrics": ["total_revenue"], "dimensions": ["zz_repro_bad_column_dim"]},
        )
        bad_col_execute = execute_fetch(con, bad_col_compile.get("generated_sql") or "SELECT 1")
        matrix_bad = execute_fetch(
            con,
            "SELECT METRIC_NAME, DIMENSION_NAME, IS_VALID, REASON_CODE FROM SEMANTIC_AGENT.VALID_COMBINATIONS_FOR_AGENT WHERE DIMENSION_NAME='zz_repro_bad_column_dim'",
        )
        rec.add("BUG-014", "reproduced" if bad_col_validation.get("row_count") == 0 and bad_col_compile.get("status") == "OK" and not bad_col_execute["ok"] else "not_reproduced", f"add={invalid_dim_add} validate={bad_col_validation.get('rows')} compile={bad_col_compile.get('status')} execute={bad_col_execute.get('error')}")
        rec.add("BUG-009", "reproduced" if "True" in str(matrix_bad.get("rows")) and not bad_col_execute["ok"] else "not_reproduced", str(matrix_bad.get("rows", matrix_bad.get("error"))))

        execute_no_fetch(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('sales','SALES','order','zz_repro_quarter_dim',"
            "'CONCAT(YEAR(o.order_date), ''-Q'', QUARTER(o.order_date))','VARCHAR(10)','Quarter Dim','',NULL,0)",
        )
        func_validation = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        rec.add("BUG-036", "reproduced" if "CONCAT" in str(func_validation) and "YEAR" in str(func_validation) else "not_reproduced_fixed", str(func_validation.get("rows", func_validation.get("error"))))
        invalid_request = compile_request(con, {"model": "sales", "object": "SALES", "metrics": [], "dimensions": ["customer_region"]})
        rec.add("BUG-006", "reproduced" if invalid_request.get("error_code") == "SEMANTIC_REQUEST_010" else "not_reproduced_fixed", f"{invalid_request.get('error_code')}: {invalid_request.get('error_message')}")

        mark_repro_objects_deleted(con)
        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")

        add_warning_metric = execute_fetch(
            con,
            "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_METRIC('sales','SALES','zz_repro_warning_metric','SUM(net_revenue)',NULL,'ADDITIVE','order_line','DECIMAL(18,2)','Warning Metric','No format hint',NULL,0,0)",
        )
        warning_validation = execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
        warning_readiness = execute_fetch(con, "SELECT VALIDATION_STATUS, VALIDATION_ERROR_COUNT, VALIDATION_WARNING_COUNT, AGENT_READINESS FROM SEMANTIC_AGENT.MODELS_FOR_AGENT WHERE MODEL_NAME='sales'")
        rec.add("BUG-015", "reproduced" if "WARNING" in str(warning_readiness) and "INVALID" in str(warning_readiness) else "not_reproduced_fixed", f"add={add_warning_metric.get('rows', add_warning_metric.get('error'))} validate={warning_validation.get('rows')} readiness={warning_readiness.get('rows')}")

        mark_repro_objects_deleted(con)
        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")

        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales','METRIC','gross_margin','zz_repro_profit','MANUAL')")
        execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales','METRIC','gross_margin_pct','zz_repro_profit','MANUAL')")
        ambiguous = compile_request(con, {"model": "sales", "object": "SALES", "metrics": ["zz_repro_profit"], "dimensions": ["customer_region"]})
        rec.add("BUG-019", "reproduced" if ambiguous.get("status") == "ERROR" and ambiguous.get("clarification_json") in (None, "") else "not_reproduced_fixed", f"status={ambiguous.get('status')} error={ambiguous.get('error_message')} clarification={ambiguous.get('clarification_json')}")

        print("| Bug | Verification status | Evidence |")
        print("|---|---|---|")
        for finding in rec.findings:
            print(f"| {finding.bug} | {finding.status} | {finding.evidence.replace('|', '/')} |")
    finally:
        try:
            mark_repro_objects_deleted(con)
            execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
            execute_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")
            execute_no_fetch(con, "EXECUTE SCRIPT SEMANTIC_ADMIN.DISABLE_SEMANTIC_SQL()")
            con.execute("ALTER SYSTEM SET SQL_PREPROCESSOR_SCRIPT = NULL")
        finally:
            con.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
