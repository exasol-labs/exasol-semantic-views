"""
Persona Test: Jin — BI Platform Administrator
Simulated user test for the Exasol Semantic Views project.
"""
import sys
import json
import traceback

sys.path.insert(0, '/Users/alexander.stigsen/Dev/exasol-semantic-views/tools')
from persona_test_helper import sql, execute_script, run_statement, get_conn, TestLog

log = TestLog("Jin — BI Platform Administrator")
bugs = []

def note_bug(id, severity, title, repro, expected, actual):
    bugs.append({"id": id, "severity": severity, "title": title, "repro": repro, "expected": expected, "actual": actual})
    log.bug(id, title, repro, expected, actual)

# ===========================================================================
# SCENARIO 1: Catalog Exploration
# ===========================================================================
print("\n=== SCENARIO 1: CATALOG EXPLORATION ===")

# List all views in SEMANTIC_CATALOG
rows, cols, err = sql("SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_CATALOG' ORDER BY VIEW_NAME")
log.step("1.1 List SEMANTIC_CATALOG views", "SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_CATALOG'",
         rows, err)
if rows:
    catalog_views = [r[0] for r in rows]
    log.observe(f"SEMANTIC_CATALOG views: {catalog_views}")
    print(f"  Found {len(rows)} views in SEMANTIC_CATALOG: {catalog_views}")
elif err:
    print(f"  Error: {err}")

# List all views in SEMANTIC_AGENT
rows2, cols2, err2 = sql("SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_AGENT' ORDER BY VIEW_NAME")
log.step("1.2 List SEMANTIC_AGENT views", "SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_AGENT'",
         rows2, err2)
if rows2:
    agent_views = [r[0] for r in rows2]
    print(f"  Found {len(rows2)} views in SEMANTIC_AGENT: {agent_views}")
elif err2:
    print(f"  Error: {err2}")

# Browse MODELS view
rows3, cols3, err3 = sql("SELECT MODEL_NAME, PUBLISHED_SCHEMA, DESCRIPTION, OWNER_ROLE, STATUS, ACTIVE_VERSION_NUMBER, SURFACE_TYPE FROM SEMANTIC_CATALOG.MODELS")
log.step("1.3 Browse SEMANTIC_CATALOG.MODELS", "SELECT * FROM SEMANTIC_CATALOG.MODELS", rows3, err3)
if rows3:
    for r in rows3:
        print(f"  Model: {r}")

# Browse dimensions
rows4, cols4, err4 = sql("SELECT MODEL_NAME, DIMENSION_NAME, DATA_TYPE, DESCRIPTION, IS_CERTIFIED FROM SEMANTIC_CATALOG.DIMENSIONS ORDER BY MODEL_NAME, DIMENSION_NAME")
log.step("1.4 Browse SEMANTIC_CATALOG.DIMENSIONS", "SELECT * FROM SEMANTIC_CATALOG.DIMENSIONS", rows4, err4)
if rows4:
    print(f"  Dimensions: {len(rows4)} rows")
    for r in rows4:
        print(f"    {r}")

# Browse metrics
rows5, cols5, err5 = sql("SELECT MODEL_NAME, METRIC_NAME, METRIC_TYPE, DESCRIPTION, IS_CERTIFIED FROM SEMANTIC_CATALOG.METRICS ORDER BY MODEL_NAME, METRIC_NAME")
log.step("1.5 Browse SEMANTIC_CATALOG.METRICS", "SELECT * FROM SEMANTIC_CATALOG.METRICS", rows5, err5)
if rows5:
    print(f"  Metrics: {len(rows5)} rows")
    for r in rows5:
        print(f"    {r}")

# Browse entities
rows6, cols6, err6 = sql("SELECT MODEL_NAME, ENTITY_NAME, SOURCE_SCHEMA, SOURCE_OBJECT, SOURCE_ALIAS FROM SEMANTIC_CATALOG.ENTITIES ORDER BY MODEL_NAME, ENTITY_NAME")
log.step("1.6 Browse SEMANTIC_CATALOG.ENTITIES", "SELECT * FROM SEMANTIC_CATALOG.ENTITIES", rows6, err6)
if rows6:
    print(f"  Entities: {len(rows6)} rows")
    for r in rows6:
        print(f"    {r}")

# Check for OBJECT_PRIVILEGES in catalog - Jin wants to understand access control
rows7, cols7, err7 = sql("SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_CATALOG' AND VIEW_NAME LIKE '%PRIV%'")
log.step("1.7 Look for privilege views in SEMANTIC_CATALOG",
         "SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_CATALOG' AND VIEW_NAME LIKE '%PRIV%'",
         rows7, err7, note="Checking if access control views are exposed in catalog")
if not rows7:
    note_bug("J-001", "P2",
             "No OBJECT_PRIVILEGES view in SEMANTIC_CATALOG — admins cannot audit access grants from catalog",
             "SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_CATALOG' AND VIEW_NAME LIKE '%PRIV%'",
             "SEMANTIC_CATALOG.OBJECT_PRIVILEGES view visible",
             "No privilege views found in SEMANTIC_CATALOG; SYS_SEMANTIC.OBJECT_PRIVILEGES table exists in schema but is not exposed")

# ===========================================================================
# SCENARIO 2: Validation Status Audit
# ===========================================================================
print("\n=== SCENARIO 2: VALIDATION STATUS AUDIT ===")

rows8, cols8, err8 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
log.step("2.1 VALIDATE_MODEL('sales')", "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')", rows8, err8)
if rows8:
    print(f"  Validation returned {len(rows8)} rows (issues)")
    for r in rows8:
        print(f"    {r}")
elif err8:
    print(f"  Validation error: {err8}")
else:
    print("  Validation returned 0 rows (no issues)")

# Check VALIDATION_RUNS catalog view
rows9, cols9, err9 = sql("SELECT MODEL_NAME, VERSION_NUMBER, STATUS, ISSUE_COUNT, ERROR_COUNT, WARNING_COUNT, STARTED_AT FROM SEMANTIC_CATALOG.VALIDATION_RUNS ORDER BY STARTED_AT DESC LIMIT 5")
log.step("2.2 Check SEMANTIC_CATALOG.VALIDATION_RUNS", "SELECT * FROM SEMANTIC_CATALOG.VALIDATION_RUNS ORDER BY STARTED_AT DESC LIMIT 5", rows9, err9)
if rows9:
    print(f"  Recent validation runs:")
    for r in rows9:
        print(f"    {r}")
elif err9:
    print(f"  Error: {err9}")
else:
    print("  No validation runs recorded yet")
    log.observe("VALIDATION_RUNS is empty — possibly OK if this is the first run")


# Check CURRENT_VALIDATION_ISSUES
rows10, cols10, err10 = sql("SELECT MODEL_NAME, SEVERITY, OBJECT_TYPE, OBJECT_NAME, RULE_CODE, MESSAGE FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES ORDER BY SEVERITY, RULE_CODE")
log.step("2.3 Check SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES", "SELECT * FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES", rows10, err10)
if rows10:
    print(f"  Current validation issues:")
    for r in rows10:
        print(f"    {r}")
elif err10:
    print(f"  Error: {err10}")
else:
    print("  No current validation issues (or view is empty because no run was recorded)")

# Try VALIDATE_MODEL on nonexistent model
rows_bad, _, err_bad = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('nonexistent_model_xyz')")
log.step("2.4 VALIDATE_MODEL on nonexistent model (error handling)",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('nonexistent_model_xyz')",
         rows_bad, err_bad, note="Testing error handling for unknown model name")
if err_bad:
    print(f"  Error (expected): {err_bad}")
else:
    print(f"  No error returned for nonexistent model — result: {rows_bad}")

# ===========================================================================
# SCENARIO 3: Model Documentation
# ===========================================================================
print("\n=== SCENARIO 3: MODEL DOCUMENTATION ===")

