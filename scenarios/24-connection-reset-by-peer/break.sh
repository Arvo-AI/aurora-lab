# An api release adds a streaming POST /import and exits straight away on
# SIGTERM. An uploader streams a body to it for 60 s at a time. The final rollout
# restart kills the old pods with the upload in flight.
kubectl -n shop get cm api-code -o json | python3 -c '
import json, sys
cm = json.load(sys.stdin)
code = cm["data"]["api.py"]
old = """    class H(BaseHTTPRequestHandler):
        def do_GET(self):"""
new = """    class H(BaseHTTPRequestHandler):
        def do_POST(self):
            left = int(self.headers.get("Content-Length", "0"))
            while left > 0:
                chunk = self.rfile.read(min(left, 65536))
                if not chunk:
                    return
                left -= len(chunk)
                time.sleep(0.1)
            self._send(200, {"imported": True})

        def do_GET(self):"""
assert old in code
code = code.replace(old, new)
old = """    print(f"api listening on :{PORT}", flush=True)"""
new = """    signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
    print(f"api listening on :{PORT}", flush=True)"""
assert old in code
code = code.replace(old, new).replace("import json, os, socket, sys, time", "import json, os, signal, socket, sys, time")
cm["data"]["api.py"] = code
cm["data"]["uploader.py"] = """import http.client, time
SIZE = 40 * 1024 * 1024
CHUNK = b"x" * 65536
while True:
    conn = http.client.HTTPConnection("api", 8080, timeout=30)
    sent = 0
    try:
        conn.putrequest("POST", "/import")
        conn.putheader("Content-Length", str(SIZE))
        conn.endheaders()
        while sent < SIZE:
            conn.send(CHUNK)
            sent += len(CHUNK)
            time.sleep(0.1)
        print("import ok, status", conn.getresponse().status, flush=True)
    except Exception as e:
        print(f"import failed after {sent} bytes: {type(e).__name__}: {e}", flush=True)
    finally:
        conn.close()
    time.sleep(1)
"""
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    cm["metadata"].pop(k, None)
print(json.dumps(cm))' | kubectl apply -f -
kubectl -n shop rollout restart deploy/api
kubectl -n shop rollout status deploy/api --timeout=120s
kubectl apply -f - <<'Y'
apiVersion: apps/v1
kind: Deployment
metadata: {name: uploader, namespace: shop}
spec:
  replicas: 1
  selector: {matchLabels: {app: uploader}}
  template:
    metadata: {labels: {app: uploader}}
    spec:
      containers:
        - name: uploader
          image: python:3.12-alpine
          command: ["python", "-u", "/code/uploader.py"]
          resources: {requests: {cpu: 20m, memory: 32Mi}, limits: {memory: 64Mi}}
          volumeMounts: [{name: code, mountPath: /code}]
      volumes:
        - name: code
          configMap: {name: api-code}
Y
kubectl -n shop rollout status deploy/uploader --timeout=120s
sleep 5
kubectl -n shop rollout restart deploy/api
kubectl -n shop rollout status deploy/api --timeout=120s
