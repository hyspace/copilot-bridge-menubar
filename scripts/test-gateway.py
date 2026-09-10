#!/usr/bin/env python3
"""Exercise the compiled multi-source gateway using only loopback fixtures."""
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
BINARY = pathlib.Path(os.environ.get("CBM_TEST_BINARY", str(ROOT / "build/copilot-bridge-service"))).resolve()
assert BINARY.is_relative_to(ROOT / "build") and BINARY.is_file()
PROTECTED = subprocess.run(["lsof", "-tiTCP:4142", "-sTCP:LISTEN"], capture_output=True, text=True).stdout.strip()
TOKEN = "FAKE_CONTROL_TOKEN_AT_LEAST_32_CHARACTERS"
CALLS = []
FAILURES = []
LOCAL = "fixture-local"
COPILOT = "fixture-copilot"


class Mock(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, value, status=200, stream=False):
        data = value.encode() if isinstance(value, str) else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("content-type", "text/event-stream" if stream else "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/v1/models":
            return self.reply({"data": [{"id": LOCAL, "loaded": True, "task": "text-generation", "context_length": 32768}]})
        if self.path == "/v1/props":
            return self.reply({"model_path": LOCAL, "modalities": {"vision": True},
                               "chat_template_caps": {"supports_tool_calls": True}})
        if self.path.startswith("/models"):
            return self.reply({"object": "list", "data": [{
                "id": COPILOT, "name": "Fixture Copilot", "model_picker_enabled": True,
                "capabilities": {"type": "chat", "family": "fixture", "tokenizer": "o200k_base",
                                 "limits": {"max_context_window_tokens": 100000},
                                 "supports": {"tool_calls": True}},
                "supported_endpoints": ["/responses"],
            }]})
        return self.reply({"error": "Unexpected fixture route"}, 404)

    def do_POST(self):
        try:
            assert self.headers.get("ChatGPT-Account-ID") is None
            assert self.headers.get("Cookie") is None
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            if self.path == "/responses":
                assert self.headers.get("Authorization") == "Bearer FAKE_COPILOT_TOKEN"
                assert body["model"] == COPILOT
                source = "copilot"
            else:
                assert self.headers.get("Authorization") is None
                assert body["model"] == LOCAL
                source = "local"
            CALLS.append((source, self.path))
            if self.path == "/v1/chat/completions":
                assert body["enabled_tools"] == ["web_search"]
                assert body["mcp_enabled"] is False and body["bypass_permissions"] is False
                return self.reply('data: {"choices":[{"delta":{"content":"Only generated text, not executed search."},"finish_reason":"stop"}]}\n\n'
                                  'data: {"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":3}}\n\n'
                                  'data: [DONE]\n\n', stream=True)
            if body.get("input") == "search":
                name = next(t["name"] for t in body["tools"] if t.get("name", "").startswith("codex_bridge_hosted_"))
                item = {"id": "search-item", "type": "function_call", "name": name,
                        "call_id": "search-call", "arguments": '{"query":"fixture only"}', "status": "completed"}
            else:
                item = {"id": "fixture-message", "type": "message", "role": "assistant", "status": "completed",
                        "content": [{"type": "output_text", "text": "FIXTURE_OK", "annotations": []}]}
            usage = {"input_tokens": 23, "output_tokens": 7}
            if source == "copilot":
                usage["copilot_usage"] = {"total_nano_aiu": 125000000}
            events = [
                {"type": "response.created", "response": {"id": "fixture-response", "output": []}},
                {"type": "response.output_item.added", "output_index": 0, "item": item},
                {"type": "response.output_item.done", "output_index": 0, "item": item},
                {"type": "response.completed", "response": {
                    "id": "fixture-response", "status": "completed", "output": [item], "usage": usage}},
            ]
            return self.reply("".join("data: " + json.dumps(e) + "\n\n" for e in events), stream=True)
        except Exception as error:
            FAILURES.append(repr(error))
            self.reply({"error": "Fixture assertion failed"}, 500)


def port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        value = listener.getsockname()[1]
    assert value != 4142
    return value


opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
mock = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Mock)
threading.Thread(target=mock.serve_forever, daemon=True).start()
try:
    with tempfile.TemporaryDirectory(prefix="codex-bridge-gateway-fixture-") as directory:
        home = pathlib.Path(directory)
        settings = home / "gateway.json"
        settings.write_text(json.dumps({
            "codexEnabled": True,  # Broker intentionally absent: must not block other sources.
            "copilotEnabled": True, "localEnabled": True,
            "localURL": f"http://127.0.0.1:{mock.server_port}/v1",
        }))
        listener_port = port()
        env = {"HOME": str(home), "PATH": "/usr/bin:/bin", "NO_COLOR": "1", "NO_PROXY": "*",
               "COPILOT_TOKEN": "FAKE_COPILOT_TOKEN", "COPILOT_BASE_URL": f"http://127.0.0.1:{mock.server_port}",
               "CODEX_BRIDGE_CONTROL_TOKEN": TOKEN, "COPILOT_BRIDGE_EVENTS_TOKEN": "FAKE_EVENT_CHANNEL",
               "COPILOT_BRIDGE_INSTANCE_ID": "gateway-fixture", "CBM_PARENT_PID": str(os.getpid())}

        def fetch(path, body=None, headers=None):
            request = urllib.request.Request(f"http://127.0.0.1:{listener_port}{path}",
                data=None if body is None else json.dumps(body).encode(),
                headers={"content-type": "application/json", **(headers or {})})
            try:
                with opener.open(request, timeout=20) as response:
                    return response.status, response.read()
            except urllib.error.HTTPError as error:
                return error.code, error.read()

        with (home / "service.log").open("w") as log:
            child = subprocess.Popen([str(BINARY), "gateway", "--host", "127.0.0.1", "--port", str(listener_port),
                                      "--settings", str(settings)], env=env, stdout=log, stderr=subprocess.STDOUT)
            try:
                for _ in range(100):
                    assert child.poll() is None, "Gateway exited before becoming healthy"
                    try:
                        if fetch("/healthz")[0] == 200:
                            break
                    except (OSError, urllib.error.URLError):
                        pass
                    time.sleep(.05)
                else:
                    raise AssertionError("Gateway never became healthy")
                status, data = fetch("/v1/models?client_version=0.153.4")
                assert status == 200, data
                catalog = json.loads(data)["models"]
                assert {m["slug"] for m in catalog} == {"local/" + LOCAL, "copilot/" + COPILOT}, catalog
                assert next(m for m in catalog if m["slug"].startswith("local/"))["context_window"] == 32768
                assert fetch("/bridge/status")[0] == 403
                assert fetch("/bridge/status", headers={"x-codex-bridge-token": TOKEN})[0] == 200
                assert fetch("/bridge/status", headers={"x-codex-bridge-token": TOKEN, "origin": "http://website.test"})[0] == 403
                assert fetch("/v1/responses", {"model": "local/" + LOCAL}, {"origin": "http://website.test"})[0] == 403
                caller = {"authorization": "Bearer FAKE_CALLER_TOKEN", "chatgpt-account-id": "FAKE_CALLER_ACCOUNT",
                          "cookie": "private=value", "session_id": "fixture-task"}
                for source, model in [("local", LOCAL), ("copilot", COPILOT)]:
                    status, data = fetch("/v1/responses", {"model": source + "/" + model, "input": "hello", "stream": True,
                        "tools": [{"type": "function", "name": "read"}, {"type": "web_search"}]}, caller)
                    assert status == 200 and b"FIXTURE_OK" in data, data
                count = len(CALLS)
                assert fetch("/v1/responses", {"model": "local/missing", "input": "x"})[0] == 404
                assert fetch("/v1/responses", {"model": COPILOT, "input": "x"})[0] == 404
                assert len(CALLS) == count, "An ambiguous model used another source"
                status, data = fetch("/v1/responses", {"model": "local/" + LOCAL, "input": "search", "stream": True,
                    "tools": [{"type": "web_search"}]})
                assert status == 200 and b"response.failed" in data and b"local_search_unavailable" in data, data
                assert b'"type":"response.web_search_call.completed"' not in data
                time.sleep(.15)
            finally:
                child.terminate()
                try:
                    child.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait(timeout=5)
        log = (home / "service.log").read_text()
        assert not FAILURES, FAILURES
        assert "FAKE_CALLER" not in log and TOKEN not in log
        events = [json.loads(line[6:]) for line in log.splitlines() if line.startswith("@@CBM:")]
        usage = [event for event in events if event.get("kind") == "usage"]
        assert len(usage) == 4, usage
        assert sum(event.get("provider", "copilot") == "local" for event in usage) == 3
        assert next(event for event in usage if event.get("provider", "copilot") == "copilot")["nanoAiu"] == 125000000
        assert not (home / ".codex/config.toml").exists(), "Gateway startup wrote Codex configuration"
finally:
    mock.shutdown()
    mock.server_close()
current = subprocess.run(["lsof", "-tiTCP:4142", "-sTCP:LISTEN"], capture_output=True, text=True).stdout.strip()
assert current == PROTECTED, "Protected listener identity changed"
print("PASS: compiled multi-source gateway; catalog, isolated auth/usage, default tools,")
print("      no cross-source fallback, explicit native-search failure, no config writes.")
print(f"Protected 4142 listener unchanged: {current or '(none)'}")
