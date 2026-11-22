#!/usr/bin/env python3
"""Development relay for the rut360gw web page (package/.../www/rut360gw/).

Serves the page locally (http://localhost:8088/rut360gw/) and relays its JSON-RPC /ubus calls
to a REAL router, without ever handling the web interface password:
  - `session.login` / `session.destroy` are simulated;
  - default mode: the other calls go to http://<ROUTER>/ubus with a session created over SSH
    (`ubus call session create` + `session grant` limited to the rut360gw object);
  - MODULE mode (PLUGIN_DIR variable): calls to the rut360gw object run the IN-DEVELOPMENT
    version of the rpcd module, copied to PLUGIN_DIR on the router (/tmp), over SSH, without
    installing anything. Read methods are real; write methods are SIMULATED (no change on the
    router), except USSD, run as a dry run (file PLUGIN_DIR/ussd.dryrun: no radio request).
Variables: ROUTER (e.g. 192.168.2.1), SID (default mode), WWW (root of the files),
PLUGIN_DIR + SSH_KEY (module mode).
Usage: see docs/DEVELOPMENT.md.
"""
import json
import os
import subprocess
import urllib.request
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

ROUTER = os.environ["ROUTER"]
SID = os.environ.get("SID", "relay")
WWW = os.environ.get("WWW", "/www")
PLUGIN_DIR = os.environ.get("PLUGIN_DIR", "")
SSH_KEY = os.environ.get("SSH_KEY", "")
READ = {"status", "get_config", "logs", "sms_list", "ussd_history"}
DRYRUN_OK = {"ussd_send", "ussd_cancel"}  # really executed, but as a dry run (no radio)

# Same policy as RutOS 7.04 uhttpd (inline scripts and styles forbidden): a page that works
# behind this relay also works on the router.
CSP = "default-src 'self'; script-src 'self'; style-src 'self'; img-src * 'self'"


def run_plugin(method, args):
    env = (f"RUT360GW_SMS_BIN={PLUGIN_DIR}/sms RUT360GW_USSD_HIST={PLUGIN_DIR}/hist "
           f"RUT360GW_USSD_DRYRUN={PLUGIN_DIR}/ussd.dryrun")
    cmd = ["ssh", "-i", SSH_KEY, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
           "-o", "LogLevel=ERROR", f"root@{ROUTER}", f"{env} sh {PLUGIN_DIR}/plugin call {method}"]
    out = subprocess.run(cmd, input=json.dumps(args).encode(), capture_output=True, timeout=90).stdout
    return json.loads(out or b"{}")


class Relay(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WWW, **kwargs)

    def end_headers(self):
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("X-Content-Type-Options", "nosniff")
        super().end_headers()

    def reply(self, req, result):
        data = json.dumps({"jsonrpc": "2.0", "id": req.get("id"), "result": result}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/ubus":
            self.send_error(404)
            return
        req = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        params = req.get("params") or []
        if len(params) >= 3 and params[1] == "session" and params[2] in ("login", "destroy"):
            self.reply(req, [0, {"ubus_rpc_session": SID}])
            return
        if PLUGIN_DIR and len(params) >= 4 and params[1] == "rut360gw":
            method, args = params[2], params[3] or {}
            if method in READ or method in DRYRUN_OK:
                self.reply(req, [0, run_plugin(method, args)])
            else:
                self.reply(req, [0, {"ok": True, "message": f"(relay: {method} simulated, router unchanged)",
                                     "password": "relay-simulated", "fiche": "# (relay: simulated sheet)",
                                     "deleted": 0}])
            return
        if params:
            params[0] = SID
        fwd = urllib.request.Request(f"http://{ROUTER}/ubus", data=json.dumps(req).encode(),
                                     headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(fwd, timeout=60) as r:
            data = r.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    print(f"page: http://localhost:8088/rut360gw/  ->  router {ROUTER}" + (f" (module {PLUGIN_DIR})" if PLUGIN_DIR else ""))
    ThreadingHTTPServer(("0.0.0.0", 8088), Relay).serve_forever()
