"""Shared driver: one test protocol, one transcript, one result file per tool."""
import datetime, http.cookiejar, json, os, re, subprocess, sys, time, urllib.error, urllib.parse, urllib.request

OUT = os.environ["OUT"]; SINK = os.environ["SINK_URL"]; HERE = os.environ["HERE"]
FIRING = open(f"{OUT}/payload-firing.json", "rb").read()
RESOLVED = open(f"{OUT}/payload-resolved.json", "rb").read()

class Tool:
    name = "tool"
    def __init__(self):
        self.dir = f"{OUT}/{self.name}"; os.makedirs(self.dir, exist_ok=True)
        self.work = f"/tmp/lab27/{self.name}"; os.makedirs(self.work, exist_ok=True)
        self.tlog = open(f"{self.dir}/transcript.log", "a", buffering=1)
        self.r = {"tool": self.name, "steps_to_first_alert": [], "not_tested": [], "findings": []}
        self.cj = http.cookiejar.CookieJar()
        self.op = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.cj), NoRedirect())
        self.hdr = {}
    # logging
    def log(self, *a):
        s = " ".join(str(x) for x in a)
        self.tlog.write(f"[{datetime.datetime.now(datetime.timezone.utc).strftime('%H:%M:%S')}] {s}\n"); print(s[:300], flush=True)
    def save(self):
        json.dump(self.r, open(f"{self.dir}/result.json", "w"), indent=1, default=str)
    def step(self, text):
        self.r["steps_to_first_alert"].append(text); self.log("STEP", len(self.r["steps_to_first_alert"]), text); self.save()
    def note(self, text): self.r["findings"].append(text); self.log("FINDING", text); self.save()
    def untested(self, text): self.r["not_tested"].append(text); self.log("NOT TESTED", text); self.save()
    # shell and http
    def sh(self, cmd, timeout=600, cwd=None, check=False, trim=4000):
        self.log("$", cmd)
        p = subprocess.run(cmd, shell=True, cwd=cwd or self.work, timeout=timeout, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace")
        o = p.stdout
        self.log(f"exit={p.returncode}\n" + (o if len(o) < trim else o[:trim//2] + "\n...[trimmed]...\n" + o[-trim//2:]))
        if check and p.returncode: raise RuntimeError(f"{cmd} exit {p.returncode}")
        return p.returncode, o
    def http(self, method, url, body=None, headers=None, form=False, quiet=False, timeout=30, trim=2500):
        h = dict(self.hdr); h.update(headers or {}); data = None
        if isinstance(body, (bytes, bytearray)): data = bytes(body); h.setdefault("Content-Type", "application/json")
        elif form: data = urllib.parse.urlencode(body).encode(); h["Content-Type"] = "application/x-www-form-urlencoded"
        elif body is not None: data = json.dumps(body).encode(); h["Content-Type"] = "application/json"
        req = urllib.request.Request(url, data=data, headers=h, method=method)
        try:
            with self.op.open(req, timeout=timeout) as resp: code, txt = resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e: code, txt = e.code, e.read().decode("utf-8", "replace")
        except Exception as e: code, txt = 0, f"{type(e).__name__}: {e}"
        if not quiet:
            shown = (body if not isinstance(body, (bytes, bytearray)) else f"<{len(body)} bytes>")
            self.log(f"{method} {re.sub(r'token=[^& ]+', 'token=REDACTED', url)} body={str(shown)[:600]}\n-> {code} {txt[:trim]}")
        try: j = json.loads(txt)
        except Exception: j = None
        return code, j, txt
    def wait_http(self, url, timeout=300, ok=(200,)):
        t0 = time.time()
        while time.time() - t0 < timeout:
            c, _, _ = self.http("GET", url, quiet=True, timeout=5)
            if c in ok: return time.time() - t0
            time.sleep(2)
        raise TimeoutError(url)
    # sink
    def sink(self, prefix):
        try: rows = [json.loads(l) for l in open(f"{OUT}/sink.jsonl")]
        except FileNotFoundError: return []
        return [r for r in rows if r["path"].startswith(prefix)]
    def wait_sink(self, prefix, n=1, timeout=150):
        t0 = time.time()
        while time.time() - t0 < timeout:
            rows = self.sink(prefix)
            if len(rows) >= n: return rows
            time.sleep(1)
        return self.sink(prefix)
    # the protocol. Subclasses: install(), minimal(), post(body)->(code,text), alerts()->list, oncall()->dict
    def install(self): raise NotImplementedError
    def minimal(self): raise NotImplementedError
    def post(self, body): raise NotImplementedError
    def alerts(self): raise NotImplementedError
    def oncall(self): pass
    def after(self): pass
    def snap(self, label, wait=4):
        time.sleep(wait); a = self.alerts(); self.r.setdefault("alert_states", {})[label] = a; self.log("ALERTS", label, json.dumps(a)[:1500]); self.save(); return a
    def run(self):
        self.save(); t0 = time.time()
        try:
            self.install(); self.r["install_seconds"] = round(time.time() - t0, 1)
            self.minimal()
            self.log("--- A. first firing")
            code, txt = self.post(FIRING); self.r["firing_http"] = code; self.r["firing_body"] = txt[:400]
            deadline = time.time() + 60; a = []
            while time.time() < deadline:
                a = self.alerts()
                if a: break
                time.sleep(1)
            self.r["seconds_to_first_alert"] = round(time.time() - t0, 1)
            self.r["after_first_firing"] = a; self.log("ALERTS after first firing", json.dumps(a)[:1500]); self.save()
            self.log("--- B. repeat firing, same bytes")
            code, txt = self.post(FIRING); self.r["repeat_http"] = code
            self.snap("after_repeat")
            self.log("--- C. resolved")
            code, txt = self.post(RESOLVED); self.r["resolved_http"] = code; self.r["resolved_body"] = txt[:300]
            self.snap("after_resolved", wait=8)
            self.log("--- D. schedule and escalation")
            self.oncall()
        except Exception as e:
            self.r["error"] = f"{type(e).__name__}: {e}"; self.log("ERROR", self.r["error"])
            import traceback; self.log(traceback.format_exc())
        try: self.after()
        except Exception as e: self.log("after failed", e)
        self.r["total_seconds"] = round(time.time() - t0, 1); self.save()

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
    def http_error_302(self, req, fp, code, msg, hdrs): return fp
    http_error_301 = http_error_303 = http_error_307 = http_error_302

def iso(dt=None, **d):
    return ((dt or datetime.datetime.now(datetime.timezone.utc)) + datetime.timedelta(**d)).strftime("%Y-%m-%dT%H:%M:%SZ")
