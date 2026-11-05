# Admission webhook test server. /hang never answers, /sleep5 answers after 5 s, /allow at once.
import json, ssl, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

class H(BaseHTTPRequestHandler):
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        p = self.path.split("?")[0]
        if p == "/hang":
            time.sleep(600)
        elif p == "/sleep5":
            time.sleep(5)
        out = json.dumps({"apiVersion": "admission.k8s.io/v1", "kind": "AdmissionReview",
                          "response": {"uid": body["request"]["uid"], "allowed": True}}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass

s = ThreadingHTTPServer(("", 8443), H)
c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
c.load_cert_chain("/t/tls.crt", "/t/tls.key")
s.socket = c.wrap_socket(s.socket, server_side=True)
s.serve_forever()
