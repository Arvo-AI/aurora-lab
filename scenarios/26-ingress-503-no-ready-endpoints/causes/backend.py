# Small upstream for the 503 reproductions.
#   /healthz        200
#   /never          500 (a readiness path that never passes)
#   .../fail503...  the app's own 503 with a JSON body and Retry-After
#   .../sleep/N...  wait N seconds, then answer
#   anything else   200
# MODE=fail answers 503 on everything but /healthz. MODE=errors is the custom
# error backend: it reports the X-Code header ingress-nginx sends it.
import json, os, re, socket, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODE = os.environ.get("MODE", "")
POD = socket.gethostname()

class H(BaseHTTPRequestHandler):
    server_version = "demo-app/1.0"
    sys_version = ""

    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, {"status": "ok"})
        if self.path == "/never":
            return self._send(500, {"status": "never ready"})
        if MODE == "errors":
            return self._send(503, {"page": "custom error page", "x_code": self.headers.get("X-Code"), "pod": POD})
        m = re.search(r"/sleep/(\d+)", self.path)
        if m:
            time.sleep(int(m.group(1)))
        if "fail503" in self.path or MODE == "fail":
            return self._send(503, {"error": "backend unavailable", "pod": POD}, {"Retry-After": "5"})
        self._send(200, {"ok": True, "pod": POD, "path": self.path})

    def _send(self, code, body, extra=None):
        data = (json.dumps(body) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

ThreadingHTTPServer(("", 8080), H).serve_forever()
