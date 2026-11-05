# An api release adds a slow dependency check to /healthz (2 s, with the probes
# still on the default timeoutSeconds of 1) and a SIGTERM handler that exits 143.
# python is PID 1 here, so without a handler it would ignore SIGTERM and end in
# 137; the handler stands in for the many runtimes that exit 143 by themselves.
kubectl -n shop get cm api-code -o json | python3 -c '
import json, sys
cm = json.load(sys.stdin)
code = cm["data"]["api.py"]
old_import = "import json, os, socket, sys, time\n"
new_import = old_import + "import signal\nsignal.signal(signal.SIGTERM, lambda *_: sys.exit(143))\n"
old = """            if self.path == "/healthz":
                return self._send(200, {"status": "ok"})"""
new = """            if self.path == "/healthz":
                time.sleep(2)  # stock service check
                return self._send(200, {"status": "ok"})"""
assert old_import in code and old in code
cm["data"]["api.py"] = code.replace(old_import, new_import).replace(old, new)
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    cm["metadata"].pop(k, None)
print(json.dumps(cm))' | kubectl apply -f -
kubectl -n shop rollout restart deploy/api
