#!/usr/bin/env python3
"""Isolated local fake-upstream tests. NEVER connects to, starts, or kills port 4142."""
import http.server
import json
import os
import pathlib
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
BINARY = ROOT / "build/copilot-bridge-service"
assert BINARY.is_file(), "Build the backend first."
ORIGINAL_PID = subprocess.run(["lsof", "-tiTCP:4142", "-sTCP:LISTEN"], capture_output=True, text=True).stdout.strip()
UPSTREAM_CALLS = []
MODEL = {
    "id": "gpt-6-astra", "name": "Test model", "model_picker_enabled": True,
    "object": "model", "policy": {"state": "enabled"},
    "capabilities": {"type": "chat", "family": "gpt-6-astra", "tokenizer": "o200k_base",
        "limits": {"max_context_window_tokens": 1000000, "max_prompt_tokens": 872000, "max_output_tokens": 128000},
        "supports": {"tool_calls": True, "streaming": True, "reasoning_effort": ["medium"]}},
    "supported_endpoints": ["/responses"]
}

class Mock(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def send(self, body, status=200, content_type="application/json"):
        data = body.encode()
        self.send_response(status)
        self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        assert self.path.startswith("/models"), self.path
        self.send(json.dumps({"object": "list", "data": [MODEL]}))
    def do_POST(self):
        assert self.headers.get("Authorization") == "Bearer FAKE_COPILOT_TEST_TOKEN"
        assert self.headers.get("X-Bridge-Key") is None, "LAN credential leaked upstream"
        assert self.headers.get("ChatGPT-Account-ID") is None, "OpenAI identity leaked upstream"
        body = json.loads(self.rfile.read(int(self.headers["content-length"])))
        UPSTREAM_CALLS.append(body.get("input"))
        if body.get("input") == "test-413":
            self.send("failed to parse request", status=413, content_type="text/plain")
            return
        events = [
            {"type":"response.created","response":{"id":"response-test","model":"gpt-6-astra","created_at":1,"output":[]}},
            {"type":"response.output_text.delta","output_index":0,"item_id":"item-test","delta":"你好"},
            {"type":"response.completed","response":{"id":"response-test","output":[],
                "usage":{"input_tokens":100,"output_tokens":20,"input_tokens_details":{"cached_tokens":40}}}}
        ]
        if body.get("input") == "test-interrupt": events = events[:-1]
        self.send("".join(f"data: {json.dumps(e)}\n\n" for e in events),
                  content_type="text/event-stream")

def port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); value = s.getsockname()[1]
    assert value != 4142
    return value

def fetch(service_port, path, key="FAKE_LAN_KEY", body=None):
    assert service_port != 4142
    headers = {"content-type":"application/json"}
    if key is not None: headers["X-Bridge-Key"] = key
    if body is not None:
        headers["Authorization"] = "Bearer FAKE_OPENAI_DO_NOT_FORWARD"
        headers["ChatGPT-Account-ID"] = "FAKE_ACCOUNT"
    request = urllib.request.Request(f"http://127.0.0.1:{service_port}{path}",
        data=None if body is None else json.dumps(body).encode(), headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=5) as response: return response.status, response.read()
    except urllib.error.HTTPError as e: return e.code, e.read()

def wait_ready(service_port, process):
    for _ in range(100):
        assert process.poll() is None, "Isolated backend exited unexpectedly"
        try:
            status, data = fetch(service_port, "/__menubar/health")
            if status == 200:
                assert json.loads(data)["instance"] == "integration"
                return
        except (OSError, urllib.error.URLError): pass
        time.sleep(.05)
    raise AssertionError("Isolated backend never became healthy")

