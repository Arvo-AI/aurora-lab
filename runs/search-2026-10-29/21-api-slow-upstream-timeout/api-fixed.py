import json, os, socket, sys, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REDIS_HOST = os.environ["REDIS_HOST"]
PORT = int(os.environ.get("PORT", "8080"))

def redis_ping():
    with socket.create_connection((REDIS_HOST, 6379), timeout=2) as s:
        s.sendall(b"PING\r\n")
        return s.recv(64).startswith(b"+PONG")

for attempt in range(1, 6):
    try:
        redis_ping()
        print(f"connected to redis at {REDIS_HOST}:6379", flush=True)
        break
    except OSError as e:
        print(f"redis connection failed (attempt {attempt}/5): {e}", flush=True)
        time.sleep(2)
else:
    print("giving up: redis unavailable", flush=True)
    sys.exit(1)

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/healthz":
            return self._send(200, {"status": "ok"})
        try:
            redis_ping()
            try:
                with urllib.request.urlopen("http://192.0.2.10:8080/stock", timeout=1) as r:
                    stock = json.load(r)
            except OSError as e:
                print(f"stock lookup failed: {e}", flush=True)
                stock = {}
            self._send(200, {"items": ["kettle", "mug", "teapot"], "stock": stock})
        except OSError as e:
            print(f"request failed: redis error: {e}", flush=True)
            self._send(503, {"error": "backend unavailable"})

    def _send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):
        print("%s %s" % (self.address_string(), fmt % args), flush=True)

print(f"api listening on :{PORT}", flush=True)
ThreadingHTTPServer(("", PORT), H).serve_forever()
