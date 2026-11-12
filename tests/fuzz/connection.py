"""Exasol connection and compile calls for live fuzz oracles."""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any

# pyexasol 3 reports usage on connect; a test run never does.
os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "true")


def _sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class ExasolBackend:
    """Own the live connection and its two semantic compiler entry points."""

    def __init__(self, connection: Any) -> None:
        self._connection = connection

    def execute(self, sql: str) -> Any:
        return self._connection.execute(sql)

    def close(self, disconnect: bool = True) -> None:
        self._connection.close(disconnect=disconnect)

    def _compile(self, script: str, argument: str) -> dict[str, Any]:
        row = self.execute(f"EXECUTE SCRIPT SEMANTIC_ADMIN.{script}({_sql_string(argument)})").fetchone()
        return {"status": row[0], "error_code": row[1], "error_message": row[2],
                "generated_sql": row[4]}

    def compile_json(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self._compile("COMPILE_REQUEST_JSON", json.dumps(payload))

    def compile_sql(self, sql: str) -> dict[str, Any]:
        return self._compile("COMPILE_SQL", sql)


def connect() -> ExasolBackend:
    try:
        import pyexasol  # type: ignore
    except ImportError:
        print("pyexasol is required for this host-side tool.", file=sys.stderr)
        raise SystemExit(2)

    connection = pyexasol.connect(
        dsn=f"{os.environ.get('EXASOL_HOST', 'localhost')}:{os.environ.get('EXASOL_PORT', '8563')}",
        user=os.environ.get("EXASOL_USER", "sys"),
        password=os.environ.get("EXASOL_PASSWORD", "exasol"),
        encryption=True,
        websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
    )
    return ExasolBackend(connection)
