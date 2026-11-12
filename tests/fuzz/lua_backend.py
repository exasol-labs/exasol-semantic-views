"""Persistent, database-free Lua compiler process for contract cases."""

from __future__ import annotations

import json
import os
import select
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]


class CaseTimeout(Exception):
    pass


class LuaBackend:
    def __init__(self, timeout: int) -> None:
        command = os.environ.get("LUA_BIN") or shutil.which("lua") or shutil.which("lua5.4")
        if command is None:
            raise RuntimeError("Lua 5.4 is required for the SQLGlot contract oracle")
        self.timeout = timeout
        self.process = subprocess.Popen(
            [command, "tests/lua/semantic_fuzz_driver.lua"], cwd=ROOT,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=None,
            bufsize=0,
        )
        self.pending = bytearray()
        self.case_deadline: float | None = None

    def begin_case(self) -> None:
        self.case_deadline = time.monotonic() + self.timeout

    def compile(self, idx: int, sql: str) -> dict[str, Any]:
        process = self.process
        assert process.stdin is not None and process.stdout is not None
        process.stdin.write((json.dumps({"id": idx, "sql": sql}) + "\n").encode())
        process.stdin.flush()
        deadline = self.case_deadline or (time.monotonic() + self.timeout)
        while b"\n" not in self.pending:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise CaseTimeout
            ready, _, _ = select.select([process.stdout], [], [], remaining)
            if not ready:
                raise CaseTimeout
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("Lua driver exited without a reply")
            self.pending.extend(chunk)
        raw, _, remainder = self.pending.partition(b"\n")
        self.pending = bytearray(remainder)
        line = raw.decode("utf-8")
        try:
            result = json.loads(line)
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"Lua driver returned invalid JSON: {line.strip()}") from exc
        if result.get("id") != idx:
            raise RuntimeError(f"Lua driver reply ID {result.get('id')!r} != case ID {idx}")
        if result.get("status") == "HARNESS_ERROR":
            raise RuntimeError(f"Lua driver failed: {result.get('error_message')}")
        if result.get("status") not in ("OK", "ERROR"):
            raise RuntimeError(f"Lua driver returned invalid status: {result!r}")
        return result

    def close(self) -> None:
        process = self.process
        if process.poll() is None and process.stdin is not None:
            process.stdin.close()
        if process.poll() is None:
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        if process.stdout is not None:
            process.stdout.close()
        if process.stderr is not None:
            process.stderr.close()
