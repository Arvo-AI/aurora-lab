# test upstream: /sleep/N waits N seconds before the header; /drip/N/S sends the header,
# then one byte every S seconds, N times; /close closes the socket with no response
import socket, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        t = time.time()
        p = self.path.strip("/").split("/")
        if p[0] == "sleep":
            time.sleep(float(p[1]))
            body = b"done\n"
            self.send_response(200); self.send_header("Content-Length", str(len(body))); self.end_headers(); self.wfile.write(body)
        elif p[0] == "drip":
            n, s = int(p[1]), float(p[2])
            self.send_response(200); self.send_header("Content-Length", str(n)); self.end_headers(); self.wfile.flush()
            for _ in range(n):
                time.sleep(s); self.wfile.write(b"."); self.wfile.flush()
        elif p[0] == "close":
            self.connection.shutdown(socket.SHUT_RDWR); self.close_connection = True
        else:
            self.send_response(200); self.send_header("Content-Length", "3"); self.end_headers(); self.wfile.write(b"ok\n")
        print(f"upstream {self.path} handled in {time.time()-t:.3f}s", flush=True)
    def log_message(self, *a): pass
ThreadingHTTPServer(("", 8080), H).serve_forever()