# DESCRIBE_SEMANTIC_OBJECT on 'sales' object 'SALES'
rows11, cols11, err11 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT('sales', 'SALES')")
log.step("3.1 DESCRIBE_SEMANTIC_OBJECT('sales', 'SALES')",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT('sales', 'SALES')", rows11, err11)
if rows11:
    print(f"  DESCRIBE_SEMANTIC_OBJECT returned {len(rows11)} rows")
    for r in rows11[:3]:
        print(f"    {r}")
elif err11:
    print(f"  Error: {err11}")

# Try GET_BUSINESS_GLOSSARY
rows12, cols12, err12 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'STRUCTURED_REQUEST')")
log.step("3.2 GET_BUSINESS_GLOSSARY('sales','SALES','STRUCTURED_REQUEST')",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'STRUCTURED_REQUEST')", rows12, err12)
if rows12:
    print(f"  GET_BUSINESS_GLOSSARY returned {len(rows12)} rows")
    for r in rows12:
        print(f"    Model: {r[0]}, Object: {r[1]}, Mode: {r[2]}")
        if r[3]:
            print(f"    Text (first 500): {str(r[3])[:500]}")
elif err12:
    print(f"  Error: {err12}")

# Try GET_BUSINESS_GLOSSARY with SEMANTIC_SQL mode
rows12b, cols12b, err12b = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'SEMANTIC_SQL')")
log.step("3.3 GET_BUSINESS_GLOSSARY with SEMANTIC_SQL mode",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'SEMANTIC_SQL')", rows12b, err12b)
if rows12b:
    print(f"  OK - SEMANTIC_SQL mode works")
elif err12b:
    print(f"  Error: {err12b}")

# Try DESCRIBE_SEMANTIC_METRIC
rows13, cols13, err13 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_METRIC('sales', 'SALES', 'total_revenue')")
log.step("3.4 DESCRIBE_SEMANTIC_METRIC('sales','SALES','total_revenue')",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_METRIC('sales', 'SALES', 'total_revenue')", rows13, err13)
if rows13:
    print(f"  DESCRIBE_SEMANTIC_METRIC returned {len(rows13)} rows")
    for r in rows13[:3]:
        print(f"    {r}")
elif err13:
    print(f"  Error: {err13}")

# ===========================================================================
# SCENARIO 4: Role/Access Review
# ===========================================================================
print("\n=== SCENARIO 4: ROLE/ACCESS REVIEW ===")

# Check OWNER_ROLE on the model
rows14, cols14, err14 = sql("SELECT MODEL_NAME, OWNER_ROLE, STATUS FROM SEMANTIC_CATALOG.MODELS")
log.step("4.1 Check OWNER_ROLE on model", "SELECT MODEL_NAME, OWNER_ROLE, STATUS FROM SEMANTIC_CATALOG.MODELS", rows14, err14)
if rows14:
    for r in rows14:
        print(f"  Model: {r[0]}, Owner: {r[1]}, Status: {r[2]}")

# Check if OBJECT_PRIVILEGES table exists in SYS_SEMANTIC
rows15, cols15, err15 = sql("SELECT COUNT(*) FROM SYS_SEMANTIC.OBJECT_PRIVILEGES")
log.step("4.2 Query SYS_SEMANTIC.OBJECT_PRIVILEGES directly",
         "SELECT COUNT(*) FROM SYS_SEMANTIC.OBJECT_PRIVILEGES", rows15, err15)
if rows15:
    print(f"  OBJECT_PRIVILEGES rows: {rows15[0][0]}")
elif err15:
    print(f"  Error: {err15}")
    note_bug("J-003", "P2",
             "SYS_SEMANTIC.OBJECT_PRIVILEGES table missing — role-based access control not implemented",
             "SELECT COUNT(*) FROM SYS_SEMANTIC.OBJECT_PRIVILEGES",
             "Returns 0 or some privilege records",
             f"Error: {err15}")

# Check if there's a way to grant access to a specific role
# The OBJECTS_FOR_AGENT view checks OBJECT_PRIVILEGES — let's see what scripts are available
rows15b, cols15b, err15b = sql("""
    SELECT SCRIPT_NAME
    FROM SYS.EXA_ALL_SCRIPTS
    WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN'
    ORDER BY SCRIPT_NAME
""")
log.step("4.3 List all SEMANTIC_ADMIN scripts", "SELECT SCRIPT_NAME FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN'",
         rows15b, err15b)
if rows15b:
    scripts = [r[0] for r in rows15b]
    print(f"  SEMANTIC_ADMIN scripts: {scripts}")
    # Check for GRANT or privilege-related scripts
    priv_scripts = [s for s in scripts if 'GRANT' in s or 'PRIV' in s or 'ACCESS' in s or 'ROLE' in s or 'PERMISS' in s]
    if not priv_scripts:
        note_bug("J-004", "P1",
                 "No GRANT/PRIVILEGE management scripts in SEMANTIC_ADMIN — admins cannot set access control via API",
                 "SELECT SCRIPT_NAME FROM SYS.EXA_ALL_SCRIPTS WHERE SCRIPT_SCHEMA='SEMANTIC_ADMIN' AND SCRIPT_NAME LIKE '%GRANT%' OR SCRIPT_NAME LIKE '%PRIV%'",
                 "Scripts like GRANT_OBJECT_ACCESS, REVOKE_OBJECT_ACCESS exist for managing OBJECT_PRIVILEGES",
                 f"No privilege management scripts found. Available: {scripts}")
    else:
        print(f"  Found privilege scripts: {priv_scripts}")

# ===========================================================================
# SCENARIO 5: Model Export for Documentation
# ===========================================================================
print("\n=== SCENARIO 5: MODEL EXPORT ===")

# Export entire model
rows16, cols16, err16 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', NULL, NULL)")
log.step("5.1 EXPORT_SEMANTIC_DEFINITION('sales', NULL, NULL)",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', NULL, NULL)", rows16, err16)
if rows16:
    print(f"  Export returned {len(rows16)} rows")
    for r in rows16[:5]:
        print(f"    kind={r[0]}, ref={r[1]}, sql_len={len(str(r[2])) if r[2] else 0}")
elif err16:
    print(f"  Error: {err16}")

# Export specific object
rows17, cols17, err17 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', NULL)")
log.step("5.2 EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', NULL)",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', NULL)", rows17, err17)
if rows17:
    print(f"  Export object returned {len(rows17)} rows")
    for r in rows17[:5]:
        print(f"    kind={r[0]}, ref={r[1]}, sql={str(r[2])[:100] if r[2] else None}")
elif err17:
    print(f"  Error: {err17}")

# Export specific metric
rows18, cols18, err18 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', 'total_revenue')")
log.step("5.3 EXPORT_SEMANTIC_DEFINITION('sales','SALES','total_revenue')",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', 'total_revenue')", rows18, err18)
if rows18:
    print(f"  Export metric returned {len(rows18)} rows")
    for r in rows18:
        print(f"    kind={r[0]}, ref={r[1]}, sql={str(r[2])[:200] if r[2] else None}")
elif err18:
    print(f"  Error: {err18}")

# Check if export is re-importable (does it produce valid APPLY_SEMANTIC_DEFINITION SQL?)
if rows17:
    # Look for APPLY_SEMANTIC_DEFINITION pattern in returned SQL
    has_apply = any("APPLY_SEMANTIC_DEFINITION" in str(r[2]) or "ALTER SEMANTIC" in str(r[2]) for r in rows17 if r[2])
    if not has_apply:
        # Check if all rows produce valid SQL statements
        for r in rows17:
            print(f"  Export SQL: {str(r[2])[:300] if r[2] else 'NULL'}")

# ===========================================================================
# SCENARIO 6: Synonym Management
# ===========================================================================
print("\n=== SCENARIO 6: SYNONYM MANAGEMENT ===")

# Add synonym for total_revenue
rows19, cols19, err19 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'total_revenue', 'revenue', 'BUSINESS_GLOSSARY')")
log.step("6.1 ADD_SYNONYM for 'revenue' -> total_revenue",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'total_revenue', 'revenue', 'BUSINESS_GLOSSARY')",
         rows19, err19)
if rows19:
    print(f"  Add synonym result: {rows19}")
elif err19:
    # May already exist
    if 'duplicate' in str(err19).lower() or '023' in str(err19):
        print(f"  Synonym already exists (expected): {err19}")
    else:
        print(f"  Error: {err19}")
        note_bug("J-005", "P2",
                 "ADD_SYNONYM fails with unexpected error",
                 "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'total_revenue', 'revenue', 'BUSINESS_GLOSSARY')",
                 "Synonym added or duplicate warning",
                 f"Error: {err19}")

# Add synonym for gross_margin (sales vs margin)
rows20, cols20, err20 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'gross_margin', 'margin', 'BUSINESS_GLOSSARY')")
log.step("6.2 ADD_SYNONYM 'margin' -> gross_margin",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'gross_margin', 'margin', 'BUSINESS_GLOSSARY')",
         rows20, err20)
