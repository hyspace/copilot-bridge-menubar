#!/usr/bin/python3
"""Native integration fixture: fake credentials, fake usage, no upstream network."""
import http.server
import json
import os
import pathlib
import signal
import sys
import time
import uuid

home = pathlib.Path(os.environ["HOME"])
if "cbm-native-test-" not in str(home):
    raise SystemExit("Refusing to run outside an isolated native test HOME")
mode = (home/"mode").read_text().strip()
counter = home/"launches"
counter.write_text(str(int(counter.read_text()) + 1) if counter.exists() else "1")
(home/"argv.json").write_text(json.dumps(sys.argv[1:]))
(home/"env.json").write_text(json.dumps(dict(os.environ)))

def emit(data):
    data["channel"] = os.environ["COPILOT_BRIDGE_EVENTS_TOKEN"]
    print("@@CBM:" + json.dumps(data), flush=True)

if mode == "auth-no-response":
    time.sleep(60)
    raise SystemExit(0)
if sys.argv[1] == "auth":
    emit({"kind":"authRequired","code":"ABCD-1234","expiresIn":60})
    time.sleep(.15)
    if mode == "auth-denied":
        emit({"kind":"authFailed","message":"denied"})
        raise SystemExit(1)
    # Deliberately exit immediately after the final event to exercise pipe draining.
    emit({"kind":"authSuccess"})
    raise SystemExit(0)
if mode == "crash":
    print("fake crash", file=sys.stderr, flush=True)
    raise SystemExit(7)
if mode == "stubborn":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
if mode == "never-ready":
    time.sleep(60)
    raise SystemExit(0)

port = int(sys.argv[sys.argv.index("--port")+1])
if port == 4142:
    raise SystemExit("The current real bridge is protected")
emit({"kind":"usage","id":str(uuid.uuid4()),"timestamp":time.time(),"model":"fake-model",
      "status":200,"input":100,"output":20,"cached":40,"outcome":"complete"})

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        if self.path == "/healthz":
            body = {"ok":True,"instance":os.environ["COPILOT_BRIDGE_INSTANCE_ID"]}
        elif self.path == "/usage":
            if (home/"quota-error").exists():
                self.send_error(503)
                return
            body = {"token_based_billing":True,"quota_snapshots":{"premium_interactions":{
                "quota_remaining":75.5,"entitlement":100,"credits_used":24,
                "percent_remaining":75.5,"unlimited":False}}}
        else:
            self.send_error(404)
            return
        data = json.dumps(body).encode()
        self.send_response(200)
        self.send_header("content-type","application/json")
        self.send_header("content-length",str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = http.server.HTTPServer(("127.0.0.1",port),Handler)
server.serve_forever()
