"""Helper for persona user tests - runs SQL and MCP calls, records results."""
import json
import subprocess
import sys
import time
import traceback
import pyexasol

PYTHON = sys.executable
DSN = 'localhost:8563'
USER = 'sys'
PASSWORD = 'exasol'
MCP_BASE = 'http://localhost:4896'

# --- DB helpers ---

def get_conn():
    return pyexasol.connect(dsn=DSN, user=USER, password=PASSWORD, websocket_sslopt={'cert_reqs': 0})

def sql(query, conn=None, close=True):
    """Run a SELECT query, return (rows, columns, error)."""
    own = conn is None
    if own:
        conn = get_conn()
    try:
        stmt = conn.execute(query)
        cols = list(stmt.columns().keys())
        rows = stmt.fetchall()
        return rows, cols, None
    except Exception as e:
        return None, None, str(e)
    finally:
        if own and close:
            conn.close()

def execute_script(script_call, conn=None):
    """Run EXECUTE SCRIPT ..., return (result, error)."""
    own = conn is None
    if own:
        conn = get_conn()
    try:
        rows, cols, err = sql(script_call, conn=conn, close=False)
        return rows, cols, err
    finally:
        if own:
            conn.close()

def run_statement(stmt, conn=None):
    """Run any statement (DDL, DML, EXECUTE SCRIPT). Returns (success, error)."""
    own = conn is None
    if own:
        conn = get_conn()
    try:
        conn.execute(stmt)
        return True, None
    except Exception as e:
        return False, str(e)
    finally:
        if own:
            conn.close()

# --- MCP helpers ---

_mcp_session_id = None

def mcp_init():
    """Initialize an MCP session, return session_id."""
    global _mcp_session_id
    # Get session ID from server
    r = subprocess.run(
        ['curl', '-sv', '-H', 'Accept: text/event-stream', f'{MCP_BASE}/mcp'],
        capture_output=True, text=True
    )
    import re
    m = re.search(r'mcp-session-id: ([a-f0-9]+)', r.stderr)
    if not m:
        raise RuntimeError(f"Could not get session ID: {r.stderr[:200]}")
    _mcp_session_id = m.group(1)
    # Initialize
    payload = json.dumps({
        "jsonrpc": "2.0", "id": 1, "method": "initialize",
        "params": {"protocolVersion": "2024-11-05", "capabilities": {},
                   "clientInfo": {"name": "persona-test", "version": "1.0"}}
    })
    r = subprocess.run(
        ['curl', '-s', '-X', 'POST', f'{MCP_BASE}/mcp',
         '-H', 'Content-Type: application/json',
         '-H', 'Accept: application/json, text/event-stream',
         '-H', f'mcp-session-id: {_mcp_session_id}',
         '-d', payload],
        capture_output=True, text=True
    )
    # Send initialized notification
    notif = json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"})
    subprocess.run(
        ['curl', '-s', '-X', 'POST', f'{MCP_BASE}/mcp',
         '-H', 'Content-Type: application/json',
         '-H', 'Accept: application/json, text/event-stream',
         '-H', f'mcp-session-id: {_mcp_session_id}',
         '-d', notif],
        capture_output=True, text=True
    )
    return _mcp_session_id

def mcp_call(tool_name, params=None, req_id=None):
    """Call an MCP tool, return parsed result."""
    global _mcp_session_id
    if _mcp_session_id is None:
        mcp_init()
    if req_id is None:
        req_id = int(time.time() * 1000) % 100000
    payload = json.dumps({
        "jsonrpc": "2.0", "id": req_id, "method": "tools/call",
        "params": {"name": tool_name, "arguments": params or {}}
    })
    r = subprocess.run(
        ['curl', '-s', '-X', 'POST', f'{MCP_BASE}/mcp',
         '-H', 'Content-Type: application/json',
         '-H', 'Accept: application/json, text/event-stream',
         '-H', f'mcp-session-id: {_mcp_session_id}',
         '-d', payload],
        capture_output=True, text=True
    )
    # Parse SSE
    raw = r.stdout
    for line in raw.splitlines():
        if line.startswith('data: '):
            try:
                return json.loads(line[6:])
            except:
                pass
    return {"error": f"Could not parse: {raw[:200]}"}

# --- Reporting helpers ---

class TestLog:
    def __init__(self, persona_name):
        self.persona = persona_name
        self.steps = []
        self.bugs = []
        self.friction = []
        self.observations = []

    def step(self, name, sql_or_action, result, error=None, note=None):
        entry = {
            "step": name,
            "action": sql_or_action[:200] if sql_or_action else None,
            "result_summary": self._summarize(result),
            "error": error,
            "note": note
        }
        self.steps.append(entry)
        status = "ERROR" if error else "OK"
        print(f"  [{status}] {name}")
        if error:
            print(f"         ERR: {error[:120]}")
        if note:
            print(f"        NOTE: {note}")

    def bug(self, id, title, repro, expected, actual):
        self.bugs.append({"id": id, "title": title, "repro": repro, "expected": expected, "actual": actual})
        print(f"  [BUG-{id}] {title}")

    def friction(self, point):
        self.friction.append(point)
        print(f"  [FRICTION] {point}")

    def observe(self, observation):
        self.observations.append(observation)

    def _summarize(self, result):
        if result is None:
            return None
        if isinstance(result, list):
            return f"{len(result)} rows"
        if isinstance(result, dict):
            return str(result)[:100]
        return str(result)[:100]


if __name__ == '__main__':
    print("Helper module loaded OK")
    sid = mcp_init()
    print(f"MCP session: {sid}")