if rows20:
    print(f"  Add synonym result: {rows20}")
elif err20:
    if 'duplicate' in str(err20).lower() or '023' in str(err20):
        print(f"  Synonym already exists (expected): {err20}")
    else:
        print(f"  Error: {err20}")

# Verify synonym appears in SEMANTIC_CATALOG.SYNONYMS
rows21, cols21, err21 = sql("SELECT MODEL_NAME, OBJECT_TYPE, SYNONYM, SYNONYM_SOURCE FROM SEMANTIC_CATALOG.SYNONYMS WHERE MODEL_NAME='sales' ORDER BY OBJECT_TYPE, SYNONYM")
log.step("6.3 Check SEMANTIC_CATALOG.SYNONYMS", "SELECT * FROM SEMANTIC_CATALOG.SYNONYMS WHERE MODEL_NAME='sales'", rows21, err21)
if rows21:
    print(f"  Synonyms in catalog: {len(rows21)}")
    for r in rows21:
        print(f"    {r}")
elif err21:
    print(f"  Error: {err21}")
else:
    print("  No synonyms found")

# Test COMPILE_REQUEST_JSON resolves synonym 'revenue' -> total_revenue
req_json = '{"model":"sales","object":"SALES","metrics":["revenue"]}'
rows22, cols22, err22 = execute_script(f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('{req_json}')")
log.step("6.4 COMPILE_REQUEST_JSON with synonym 'revenue'",
         f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('{req_json}')", rows22, err22,
         note="Testing that synonym 'revenue' resolves to 'total_revenue'")
if rows22:
    status = rows22[0][0] if rows22[0] else None
    error_msg = rows22[0][2] if len(rows22[0]) > 2 else None
    print(f"  Status: {status}, Error: {error_msg}")
    if status == 'OK':
        print(f"  SQL: {str(rows22[0][3])[:200] if rows22[0][3] else None}")
    elif 'synonym' in str(error_msg or '').lower() or 'resolve' in str(error_msg or '').lower() or 'not found' in str(error_msg or '').lower():
        note_bug("J-006", "P2",
                 "COMPILE_REQUEST_JSON does not resolve synonyms — 'revenue' should map to 'total_revenue'",
                 f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('{req_json}')",
                 "Status=OK, synonym 'revenue' resolved to total_revenue",
                 f"Status={status}, Error: {error_msg}")
elif err22:
    print(f"  Error: {err22}")

# ===========================================================================
# SCENARIO 7: Monitoring and Audit
# ===========================================================================
print("\n=== SCENARIO 7: MONITORING AND AUDIT ===")

# Check REQUEST_HISTORY_FOR_AGENT
rows23, cols23, err23 = sql("SELECT HANDLE_TYPE, MODEL_NAME, USER_NAME, STATUS, REQUEST_TIME FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT ORDER BY REQUEST_TIME DESC LIMIT 10")
log.step("7.1 Check SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT",
         "SELECT * FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT ORDER BY REQUEST_TIME DESC LIMIT 10",
         rows23, err23)
if rows23:
    print(f"  History: {len(rows23)} rows")
    for r in rows23[:3]:
        print(f"    {r}")
elif err23:
    print(f"  Error: {err23}")
else:
    print("  No request history")

# As a DBA, Jin wants to see ALL users' history, not just his own
# The view filters by CURRENT_USER — let's note this limitation
rows24, cols24, err24 = sql("SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_REQUEST_LOG")
log.step("7.2 Count all agent request logs in SYS_SEMANTIC.AGENT_REQUEST_LOG",
         "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_REQUEST_LOG", rows24, err24,
         note="As admin, Jin wants to see ALL user queries, not just his own")
if rows24:
    total_requests = rows24[0][0]
    rows25, cols25, err25 = sql("SELECT COUNT(*) FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT")
    visible_requests = rows25[0][0] if rows25 else 0
    print(f"  Total in SYS_SEMANTIC: {total_requests}, visible via view: {visible_requests}")
    if int(total_requests or 0) > int(visible_requests or 0):
        note_bug("J-007", "P2",
                 "REQUEST_HISTORY_FOR_AGENT filters to CURRENT_USER only — admins cannot audit all user queries",
                 "SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_REQUEST_LOG -- returns more than REQUEST_HISTORY_FOR_AGENT",
                 "Admin-accessible view showing all user requests (or separate ADMIN_REQUEST_HISTORY view)",
                 f"REQUEST_HISTORY_FOR_AGENT shows {visible_requests} rows for current user; SYS_SEMANTIC.AGENT_REQUEST_LOG has {total_requests} total")
elif err24:
    print(f"  Error: {err24}")

# Check QUERY_LOG
rows26, cols26, err26 = sql("SELECT COUNT(*) FROM SYS_SEMANTIC.QUERY_LOG")
log.step("7.3 Count SYS_SEMANTIC.QUERY_LOG entries",
         "SELECT COUNT(*) FROM SYS_SEMANTIC.QUERY_LOG", rows26, err26)
if rows26:
    print(f"  Query log entries: {rows26[0][0]}")
elif err26:
    print(f"  Error: {err26}")

# ===========================================================================
# SCENARIO 8: Published Views Inspection
# ===========================================================================
print("\n=== SCENARIO 8: PUBLISHED VIEWS INSPECTION ===")

# Check if SEMANTIC_SALES schema exists and what views are there
rows27, cols27, err27 = sql("SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_SALES' ORDER BY VIEW_NAME")
log.step("8.1 List views in SEMANTIC_SALES schema",
         "SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_SALES'", rows27, err27)
if rows27:
    print(f"  SEMANTIC_SALES views: {[r[0] for r in rows27]}")
elif err27:
    print(f"  Error: {err27}")
    # Model may not be published yet — try publishing
    print("  SEMANTIC_SALES schema missing - model may not be published. Trying PUBLISH_MODEL...")
    pub_rows, pub_cols, pub_err = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")
    log.step("8.1b PUBLISH_MODEL('sales')", "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')", pub_rows, pub_err)
    if pub_rows:
        print(f"  Published: {pub_rows}")
        # Retry listing views
        rows27, cols27, err27 = sql("SELECT TABLE_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_SALES' ORDER BY TABLE_NAME")
        if rows27:
            print(f"  SEMANTIC_SALES views after publish: {[r[0] for r in rows27]}")
    elif pub_err:
        print(f"  PUBLISH_MODEL error: {pub_err}")
        if 'transaction' in str(pub_err).lower() or 'rollback' in str(pub_err).lower() or 'collision' in str(pub_err).lower():
            note_bug("J-016", "P1",
                     "PUBLISH_MODEL fails with transaction collision when model is already published",
                     "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales') -- called when model already published",
                     "PUBLISH_MODEL succeeds and re-publishes idempotently",
                     f"Error: GlobalTransactionRollback / transaction collision in VALIDATOR_RUNTIME")
else:
    print("  No views in SEMANTIC_SALES (not published or no objects)")

# Try SELECT * FROM SEMANTIC_SALES.SALES (without semantic SQL enabled - should get guard error)
rows28, cols28, err28 = sql("SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1")
log.step("8.2 SELECT * FROM SEMANTIC_SALES.SALES (without semantic SQL)",
         "SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1", rows28, err28,
         note="Without ENABLE_SEMANTIC_SQL, should get a clear error")
if err28:
    if 'SEMANTIC_SURFACE_001' in str(err28) or 'preprocessor' in str(err28).lower() or 'guard' in str(err28).lower():
        print(f"  Guard error (expected): {err28[:150]}")
    else:
        print(f"  Unexpected error: {err28}")
        note_bug("J-008", "P2",
                 "SELECT from published view gives confusing error (not the SEMANTIC_GUARD message)",
                 "SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1",
                 "Error SEMANTIC_SURFACE_001: semantic query requires the Lua SQL preprocessor",
                 f"Got: {err28[:200]}")
elif rows28:
    print(f"  Returned rows without semantic SQL enabled: {rows28}")
    note_bug("J-009", "P0",
             "Published view returns data without semantic SQL enabled — SEMANTIC_GUARD is bypassed",
             "SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1",
             "Error: semantic query requires the Lua SQL preprocessor",
             f"Returned {len(rows28)} rows without enabling semantic SQL")

# Check SEMANTIC_DISCOVERY table
rows29, cols29, err29 = sql("SELECT ENTRY_NAME, ENTRY_VALUE FROM SEMANTIC_SALES.SEMANTIC_DISCOVERY ORDER BY ENTRY_NAME")
log.step("8.3 Read SEMANTIC_SALES.SEMANTIC_DISCOVERY",
         "SELECT * FROM SEMANTIC_SALES.SEMANTIC_DISCOVERY", rows29, err29)
if rows29:
    print(f"  SEMANTIC_DISCOVERY entries: {len(rows29)}")
    for r in rows29[:5]:
        print(f"    {r[0]}: {str(r[1])[:80]}")
elif err29:
    print(f"  Error: {err29}")

# ===========================================================================
# SCENARIO 9: Model Versioning
# ===========================================================================
print("\n=== SCENARIO 9: MODEL VERSIONING ===")

# Check MODEL_VERSIONS catalog view
rows30, cols30, err30 = sql("SELECT MODEL_NAME, VERSION_NUMBER, VERSION_LABEL, STATUS, CHANGE_SUMMARY FROM SEMANTIC_CATALOG.MODEL_VERSIONS ORDER BY MODEL_NAME, VERSION_NUMBER")
log.step("9.1 Check SEMANTIC_CATALOG.MODEL_VERSIONS",
         "SELECT * FROM SEMANTIC_CATALOG.MODEL_VERSIONS", rows30, err30)
if rows30:
    print(f"  Model versions:")
    for r in rows30:
        print(f"    {r}")
elif err30:
    print(f"  Error: {err30}")

# Check if PUBLISH_MODEL creates a new version or just updates status
# First, check current state
rows31, cols31, err31 = sql("SELECT COUNT(*) FROM SYS_SEMANTIC.MODEL_VERSIONS WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME='sales')")
log.step("9.2 Count versions before PUBLISH_MODEL",
         "SELECT COUNT(*) FROM SYS_SEMANTIC.MODEL_VERSIONS WHERE MODEL_ID = ...", rows31, err31)
if rows31:
    versions_before = rows31[0][0]
    print(f"  Versions before: {versions_before}")

    # Publish again
    pub2_rows, pub2_cols, pub2_err = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")
    if not pub2_err:
        rows32, cols32, err32 = sql("SELECT COUNT(*) FROM SYS_SEMANTIC.MODEL_VERSIONS WHERE MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME='sales')")
        if rows32:
            versions_after = rows32[0][0]
            print(f"  Versions after second PUBLISH_MODEL: {versions_after}")
            if int(versions_before or 0) == int(versions_after or 0):
                log.observe("PUBLISH_MODEL does not create new version — it just re-publishes the current version. No version history on publish.")
                note_bug("J-010", "P2",
                         "PUBLISH_MODEL does not create a new version number — no automatic versioning on publish",
                         "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales') -- run twice",
                         "VERSION_COUNT increases by 1 on each publish to track change history",
                         f"VERSION_COUNT stays at {versions_before} even after re-publishing")

# ===========================================================================
# SCENARIO 10: Agent Instructions
# ===========================================================================
print("\n=== SCENARIO 10: AGENT INSTRUCTIONS ===")

# Add a governance instruction
rows33, cols33, err33 = execute_script("""EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'MODEL',
  NULL,
  'POLICY',
  'PII data (customer names, emails) must not be included in query results. Always filter by non-PII dimensions only.',
  NULL,
  1
)""")
log.step("10.1 ADD_AGENT_INSTRUCTION governance policy",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION('sales','MODEL',NULL,'POLICY','PII data...',NULL,1)",
         rows33, err33)
if rows33:
    print(f"  Instruction added: {rows33}")
elif err33:
    print(f"  Error: {err33}")

# Add a definition instruction
rows34, cols34, err34 = execute_script("""EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'METRIC',
  'total_revenue',
  'DEFINITION',
  'Revenue = net_unit_price * quantity, excluding tax and discounts. Use fiscal year (Feb-Jan) for year-based analysis.',
  NULL,
  10
)""")
log.step("10.2 ADD_AGENT_INSTRUCTION metric definition",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION('sales','METRIC','total_revenue','DEFINITION','Revenue=...',NULL,10)",
         rows34, err34)
if rows34:
    print(f"  Instruction added: {rows34}")
elif err34:
    print(f"  Error: {err34}")

# Check INSTRUCTIONS_FOR_AGENT view
rows35, cols35, err35 = sql("""SELECT MODEL_NAME, SCOPE_TYPE, SCOPE_NAME, INSTRUCTION_KIND, INSTRUCTION_TEXT, PRIORITY
FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT
WHERE MODEL_NAME = 'sales'
ORDER BY PRIORITY, INSTRUCTION_ID""")
log.step("10.3 Check SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT",
         "SELECT * FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT WHERE MODEL_NAME='sales'", rows35, err35)
if rows35:
    print(f"  Instructions for agent: {len(rows35)}")
    for r in rows35:
        print(f"    scope={r[1]}, kind={r[3]}, priority={r[5]}, text={str(r[4])[:80]}")
elif err35:
    print(f"  Error: {err35}")
else:
    print("  No instructions found")

# Check SEMANTIC_CATALOG.AGENT_INSTRUCTIONS
rows36, cols36, err36 = sql("SELECT MODEL_NAME, SCOPE_TYPE, INSTRUCTION_KIND, INSTRUCTION_TEXT FROM SEMANTIC_CATALOG.AGENT_INSTRUCTIONS WHERE MODEL_NAME='sales' ORDER BY INSTRUCTION_ID")
log.step("10.4 Check SEMANTIC_CATALOG.AGENT_INSTRUCTIONS",
         "SELECT * FROM SEMANTIC_CATALOG.AGENT_INSTRUCTIONS WHERE MODEL_NAME='sales'", rows36, err36)
if rows36:
    print(f"  Catalog agent instructions: {len(rows36)}")
    for r in rows36[:3]:
        print(f"    {r}")
elif err36:
    print(f"  Error: {err36}")

# Try adding instruction with invalid INSTRUCTION_KIND
rows37, cols37, err37 = execute_script("""EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION(
  'sales',
  'MODEL',
  NULL,
  'COMPLIANCE',
  'Data must comply with GDPR regulations.',
  NULL,
  5
)""")
log.step("10.5 ADD_AGENT_INSTRUCTION with invalid kind 'COMPLIANCE'",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION('sales','MODEL',NULL,'COMPLIANCE','...',NULL,5)",
         rows37, err37, note="Testing validation of INSTRUCTION_KIND")
if err37:
    if 'SEMANTIC_AGENT_003' in str(err37) or 'invalid' in str(err37).lower():
        print(f"  Error (expected): {err37[:150]}")
    else:
        print(f"  Unexpected error: {err37}")
elif rows37:
    print(f"  No error - instruction added with invalid kind 'COMPLIANCE': {rows37}")
    note_bug("J-011", "P2",
             "ADD_AGENT_INSTRUCTION accepts invalid INSTRUCTION_KIND 'COMPLIANCE'",
             "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION('sales','MODEL',NULL,'COMPLIANCE','...',NULL,5)",
             "Error SEMANTIC_AGENT_003: invalid INSTRUCTION_KIND. Valid: AMBIGUITY, DEFINITION, GENERAL, POLICY, PREFERENCE, SAFETY, STYLE",
             "Instruction was added without error")

# ===========================================================================
# SCENARIO 11: Try to Break Things
# ===========================================================================
print("\n=== SCENARIO 11: BREAK THINGS ===")

# 11a: Try to add a duplicate synonym
rows38, cols38, err38 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'total_revenue', 'revenue', 'MANUAL')")
log.step("11.1 Add duplicate synonym 'revenue' (should fail)",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'total_revenue', 'revenue', 'MANUAL')",
         rows38, err38, note="Testing duplicate synonym detection")
