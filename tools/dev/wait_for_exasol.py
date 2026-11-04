#!/usr/bin/env python3
"""Wait until the CI Exasol service accepts queries."""

import os
import ssl
import sys
import time


def main() -> int:
    os.environ.setdefault("EXASOL_TELEMETRY_DISABLE", "true")
    import pyexasol

    started = time.monotonic()
    deadline = started + 300
    last_error = None
    attempt = 0
    print("Waiting up to 300 seconds for Exasol to accept queries...", flush=True)
    while time.monotonic() < deadline:
        attempt += 1
        try:
            con = pyexasol.connect(
                dsn=f"{os.environ['EXASOL_HOST']}:{os.environ['EXASOL_PORT']}",
                user=os.environ["EXASOL_USER"],
                password=os.environ["EXASOL_PASSWORD"],
                encryption=True,
                websocket_sslopt={"cert_reqs": ssl.CERT_NONE},
            )
            con.execute("SELECT 1").fetchall()
            con.close()
            print(f"Exasol ready after {attempt} attempt(s).", flush=True)
            return 0
        except Exception as error:
            last_error = repr(error)[:120]
            elapsed = int(time.monotonic() - started)
            print(f"Exasol not ready (attempt {attempt}, {elapsed}s elapsed): {last_error}", flush=True)
            time.sleep(3)
    print(f"Exasol did not become ready in time. Last error: {last_error}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