mock = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mock)
threading.Thread(target=mock.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix="cbm-integration-") as directory:
    home = pathlib.Path(directory)
    (home/".codex").mkdir()
    config = home/".codex/config.toml"
    config.write_text('model = "gpt-6-astra"\n')
    env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "NO_COLOR": "1", "NO_PROXY":"*",
        "COPILOT_TOKEN":"FAKE_COPILOT_TEST_TOKEN", "COPILOT_BASE_URL":f"http://127.0.0.1:{mock.server_port}",
        "CBM_LAN_KEY":"FAKE_LAN_KEY", "CBM_INSTANCE_ID":"integration", "CBM_PARENT_PID":str(os.getpid())}
    p = port()
    args = [str(BINARY),"start","--host","127.0.0.1","--port",str(p),
            "--no-codex-setup","--no-claude-setup","--no-prompt"]
    stdout = home/"stdout.log"
    with stdout.open("w") as log:
        child = subprocess.Popen(args, env=env, stdout=log, stderr=subprocess.STDOUT)
        try:
            wait_ready(p, child)
            assert fetch(p, "/healthz", key=None)[0] == 401
            assert fetch(p, "/healthz", key="WRONG")[0] == 401
            assert fetch(p, "/healthz")[0] == 200
            assert fetch(p, "/v1/responses")[0] == 404  # HTTP GET is not WebSocket.
            status, data = fetch(p, "/v1/models?client_version=0.153.3")
            assert status == 200 and json.loads(data)["models"][0]["slug"] == "gpt-6-astra"
            for text in ["hello", "test-413", "test-interrupt"] + ["load-test"] * 100:
                status, data = fetch(p, "/v1/responses",
                    body={"model":"gpt-6-astra","input":text,"stream":True})
                assert status == (413 if text == "test-413" else 200)
                if text == "hello": assert "你好" in data.decode()
            # A competing process must fail without killing the live test server.
            try:
                competitor = subprocess.run(args, env=env, capture_output=True, timeout=8)
            except subprocess.TimeoutExpired as error:
                raise AssertionError(f"Competing isolated backend did not exit: {error.stdout!r} {error.stderr!r}")
            assert competitor.returncode != 0
            assert fetch(p, "/healthz")[0] == 200
            time.sleep(.2)
        finally:
            # Only the exact Popen handle created by this test is ever signalled.
            child.terminate()
            try: child.wait(timeout=5)
            except subprocess.TimeoutExpired: child.kill(); child.wait(timeout=5)
    records = [json.loads(line[6:]) for line in stdout.read_text().splitlines() if line.startswith("@@CBM:")]
    usage = [record for record in records if record.get("kind") == "usage"]
    assert len(usage) == 103, len(usage)
    assert sum(record["input"] or 0 for record in usage) == 10100
    assert len([r for r in usage if r["outcome"] == "http_error"]) == 1
    assert len([r for r in usage if r["outcome"] == "interrupted"]) == 1
    assert "FAKE_OPENAI_DO_NOT_FORWARD" not in stdout.read_text()
    assert config.read_text() == 'model = "gpt-6-astra"\n'

    # Parent-death test: launch through a disposable parent, then kill that parent only.
    p2 = port()
    parent_code = """
import subprocess,os,sys,time,json
env=json.loads(sys.argv[1]);env['CBM_PARENT_PID']=str(os.getpid())
p=subprocess.Popen(json.loads(sys.argv[2]),env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
print(p.pid,flush=True)
time.sleep(30)
"""
    args2 = args.copy(); args2[args2.index("--port")+1] = str(p2)
    launcher = subprocess.Popen(["/usr/bin/python3","-c",parent_code,json.dumps(env),json.dumps(args2)],
                                stdout=subprocess.PIPE,text=True)
    orphan_pid = int(launcher.stdout.readline().strip())
    try:
        wait_ready(p2, launcher)
        launcher.terminate(); launcher.wait(timeout=5)
        for _ in range(70):
            try: fetch(p2, "/healthz")
            except (OSError, urllib.error.URLError): break
            time.sleep(.1)
        else: raise AssertionError(f"Orphan backend {orphan_pid} did not shut down")
    finally:
        if launcher.poll() is None: launcher.terminate(); launcher.wait(timeout=5)
mock.shutdown(); mock.server_close()
current = subprocess.run(["lsof","-tiTCP:4142","-sTCP:LISTEN"],capture_output=True,text=True).stdout.strip()
assert ORIGINAL_PID == current, "Protected listener identity changed"
print("PASS: compiled arm64 backend, 103 fake requests, LAN auth, usage/413/interruption,")
print("      catalog compatibility, no config writes, port conflict, parent-death cleanup.")
print(f"Protected 4142 listener unchanged: {current or '(none)'}")
