# One thread, like a blocking worker: while a handler runs, new connections wait
# in the kernel accept queue with their request bytes unread.
import os, time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _send(self, code, body=b"ok\n", close=False):
        self.send_response(code)
        self.send_header("Content-Length", str(len(body)))
        if close:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/die":
            time.sleep(int(parse_qs(u.query).get("ms", ["3000"])[0]) / 1000)
            os._exit(1)
        self._send(200)
    def do_POST(self):
        # Reject on the header alone and close, leaving the body unread.
        self._send(413, b"too large\n", close=True)
    def log_message(self, *a):
        pass

HTTPServer(("", 8081), H).serve_forever()
