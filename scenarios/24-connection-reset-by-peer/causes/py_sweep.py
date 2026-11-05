# Keepalive race with requests.Session: reuse a connection just around the
# server's idle timeout. Connection pool checks stay on, as in production.
import collections, random, sys, threading, time, requests
url, idle, window, threads, rounds = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
res = collections.Counter(); lock = threading.Lock()
def work():
    time.sleep(random.random())
    for _ in range(rounds):
        s = requests.Session()
        try:
            s.post(url, data=b"x", timeout=5).content
        except Exception:
            continue
        time.sleep(idle + random.uniform(-window, window))
        try:
            s.post(url, data=b"x", timeout=5).content
            k = "ok"
        except Exception as e:
            k = f"{type(e).__name__}: {e}"
        with lock:
            res[k] += 1
        s.close()
ts = [threading.Thread(target=work) for _ in range(threads)]
[t.start() for t in ts]; [t.join() for t in ts]
for k, v in sorted(res.items()):
    print(f"{v:6d}  {k}")
