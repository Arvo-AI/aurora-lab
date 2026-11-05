# Opens a new connection per request, no retries, until /tmp/stop appears.
import collections, http.client, os, sys, threading, time

host, threads = sys.argv[1], int(sys.argv[2])
res, lock = collections.Counter(), threading.Lock()

def work():
    while not os.path.exists("/tmp/stop"):
        c = http.client.HTTPConnection(host, 8080, timeout=30)
        try:
            c.request("GET", "/slow")
            r = c.getresponse()
            r.read()
            key = f"http_{r.status}"
        except Exception as e:
            key = f"{type(e).__name__}: {e}"
        finally:
            c.close()
        with lock:
            res[key] += 1

ts = [threading.Thread(target=work) for _ in range(threads)]
[t.start() for t in ts]
[t.join() for t in ts]
print(" | ".join(f"{k}={v}" for k, v in sorted(res.items())), flush=True)
