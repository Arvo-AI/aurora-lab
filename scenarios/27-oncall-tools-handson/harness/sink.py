"""Records every POST it receives to a JSON-lines file. Stands in for a phone."""
import datetime, json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
port, path = int(sys.argv[1]), sys.argv[2]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        with open(path, "a") as f:
            f.write(json.dumps({"t": datetime.datetime.now(datetime.timezone.utc).isoformat(), "path": self.path, "body": body}) + "\n")
        self.send_response(200); self.send_header("Content-Length", "2"); self.end_headers(); self.wfile.write(b"ok")
    def do_GET(self): self.do_POST()
    def log_message(self, *a): pass
ThreadingHTTPServer(("0.0.0.0", port), H).serve_forever()