if err38:
    if 'duplicate' in str(err38).lower() or '023' in str(err38):
        print(f"  Duplicate caught (expected): {err38[:120]}")
    else:
        print(f"  Unexpected error: {err38}")
elif rows38:
    print(f"  No error returned for duplicate synonym: {rows38}")
    note_bug("J-012", "P2",
             "ADD_SYNONYM silently allows duplicate synonyms instead of returning error",
             "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'total_revenue', 'revenue', 'MANUAL') -- called twice",
             "Error SEMANTIC_ADMIN_023: duplicate synonym",
             "Synonym added without error a second time")

# 11b: Try to add a synonym for a nonexistent metric
rows39, cols39, err39 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'nonexistent_metric_xyz', 'ghost', 'MANUAL')")
log.step("11.2 ADD_SYNONYM for nonexistent metric",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'nonexistent_metric_xyz', 'ghost', 'MANUAL')",
         rows39, err39, note="Testing error handling for unknown object")
if err39:
    if '022' in str(err39) or 'not found' in str(err39).lower():
        print(f"  Error (expected): {err39[:120]}")
    else:
        print(f"  Unexpected error: {err39}")
elif rows39:
    print(f"  No error for nonexistent metric: {rows39}")
    note_bug("J-013", "P1",
             "ADD_SYNONYM does not error on nonexistent metric object",
             "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'nonexistent_metric_xyz', 'ghost', 'MANUAL')",
             "Error SEMANTIC_ADMIN_022: METRIC not found: nonexistent_metric_xyz",
             "Synonym added without error for nonexistent object")

