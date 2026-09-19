#!/usr/bin/env python3
"""Verify BUG-D-002 fix: server-side compile cache.

Asserts:
1. Identical repeated COMPILE_REQUEST_JSON calls return the same GENERATED_SQL
   and are flagged CACHE_HIT=TRUE in AGENT_REQUEST_LOG after the first miss.
2. Cache hits are materially faster than misses.
3. Requests that differ only in `client` / `purpose` share the cache (those
   fields are logging metadata, not compile inputs).
4. PUBLISH_MODEL invalidates the cache for that model_version.
5. SET_MATERIALIZATION_STATUS invalidates the cache (materialization choice
   changes mean cached compile output is no longer correct).
6. Distinct requests do not collide on the cache key.
7. The deployed runtime carries a build stamp, both compiling runtimes agree on
   it, and it matches what the current Lua sources hash to -- so a cached
   statement cannot outlive the compiler that produced it. Before this, a parser
   change that left PLAN_VERSION alone kept serving the previous runtime's SQL.
"""

from __future__ import annotations

import importlib.util
import json
import os
import re
import ssl
import sys
import time
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]


def connect():
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required.", file=sys.stderr)
        raise SystemExit(2)
    host = os.environ.get("EXASOL_HOST", "localhost")
    port = os.environ.get("EXASOL_PORT", "8563")
    return pyexasol.connect(
        dsn=f"{host}:{port}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )


def sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def scalar(con, sql: str) -> Any:
    rows = con.execute(sql).fetchall()
    return rows[0][0] if rows else None


def compile_request(con, request: dict[str, Any]) -> dict[str, Any]:
    payload = json.dumps(request, separators=(",", ":"))
    started = time.perf_counter()
    rows = con.execute(
        f"EXECUTE SCRIPT SEMANTIC_ADMIN.COMPILE_REQUEST_JSON({sql_string(payload)})"
    ).fetchall()
    elapsed = time.perf_counter() - started
    row = rows[0]
    return {
        "status": row[0],
        "error_code": row[1],
        "error_message": row[2],
        "generated_sql": row[4],
        "plan_json": row[5],
        "agent_request_id": row[8],
        "elapsed_ms": elapsed * 1000.0,
    }


def assert_equal(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok {name}: {actual!r}")


def assert_true(name: str, predicate: bool, detail: str = "") -> None:
    if not predicate:
        raise AssertionError(f"{name} failed{(' — ' + detail) if detail else ''}")
    print(f"ok {name}{(' — ' + detail) if detail else ''}")


def cache_hit_for(con, agent_request_id: int) -> bool:
    val = scalar(con, f"SELECT CACHE_HIT FROM SYS_SEMANTIC.AGENT_REQUEST_LOG WHERE AGENT_REQUEST_ID = {agent_request_id}")
    return bool(val)


def cache_count(con, model_name: str = "sales") -> int:
    val = scalar(con, f"""
        SELECT COUNT(*) FROM SYS_SEMANTIC.COMPILE_CACHE c
        JOIN SYS_SEMANTIC.MODELS m ON m.ACTIVE_VERSION_ID = c.MODEL_VERSION_ID
        WHERE UPPER(m.MODEL_NAME) = UPPER('{model_name}')
    """)
    return int(val or 0)


def deployed_build_stamp(con, script_name: str) -> str | None:
    text = scalar(con, "SELECT SCRIPT_TEXT FROM EXA_ALL_SCRIPTS "
                       "WHERE SCRIPT_SCHEMA = 'SEMANTIC_ADMIN' "
                       f"AND SCRIPT_NAME = {sql_string(script_name)}")
    if text is None:
        return None
    found = re.search(r'ESV_RUNTIME_BUILD = "([0-9a-f]+)"', str(text))
    return found.group(1) if found else None


def packaged_build_id() -> str:
    spec = importlib.util.spec_from_file_location(
        "package_lua_scripts", ROOT / "tools/package_lua_scripts.py")
    module = importlib.util.module_from_spec(spec)  # type: ignore[arg-type]
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module.runtime_build_id()


def main() -> None:
    con = connect()

    base_request = {
        "model": "sales",
        "object": "SALES",
        "metrics": ["total_revenue"],
        "dimensions": ["customer_region"],
        "client": "verify_compile_cache",
    }

    # Test 1: warm the cache, then a second identical call hits it.
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    miss = compile_request(con, base_request)
    assert_equal("first compile status", miss["status"], "OK")
    assert_equal("first compile cache_hit", cache_hit_for(con, miss["agent_request_id"]), False)

    hit = compile_request(con, base_request)
    assert_equal("second compile status", hit["status"], "OK")
    assert_equal("second compile cache_hit", cache_hit_for(con, hit["agent_request_id"]), True)
    assert_equal("cache hit returns identical SQL", hit["generated_sql"], miss["generated_sql"])
    assert_equal("cache hit returns identical plan", hit["plan_json"], miss["plan_json"])

    # Test 2: cache hit is faster than miss. Repeat several to smooth jitter.
    miss_times: list[float] = []
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    for i in range(3):
        miss_times.append(compile_request(con, {**base_request, "client": f"miss{i}"})["elapsed_ms"])
        con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    miss_avg = sum(miss_times) / len(miss_times)

    # Warm once, then time hits
    compile_request(con, base_request)
    hit_times: list[float] = []
    for i in range(5):
        hit_times.append(compile_request(con, base_request)["elapsed_ms"])
    hit_avg = sum(hit_times) / len(hit_times)

    assert_true("cache hit faster than miss",
                hit_avg < miss_avg,
                f"miss avg {miss_avg:.0f} ms, hit avg {hit_avg:.0f} ms")

    # Test 3: client/purpose differ but cache should still hit.
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    compile_request(con, {**base_request, "client": "alice"})
    metadata_only = compile_request(con, {**base_request, "client": "bob", "purpose": "demo"})
    assert_equal("metadata-only differences share cache",
                 cache_hit_for(con, metadata_only["agent_request_id"]), True)

    # Test 4: PUBLISH_MODEL invalidates the cache.
    before_publish = cache_count(con)
    assert_true("cache populated before publish", before_publish > 0,
                f"{before_publish} entries")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.PUBLISH_MODEL('sales')")
    after_publish = cache_count(con)
    assert_equal("PUBLISH_MODEL invalidated cache", after_publish, 0)

    # Test 5: SET_MATERIALIZATION_STATUS invalidates the cache.
    # Warm again with a request that picks the materialization.
    mat_request = {
        "model": "sales", "object": "SALES",
        "metrics": ["total_revenue"], "dimensions": ["customer_region"],
        "client": "mat_test",
    }
    compile_request(con, mat_request)  # warm
    after_warm = cache_count(con)
    assert_true("cache warmed before mat-status change", after_warm > 0,
                f"{after_warm} entries")
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MATERIALIZATION_STATUS('sales', 'sales_revenue_by_region', 'INACTIVE')")
    after_inactive = cache_count(con)
    assert_equal("SET_MATERIALIZATION_STATUS invalidated cache", after_inactive, 0)
    con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.SET_MATERIALIZATION_STATUS('sales', 'sales_revenue_by_region', 'ACTIVE')")

    # Test 6: distinct requests do not collide.
    con.execute("DELETE FROM SYS_SEMANTIC.COMPILE_CACHE")
    distinct_requests = [
        {**base_request, "metrics": ["total_revenue"]},
        {**base_request, "metrics": ["gross_margin"]},
        {**base_request, "metrics": ["total_revenue"], "dimensions": ["order_month"]},
        {**base_request, "metrics": ["total_revenue"], "limit": 10},
    ]
    sql_set: set[str] = set()
    for req in distinct_requests:
        result = compile_request(con, req)
        if result["status"] != "OK":
            print(f"  request {req} → {result['status']} {result['error_code']} {result['error_message']}")
            raise SystemExit(1)
        sql_set.add(result["generated_sql"])
    assert_equal("distinct requests produce distinct SQL", len(sql_set), len(distinct_requests))
    distinct_cache = cache_count(con)
    assert_equal("distinct requests fill distinct cache slots", distinct_cache, len(distinct_requests))

    # Test 7: the cache key is bound to the runtime that filled it.
    compiler_stamp = deployed_build_stamp(con, "COMPILER_RUNTIME")
    materialization_stamp = deployed_build_stamp(con, "MATERIALIZATION_RUNTIME")
    assert_true("COMPILER_RUNTIME carries a build stamp", compiler_stamp is not None)
    assert_equal("both compiling runtimes share one build", materialization_stamp, compiler_stamp)
    assert_equal("deployed runtime matches the packaged sources",
                 compiler_stamp, packaged_build_id())

    con.close()
    print(f"ok compile cache: miss avg {miss_avg:.0f} ms / hit avg {hit_avg:.0f} ms "
          f"({miss_avg / max(hit_avg, 1):.1f}x speedup), runtime build {compiler_stamp}")


if __name__ == "__main__":
    main()
