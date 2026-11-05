# A registry that resolves the manifest and config, then stalls forever in the layer blob.
import hashlib, json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
cfg = json.dumps({"architecture": "amd64", "os": "linux", "rootfs": {"type": "layers", "diff_ids": ["sha256:" + "0" * 64]}, "config": {}}).encode()
cd = "sha256:" + hashlib.sha256(cfg).hexdigest()
ld = "sha256:" + "a" * 64
man = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": cd, "size": len(cfg)},
  "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": ld, "size": 1048576}]}).encode()
md = "sha256:" + hashlib.sha256(man).hexdigest()
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def send(self, b, ct="application/json"):
        self.send_response(200)
        self.send_header("Content-Type", ct); self.send_header("Content-Length", str(len(b)))
        self.send_header("Docker-Content-Digest", md if b is man else "sha256:" + hashlib.sha256(b).hexdigest())
        self.end_headers()
        if self.command != "HEAD": self.wfile.write(b)
    def do_HEAD(self): self.do_GET()
    def do_GET(self):
        p = self.path; print(self.command, p, flush=True)
        if p.endswith("/v2/"): return self.send(b"{}")
        if "/manifests/" in p: return self.send(man, "application/vnd.oci.image.manifest.v1+json")
        if cd in p: return self.send(cfg, "application/vnd.oci.image.config.v1+json")
        if ld in p:
            self.send_response(200); self.send_header("Content-Length", "1048576"); self.end_headers()
            self.wfile.write(b"\0" * 4096); self.wfile.flush(); time.sleep(3600)
    def log_message(self, *a): pass
ThreadingHTTPServer(("", int(sys.argv[1])), H).serve_forever()
