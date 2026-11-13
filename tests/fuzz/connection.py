"""Exasol connection and compile calls for live fuzz oracles."""

from __future__ import annotations

import json
import os
import ssl
import sys
from typing import Any, Callable

# pyexasol 3 reports usage on connect; a test run never does.
os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "true")


def _sql_string(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


class ExasolBackend:
    """Own the live connection and its two semantic compiler entry points."""

    def __init__(self, connection: Any, preprocessor_factory: Callable[[], Any] | None = None) -> None:
        self._connection = connection
        self._preprocessor_factory = preprocessor_factory
        self._preprocessor_connection: Any = None

    def execute(self, sql: str) -> Any:
        return self._connection.execute(sql)

    def close(self, disconnect: bool = True) -> None:
        if self._preprocessor_connection is not None:
            self._preprocessor_connection.close(disconnect=disconnect)
        self._connection.close(disconnect=disconnect)

    def execute_preprocessed(self, sql: str) -> Any:
        if self._preprocessor_connection is None:
            if self._preprocessor_factory is None:
                raise RuntimeError("preprocessor connection is unavailable")
            con = self._preprocessor_factory()
            try:
                con.execute("EXECUTE SCRIPT SEMANTIC_ADMIN.ENABLE_SEMANTIC_SQL()")
            except BaseException:
                con.close()
                raise
            self._preprocessor_connection = con
        return self._preprocessor_connection.execute(sql)

    def _compile(self, script: str, argument: str) -> dict[str, Any]:
        statement = self.execute(
            f"EXECUTE SCRIPT SEMANTIC_ADMIN.{script}({_sql_string(argument)})")
        names = [name.lower() for name in statement.columns().keys()]
        values = dict(zip(names, statement.fetchone(), strict=True))
        return {name: values[name] for name in
                ("status", "error_code", "error_message", "generated_sql")}

    def compile_json(self, payload: dict[str, Any]) -> dict[str, Any]:
        return self._compile("COMPILE_REQUEST_JSON", json.dumps(payload))

    def compile_sql(self, sql: str) -> dict[str, Any]:
        return self._compile("COMPILE_SQL", sql)


def _connect_raw() -> Any:
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


def connect() -> ExasolBackend:
    return ExasolBackend(_connect_raw(), _connect_raw)