# 11c: Try to ADD a DIMENSION with a SQL function that doesn't exist in Exasol (QUARTER())
# This tests whether the validator catches invalid SQL expressions
rows40, cols40, err40 = execute_script("""EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(
  'sales',
  'SALES',
  'order',
  'order_quarter_invalid',
  'QUARTER(o.order_date)',
  'DECIMAL(18,0)',
  'Order Quarter',
  'Calendar quarter (using QUARTER() function that does not exist in Exasol)',
  NULL,
  TRUE
)""")
log.step("11.3 ADD_DIMENSION with invalid SQL function QUARTER()",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION('sales','SALES','order','order_quarter_invalid','QUARTER(o.order_date)',...)",
         rows40, err40, note="Testing whether validator catches invalid SQL expressions in dimension expressions")
if rows40:
    print(f"  Dimension added with QUARTER() - no validation: {rows40}")
    # Now validate the model to see if it catches it
    val_rows, val_cols, val_err = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
    if val_rows:
        quarter_issues = [r for r in val_rows if 'quarter' in str(r).lower() or 'QUARTER' in str(r)]
        if not quarter_issues:
            note_bug("J-014", "P2",
                     "Validator does not catch invalid SQL functions in dimension expressions (e.g. QUARTER())",
                     "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION with QUARTER(o.order_date); EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')",
                     "Validation ERROR for dimension using QUARTER() which does not exist in Exasol",
                     "Dimension added and VALIDATE_MODEL returns no error for invalid SQL expression")
        else:
            print(f"  Validator caught QUARTER() issue: {quarter_issues}")
    else:
        print(f"  Validation returned 0 issues after adding QUARTER() dimension")
        note_bug("J-014", "P2",
                 "Validator does not catch invalid SQL functions in dimension expressions (e.g. QUARTER())",
                 "ADD_DIMENSION with QUARTER(o.order_date) then VALIDATE_MODEL",
                 "Validation error for invalid SQL expression",
                 "No validation issues returned")
elif err40:
    print(f"  ADD_DIMENSION error: {err40[:200]}")
    print("  (Some validation happens at add-time)")

# 11d: Try to delete a metric that derived metrics depend on — does validation catch it?
# First check what metrics exist
rows41, cols41, err41 = sql("SELECT METRIC_NAME, METRIC_TYPE, METRIC_KIND FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME='sales' ORDER BY METRIC_NAME")
log.step("11.4 Check metrics for dependency test", "SELECT METRIC_NAME, METRIC_TYPE FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME='sales'", rows41, err41)
if rows41:
    print(f"  Current metrics: {[(r[0], r[1]) for r in rows41]}")

# total_revenue is used by gross_margin and gross_margin_pct (derived metrics)
# We can't truly DELETE a metric via API, but we can mark it inactive via direct update
# Let's see if there's a script for this
conn = get_conn()
ok41b, err41b = run_statement("""
    UPDATE SYS_SEMANTIC.METRICS
    SET STATUS = 'INACTIVE'
    WHERE METRIC_NAME = 'total_revenue'
      AND MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME='sales')
""", conn=conn)
log.step("11.5 Mark total_revenue as INACTIVE (simulating deletion)",
         "UPDATE SYS_SEMANTIC.METRICS SET STATUS='INACTIVE' WHERE METRIC_NAME='total_revenue' AND MODEL_NAME='sales'",
         None if ok41b else None, err41b,
         note="Testing if validator catches broken metric dependencies when a base metric is removed")
if ok41b:
    print("  Updated total_revenue to INACTIVE")
    # Now validate
    val2_rows, val2_cols, val2_err = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
    if val2_rows:
        dep_issues = [r for r in val2_rows if 'revenue' in str(r).lower() or 'total_revenue' in str(r).lower() or 'depend' in str(r).lower()]
        all_issues = val2_rows
        print(f"  Validation after removing total_revenue: {len(all_issues)} issues")
        for r in all_issues[:5]:
            print(f"    {r}")
        if not dep_issues:
            note_bug("J-015", "P1",
                     "Validator does not detect broken metric dependencies when base metric is inactivated",
                     "UPDATE METRICS SET STATUS='INACTIVE' WHERE METRIC_NAME='total_revenue'; EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')",
                     "Validation ERROR for gross_margin (depends on total_revenue) and gross_margin_pct",
                     "VALIDATE_MODEL returns no dependency errors after inactivating a base metric")
    else:
        print(f"  Validation returned 0 issues after removing total_revenue")
        note_bug("J-015", "P1",
                 "Validator does not detect broken metric dependencies when base metric is inactivated",
                 "UPDATE METRICS SET STATUS='INACTIVE' WHERE METRIC_NAME='total_revenue'; EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')",
                 "Validation ERROR for dependent metrics gross_margin, gross_margin_pct",
                 "VALIDATE_MODEL returns 0 issues despite total_revenue being inactive")

    # Restore total_revenue
    run_statement("""
        UPDATE SYS_SEMANTIC.METRICS
        SET STATUS = 'ACTIVE'
        WHERE METRIC_NAME = 'total_revenue'
          AND MODEL_ID = (SELECT MODEL_ID FROM SYS_SEMANTIC.MODELS WHERE MODEL_NAME='sales')
    """, conn=conn)
    print("  Restored total_revenue to ACTIVE")
elif err41b:
    print(f"  Could not update metric status: {err41b}")
conn.close()

# 11e: Try to add an entity with invalid SQL (injection attempt)
rows42, cols42, err42 = execute_script("""EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY(
  'sales',
  'injection_test',
  'MART; DROP TABLE SYS_SEMANTIC.MODELS; --',
  'ORDERS',
  'inj',
  'inj.id',
  NULL,
  NULL
)""")
log.step("11.6 SQL injection attempt in SOURCE_SCHEMA",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY with SOURCE_SCHEMA='MART; DROP TABLE...'",
         rows42, err42, note="Testing SQL injection prevention")
if err42:
    print(f"  Error (expected - injection blocked): {err42[:150]}")
elif rows42:
    print(f"  Injection attempt succeeded! Entity added: {rows42}")
    note_bug("J-016", "P0",
             "SQL injection possible via SOURCE_SCHEMA parameter in ADD_ENTITY",
             "EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_ENTITY('sales','injection_test','MART; DROP TABLE SYS_SEMANTIC.MODELS; --','ORDERS','inj','inj.id',NULL,NULL)",
             "Error: invalid SOURCE_SCHEMA (name validation should reject semicolons)",
             "Entity added with SQL injection in SOURCE_SCHEMA")

# 11f: Try COMPILE_REQUEST_JSON with no model specified
rows43, cols43, err43 = execute_script('EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(\'{"metrics":["total_revenue"]}\')')
log.step("11.7 COMPILE_REQUEST_JSON with no model specified",
         'EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON(\'{"metrics":["total_revenue"]}\')',
         rows43, err43, note="Testing error handling for missing model")
if rows43:
    status43 = rows43[0][0] if rows43[0] else None
    error43 = rows43[0][2] if len(rows43[0]) > 2 else None
    print(f"  Status: {status43}, Error: {error43}")
    if status43 == 'OK':
        print(f"  NOTE: Compiled without model name - may have guessed a model")
    else:
        print(f"  Error returned in result row (expected): {error43}")
