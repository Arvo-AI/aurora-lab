# An api release makes /healthz call a stock service with no timeout. The address
# drops packets (192.0.2.10 is TEST-NET-1, RFC 5737), so the handler blocks far
# longer than the probe's 1 s timeoutSeconds. New pods never get Ready; the
# liveness probe restarts them. The old pods keep the old code and keep serving.
kubectl -n shop get cm api-code -o json | python3 -c '
import json, sys
cm = json.load(sys.stdin)
code = cm["data"]["api.py"]
old_import = "import json, os, socket, sys, time\n"
new_import = "import json, os, socket, sys, time, urllib.request\n"
old = """        if self.path == "/healthz":
            return self._send(200, {"status": "ok"})"""
new = """        if self.path == "/healthz":
            urllib.request.urlopen("http://192.0.2.10:8080/stock")
            return self._send(200, {"status": "ok"})"""
assert old_import in code and old in code
cm["data"]["api.py"] = code.replace(old_import, new_import).replace(old, new)
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    cm["metadata"].pop(k, None)
print(json.dumps(cm))' | kubectl apply -f -
kubectl -n shop rollout restart deploy/api