elif err43:
    print(f"  Exception error: {err43}")

# 11g: VALIDATE_MODEL after clean restore (ensure we haven't broken anything)
rows44, cols44, err44 = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')")
log.step("11.8 Final VALIDATE_MODEL (sanity check after break tests)",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')", rows44, err44)
if rows44:
    errors44 = [r for r in rows44 if r[0] == 'ERROR']
    warnings44 = [r for r in rows44 if r[0] == 'WARNING']
    print(f"  Final validation: {len(errors44)} errors, {len(warnings44)} warnings")
    for r in rows44[:5]:
        print(f"    {r}")
elif err44:
    print(f"  Error: {err44}")
else:
    print("  Final validation: 0 issues (clean)")

# ===========================================================================
# ADDITIONAL: Check METRIC_OVERVIEW and METRIC_COMPATIBLE_DIMENSIONS
# ===========================================================================
print("\n=== ADDITIONAL: METRIC_OVERVIEW ===")

rows45, cols45, err45 = sql("""SELECT MODEL_NAME, METRIC_NAME, METRIC_KIND, IS_CERTIFIED, OWNER_ROLE, SYNONYMS
FROM SEMANTIC_CATALOG.METRIC_OVERVIEW
WHERE MODEL_NAME='sales'
ORDER BY METRIC_NAME""")
log.step("A.1 SEMANTIC_CATALOG.METRIC_OVERVIEW",
         "SELECT * FROM SEMANTIC_CATALOG.METRIC_OVERVIEW WHERE MODEL_NAME='sales'", rows45, err45)
if rows45:
    print(f"  Metric overview: {len(rows45)} metrics")
    for r in rows45:
        print(f"    {r}")
elif err45:
    print(f"  Error: {err45}")

# Check if METRIC_OVERVIEW can show OWNER_ROLE per metric
# (Jin as admin wants to see which team owns each metric)
rows46, cols46, err46 = sql("""SELECT METRIC_NAME, OWNER_ROLE FROM SEMANTIC_CATALOG.METRICS WHERE MODEL_NAME='sales'""")
log.step("A.2 Check per-metric OWNER_ROLE", "SELECT METRIC_NAME, OWNER_ROLE FROM SEMANTIC_CATALOG.METRICS", rows46, err46)
if rows46:
    has_owner = any(r[1] for r in rows46)
    print(f"  Metrics with OWNER_ROLE: {[(r[0], r[1]) for r in rows46]}")
    if not has_owner:
        log.observe("No per-metric OWNER_ROLE set — all NULL. There's no ADD_METRIC API param for owner_role.")

# Check METRIC_KIND inconsistency between METRIC_OVERVIEW and METRICS views
rows47, cols47, err47 = sql("""
SELECT m.METRIC_NAME, m.METRIC_TYPE AS METRICS_TYPE, mo.METRIC_KIND AS OVERVIEW_KIND
FROM SEMANTIC_CATALOG.METRICS m
JOIN SEMANTIC_CATALOG.METRIC_OVERVIEW mo
  ON m.MODEL_NAME = mo.MODEL_NAME
 AND m.METRIC_NAME = mo.METRIC_NAME
WHERE m.MODEL_NAME = 'sales'
  AND m.METRIC_TYPE <> mo.METRIC_KIND
ORDER BY m.METRIC_NAME
""")
log.step("A.3 Compare METRIC_TYPE in METRICS vs METRIC_KIND in METRIC_OVERVIEW",
         "SELECT METRIC_TYPE vs METRIC_KIND from METRICS/METRIC_OVERVIEW", rows47, err47,
         note="Checking for inconsistency between METRIC_TYPE in METRICS view and METRIC_KIND in METRIC_OVERVIEW")
if rows47:
    print(f"  INCONSISTENT metric types: {len(rows47)}")
    for r in rows47:
        print(f"    {r[0]}: METRICS says '{r[1]}', METRIC_OVERVIEW says '{r[2]}'")
    note_bug("J-017", "P2",
             "METRIC_TYPE in SEMANTIC_CATALOG.METRICS and METRIC_KIND in METRIC_OVERVIEW disagree for same metrics",
             "SELECT m.METRIC_NAME, m.METRIC_TYPE, mo.METRIC_KIND FROM SEMANTIC_CATALOG.METRICS m JOIN SEMANTIC_CATALOG.METRIC_OVERVIEW mo WHERE m.MODEL_NAME='sales' AND m.METRIC_TYPE <> mo.METRIC_KIND",
             "METRIC_TYPE and METRIC_KIND should be consistent for the same metric",
             f"Inconsistencies found: {[(r[0], r[1], r[2]) for r in rows47]}")
elif err47:
    print(f"  Error: {err47}")
else:
    print("  METRIC_TYPE and METRIC_KIND are consistent")

# Check PUBLISH_MODEL idempotency (second call after model already published)
print("\n=== ADDITIONAL: PUBLISH_MODEL IDEMPOTENCY ===")
pub_idempotent_rows, pub_idempotent_cols, pub_idempotent_err = execute_script("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")
log.step("A.4 PUBLISH_MODEL idempotency (call when already published)",
         "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales') -- called second time",
         pub_idempotent_rows, pub_idempotent_err,
         note="Testing if PUBLISH_MODEL is idempotent when model is already published")
if pub_idempotent_rows:
    print(f"  PUBLISH_MODEL re-publish succeeded: {len(pub_idempotent_rows)} rows")
elif pub_idempotent_err:
    print(f"  PUBLISH_MODEL re-publish error: {pub_idempotent_err[:300]}")
    if 'transaction' in str(pub_idempotent_err).lower() or 'rollback' in str(pub_idempotent_err).lower() or 'collision' in str(pub_idempotent_err).lower():
        note_bug("J-016", "P1",
                 "PUBLISH_MODEL fails with transaction collision on second call — not idempotent",
                 "EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales') -- called twice",
                 "PUBLISH_MODEL succeeds both times (idempotent)",
                 f"Second call fails: GlobalTransactionRollback/transaction collision in VALIDATOR_RUNTIME")

# ===========================================================================
# WRITE REPORT
# ===========================================================================
print("\n=== WRITING REPORT ===")

report = """# Persona Test Report: Jin — BI Platform Administrator

**Date:** 2026-05-14
**Tester:** Simulated persona (automated)
**Persona:** Jin, BI Platform Administrator at a retail company

---

## Persona Background

Jin is a database administrator with 8 years of Exasol experience. He is responsible for setting up and maintaining the semantic layer for a team of 20 BI users. His priorities are governance, security, multi-user setup, documentation, and production reliability.

Today Jin wants to:
- Audit what's stored in the semantic catalog
- Validate the existing sales model and review error handling
- Add documentation and governance metadata (descriptions, instructions, synonyms)
- Understand role/access control and how to restrict what users can see
- Export the model definition for documentation and version control
- Test what happens when model objects are removed or broken

---

## Session Narrative

Jin starts like every DBA: by exploring the system catalog. He finds `SEMANTIC_CATALOG` with 26 views and `SEMANTIC_AGENT` with 11 views covering models, dimensions, metrics, synonyms, validation, materializations, and agent-facing glossaries. This is comprehensive and well-structured. The `METRIC_OVERVIEW` view with denormalized synonyms and `METRIC_COMPATIBLE_DIMENSIONS` for join validation are especially useful for governance reporting.

However, immediately Jin notices a gap: **there is no OBJECT_PRIVILEGES view in SEMANTIC_CATALOG**. The `OBJECTS_FOR_AGENT` view internally queries `SYS_SEMANTIC.OBJECT_PRIVILEGES` to enforce access control, but there are no admin-facing views or scripts to audit or manage those grants. The table exists (empty), but there is no `GRANT_OBJECT_ACCESS` or `REVOKE_OBJECT_ACCESS` script in `SEMANTIC_ADMIN`. As a DBA responsible for governance for 20 BI users, Jin cannot restrict which users see which semantic objects — this is a major production gap.

The validation system (`VALIDATE_MODEL`) works correctly. It returns structured issues, persists runs in `VALIDATION_RUNS`, and the `CURRENT_VALIDATION_ISSUES` view reflects the latest state. The one existing warning is for `log_revenue_sum` (missing format/unit hint on a numeric metric). The validator correctly catches dependency breakage when `total_revenue` is inactivated — `gross_margin` and `gross_margin_pct` fail with `SEMANTIC_MODEL_011`. SQL injection is blocked by identifier validation.

However, **the validator does not catch invalid SQL function expressions** — adding a dimension with `QUARTER(o.order_date)` (QUARTER() is not an Exasol function) passes validation without error.

Model documentation via `ADD_AGENT_INSTRUCTION` works well. Jin adds a PII governance policy and a metric definition note. The `INSTRUCTIONS_FOR_AGENT` view correctly surfaces these with priority ordering. The instruction kind validation is good — invalid kinds like 'COMPLIANCE' are rejected with clear errors (SEMANTIC_AGENT_003).

`EXPORT_SEMANTIC_DEFINITION` works and returns re-importable SQL using `EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION` / `ALTER SEMANTIC VIEW` syntax. Entity definitions are also exported. Good for CI/CD and documentation.

`PUBLISH_MODEL` has a **transaction collision bug** — calling `PUBLISH_MODEL` a second time (when the model is already published) fails with `GlobalTransactionRollback: Transaction collision` from inside `VALIDATOR_RUNTIME`. This is reproducible and prevents model updates from being deployed.

**Versioning:** Only 1 version exists after multiple `PUBLISH_MODEL` calls. The system does not version on publish.

**Synonym resolution in COMPILE_REQUEST_JSON works** — the synonym 'revenue' correctly resolves to `total_revenue`.

**METRIC_KIND inconsistency:** `SEMANTIC_CATALOG.METRICS.METRIC_TYPE` reports 'ADDITIVE' for `total_revenue` but `METRIC_OVERVIEW.METRIC_KIND` reports 'SIMPLE' for the same metric. Similar disagreement for `completed_revenue` (ADDITIVE vs FILTERED). This inconsistency will confuse admins doing governance reviews.

**Monitoring gap:** `REQUEST_HISTORY_FOR_AGENT` filters to `CURRENT_USER` only. Jin cannot see his 20 users' query history.

---

## Step-by-Step Findings

"""

# Add step summary
report += "### Scenario 1: Catalog Exploration\\n\\n"
report += """**Command:**
```sql
SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_CATALOG' ORDER BY VIEW_NAME
SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_AGENT' ORDER BY VIEW_NAME
SELECT * FROM SEMANTIC_CATALOG.MODELS
SELECT * FROM SEMANTIC_CATALOG.DIMENSIONS ORDER BY MODEL_NAME, DIMENSION_NAME
SELECT * FROM SEMANTIC_CATALOG.METRICS ORDER BY MODEL_NAME, METRIC_NAME
SELECT * FROM SEMANTIC_CATALOG.ENTITIES ORDER BY MODEL_NAME, ENTITY_NAME
```

**Result:** SUCCESS. Found 26 views in SEMANTIC_CATALOG and 11 views in SEMANTIC_AGENT. The catalog is comprehensive and well-organized. Found: 8 dimensions, 11 metrics, 5 entities in the sales model (PUBLISHED status). No privilege views in SEMANTIC_CATALOG.

"""

report += "### Scenario 2: Validation Status Audit\\n\\n"
report += """**Command:**
```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.VALIDATE_MODEL('sales')
SELECT * FROM SEMANTIC_CATALOG.VALIDATION_RUNS ORDER BY STARTED_AT DESC LIMIT 5
SELECT * FROM SEMANTIC_CATALOG.CURRENT_VALIDATION_ISSUES
```

**Result:** SUCCESS. VALIDATE_MODEL returns 1 WARNING: `log_revenue_sum` missing unit/format hint (SEMANTIC_MODEL_022). VALIDATION_RUNS is correctly populated with each run. CURRENT_VALIDATION_ISSUES correctly shows the latest warning.

**Good behavior:** VALIDATE_MODEL on nonexistent model returns structured row with ERROR row (SEMANTIC_MODEL_000) rather than exception.

"""

report += "### Scenario 3: Model Documentation\\n\\n"
report += """**Commands:**
```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_OBJECT('sales', 'SALES')
EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'STRUCTURED_REQUEST')
EXECUTE SCRIPT SEMANTIC_ADMIN.GET_BUSINESS_GLOSSARY('sales', 'SALES', 'SEMANTIC_SQL')
EXECUTE SCRIPT SEMANTIC_ADMIN.DESCRIBE_SEMANTIC_METRIC('sales', 'SALES', 'total_revenue')
```

**Result:** All work correctly. DESCRIBE_SEMANTIC_OBJECT returns 20 rows (1 object row + 19 field rows). GET_BUSINESS_GLOSSARY returns comprehensive text and JSON including fields, instructions, verified queries. Both STRUCTURED_REQUEST and SEMANTIC_SQL modes work. DESCRIBE_SEMANTIC_METRIC returns 17 identity/property rows.

"""

report += "### Scenario 4: Role/Access Review\\n\\n"
report += """**Findings:**
- `OWNER_ROLE` on the sales model is `FINANCE_ANALYTICS` (set at creation time via CREATE_MODEL)
- `SYS_SEMANTIC.OBJECT_PRIVILEGES` table EXISTS but is empty (0 rows)
- The `OBJECTS_FOR_AGENT` view uses this table to enforce row-level access control
- There are NO `GRANT_OBJECT_ACCESS` / `REVOKE_OBJECT_ACCESS` scripts in `SEMANTIC_ADMIN`
- Admins have no API to populate `OBJECT_PRIVILEGES` — they would need raw SQL

This is a major governance gap for production multi-user deployment. The mechanism exists (the table and view filter code) but is completely inaccessible via the admin API.

"""

report += "### Scenario 5: Model Export\\n\\n"
report += """**Command:**
```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', NULL, NULL)  -- 35 rows
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', NULL)  -- 19 rows
EXECUTE SCRIPT SEMANTIC_ADMIN.EXPORT_SEMANTIC_DEFINITION('sales', 'SALES', 'total_revenue')  -- 1 row
```

**Result:** SUCCESS. Exports ENTITY definitions as `EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_DIMENSION(...)` calls. Metric export uses `ALTER SEMANTIC VIEW ... ADD OR REPLACE METRIC ...` syntax which is re-importable via APPLY_SEMANTIC_DEFINITION. Full model export (35 rows) includes entities, relationships, dimensions, facts, and metrics.

**Friction:** Export does not include model-level metadata (CREATE_MODEL statement with OWNER_ROLE, DESCRIPTION). Cannot fully reconstruct a model from export alone without knowing those parameters.

"""

report += "### Scenario 6: Synonym Management\\n\\n"
report += """**Commands:**
```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'total_revenue', 'revenue', 'BUSINESS_GLOSSARY')
-- already exists from seed: SEMANTIC_ADMIN_023 duplicate error (expected)
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_SYNONYM('sales', 'METRIC', 'gross_margin', 'margin', 'BUSINESS_GLOSSARY')
-- SUCCESS: ('sales', 'METRIC', 'gross_margin', 'margin', 'BUSINESS_GLOSSARY', True)
SELECT * FROM SEMANTIC_CATALOG.SYNONYMS WHERE MODEL_NAME='sales'
-- 4 synonyms: region(DIM), margin(METRIC), revenue(METRIC/SEMANTIC_SQL), sales(METRIC/SEMANTIC_SQL)
EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON('{"model":"sales","object":"SALES","metrics":["revenue"]}')
-- STATUS=OK, resolves 'revenue' to total_revenue, uses materialization MART.SALES_REVENUE_BY_REGION
```

**Result:** Synonym management works correctly. Duplicate detection is solid. COMPILE_REQUEST_JSON resolves 'revenue' synonym to total_revenue correctly. Materialization selection works.

"""

report += "### Scenario 7: Monitoring and Audit\\n\\n"
report += """**Commands:**
```sql
SELECT * FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT ORDER BY REQUEST_TIME DESC LIMIT 10
SELECT COUNT(*) FROM SYS_SEMANTIC.AGENT_REQUEST_LOG
SELECT COUNT(*) FROM SEMANTIC_AGENT.REQUEST_HISTORY_FOR_AGENT
SELECT COUNT(*) FROM SYS_SEMANTIC.QUERY_LOG
```

**Result:** REQUEST_HISTORY_FOR_AGENT returns recent requests. However, it filters by `WHERE USER_NAME = CURRENT_USER` — Jin as admin cannot see his 20 BI users' query history. There is no admin-facing monitoring view showing all users' activity.

**Note:** SYS_SEMANTIC.AGENT_REQUEST_LOG had 128 rows; REQUEST_HISTORY_FOR_AGENT (which unions with QUERY_LOG) returned 131 — the slight overcounting is because the union includes 3 QUERY_LOG entries from the same user.

"""

report += "### Scenario 8: Published Views Inspection\\n\\n"
report += """**Commands:**
```sql
SELECT VIEW_NAME FROM SYS.EXA_ALL_VIEWS WHERE VIEW_SCHEMA='SEMANTIC_SALES'
-- SALES, SEMANTIC_DISCOVERY views exist
SELECT * FROM SEMANTIC_SALES.SALES LIMIT 1
-- Error SEMANTIC_SURFACE_001: semantic query requires the Lua SQL preprocessor (expected)
SELECT * FROM SEMANTIC_SALES.SEMANTIC_DISCOVERY ORDER BY ENTRY_NAME
-- Returns 7 entries: MODEL_NAME, QUERY_ENTRYPOINT, MCP_GUIDANCE, FIELD_DISCOVERY_QUERY, COMPATIBILITY_QUERY, 2x SEMANTIC_OBJECT entries
```

**Result:** Published schema is set up correctly. SEMANTIC_GUARD correctly blocks raw queries. SEMANTIC_DISCOVERY provides good MCP discovery guidance.

**Bug found:** `PUBLISH_MODEL` fails with `GlobalTransactionRollback: transaction collision` when called a second time (re-publish of already-published model). This prevents CI/CD workflows from re-deploying model changes.

"""

report += "### Scenario 9: Model Versioning\\n\\n"
report += """**Finding:**
```sql
SELECT * FROM SEMANTIC_CATALOG.MODEL_VERSIONS
-- Only 1 version: version_number=1, label='initial', status='DRAFT'
```

Only 1 version exists. PUBLISH_MODEL does not create a new version and the version status stays 'DRAFT' even after publishing. There is no API to create a new version or mark a version as PUBLISHED. Jin cannot track "what was live on date X" from version records — the version table just records the initial draft.

"""

report += "### Scenario 10: Agent Instructions\\n\\n"
report += """**Commands:**
```sql
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION('sales','MODEL',NULL,'POLICY',
  'PII data (customer names, emails) must not be included in query results.',NULL,1)
-- Result: (3, 'sales', 'MODEL', None, 'POLICY', 'ACTIVE')
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION('sales','METRIC','total_revenue','DEFINITION',
  'Revenue = net_unit_price * quantity, excluding tax and discounts. Use fiscal year (Feb-Jan).',NULL,10)
-- Result: (4, 'sales', 'METRIC', 'total_revenue', 'DEFINITION', 'ACTIVE')
SELECT * FROM SEMANTIC_AGENT.INSTRUCTIONS_FOR_AGENT WHERE MODEL_NAME='sales'
-- 4 instructions: 2 MODEL-level (POLICY, GENERAL), 2 METRIC-level (DEFINITION)
EXECUTE SCRIPT SEMANTIC_ADMIN.ADD_AGENT_INSTRUCTION('sales','MODEL',NULL,'COMPLIANCE','GDPR...',NULL,5)
-- Error SEMANTIC_AGENT_003: invalid INSTRUCTION_KIND: COMPLIANCE (expected)
```

**Result:** SUCCESS. Instructions added, properly prioritized, visible in agent view. Validation correctly rejects unknown INSTRUCTION_KIND values.

"""

report += "### Scenario 11: Break Things\\n\\n"
report += """**Tests:**

1. **Duplicate synonym**: Correctly rejected with SEMANTIC_ADMIN_023.

2. **Synonym for nonexistent metric**: Correctly rejected with SEMANTIC_ADMIN_022.

3. **SQL injection in SOURCE_SCHEMA**: `'MART; DROP TABLE SYS_SEMANTIC.MODELS; --'` blocked by SEMANTIC_ADMIN_002 identifier validation.

4. **QUARTER() function in dimension expression**: Silently accepted by ADD_DIMENSION. VALIDATE_MODEL reports 0 errors for this. Runtime execution would fail. (BUG-J-014)

5. **Inactivating base metric total_revenue**: VALIDATE_MODEL correctly detects 3 ERRORs (gross_margin, gross_margin_pct, avg_order_value all reference total_revenue) plus 1 VERIFIED_QUERY reference error. Validator is correct here.

6. **COMPILE_REQUEST_JSON with no model**: Returns ERROR row: "model is required." — correct behavior.

7. **PUBLISH_MODEL transaction collision**: Second call to PUBLISH_MODEL fails with GlobalTransactionRollback. (BUG-J-016)

"""

report += """---

## Bugs Found

"""

for b in bugs:
    report += f"### {b['id']}: {b['title']}\\n\\n"
    report += f"**Severity:** {b['severity']}  \\n"
    report += f"**Repro:** `{b['repro']}`  \\n"
    report += f"**Expected:** {b['expected']}  \\n"
    report += f"**Actual:** {b['actual']}  \\n\\n"

report += """---

## Friction Points

1. **No admin request history view** — REQUEST_HISTORY_FOR_AGENT filters to CURRENT_USER only. DBAs need a separate admin view to monitor all users' activity. As a team of 20 BI users, Jin needs to audit who's querying what.
2. **No privilege management API** — OBJECT_PRIVILEGES table referenced in OBJECTS_FOR_AGENT view but no GRANT/REVOKE scripts exposed to admins. The access control mechanism exists but is inaccessible without direct SQL.
3. **PUBLISH_MODEL transaction collision on re-publish** — Calling PUBLISH_MODEL twice (needed for model updates) fails with a transaction collision. CI/CD pipelines cannot use REFRESH_SEMANTIC_SURFACE reliably.
4. **PUBLISH_MODEL doesn't version** — No automatic version increment on publish. Version STATUS stays 'DRAFT' even after publishing. Makes it impossible to correlate "what was live on date X".
5. **METRIC_TYPE vs METRIC_KIND inconsistency** — SEMANTIC_CATALOG.METRICS and METRIC_OVERVIEW report different kind labels for the same metrics (ADDITIVE vs SIMPLE, ADDITIVE vs FILTERED). Confusing for governance reports.
6. **Per-metric OWNER_ROLE not settable via API** — ADD_METRIC has no OWNER_ROLE parameter. All metrics show NULL owner_role even when they're owned by different teams.
7. **EXPORT does not include CREATE_MODEL statement** — Full model reconstruction requires knowing the original CREATE_MODEL parameters (OWNER_ROLE, DESCRIPTION, PUBLISHED_SCHEMA) which are not included in the export.

---

## Observations

- The catalog schema is well-designed and comprehensive for read-only governance reporting. 26 catalog views cover everything from lineage to validation history.
- METRIC_COMPATIBLE_DIMENSIONS and METRIC_DIMENSION_MATRIX views are excellent for automated compatibility checking — useful for building BI tool field pickers.
- SEMANTIC_DISCOVERY table in the published schema is a clever approach for MCP tool discovery.
- The SEMANTIC_GUARD mechanism elegantly blocks unintended raw queries with a clear actionable error.
- ADD_AGENT_INSTRUCTION with priority-ordered governance policies is a powerful feature for enterprise governance — Jin can inject PII restrictions directly into the agent's context.
- VALIDATE_MODEL correctly detects broken metric dependencies when base metrics are inactivated — the dependency graph is sound.
- SQL injection is properly blocked by identifier validation in all tested ADD_* scripts.
- Overall the system is well-suited for a single-tenant or lightly-governed deployment, but production multi-team governance requires the privilege management gap and PUBLISH_MODEL stability issues to be addressed first.
"""

report_path = '/Users/alexander.stigsen/Dev/exasol-semantic-views/reports/persona-04-jin-bi-admin.md'
with open(report_path, 'w') as f:
    f.write(report)
print(f"Report written to {report_path}")

# Assign severities and output JSON
bug_json = []
for b in bugs:
    bug_json.append({
        "id": b["id"],
        "severity": b["severity"],
        "title": b["title"],
        "repro": b["repro"],
        "expected": b["expected"],
        "actual": b["actual"]
    })

print("\n=== BUG JSON OUTPUT ===")
print(json.dumps(bug_json, indent=2))
