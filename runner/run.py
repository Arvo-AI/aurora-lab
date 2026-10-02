#!/usr/bin/env python3
"""Run lab scenarios against a local Aurora and record everything.

For each scenario: reset the shop app, inject the fault, capture cluster
evidence, give Aurora only the alert text, wait for its investigation to
finish, and save the incident, the full timeline (every tool call and thought)
and the final root cause. Grading is a separate step (grade.py).

    python3 runner/run.py setup
    python3 runner/run.py run [scenario ...] [--run-id ID] [--repeats N]
                              [--clusters aurora-lab,aurora-lab-2,...]

Every (scenario, repeat) gets a fresh Aurora user and org, so no memory,
artifact or incident list carries over from one investigation to the next.
With several clusters, one lane runs per cluster, in parallel.

Config comes from the environment:
    AURORA_URL        default http://127.0.0.1:15080
    AURORA_ENV_FILE   the Aurora .env (for INTERNAL_API_SECRET)
"""
import argparse
import json
import os
import queue
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STATE = ROOT / "runner" / ".state.json"
AURORA = os.environ.get("AURORA_URL", "http://127.0.0.1:15080").rstrip("/")
ENV_FILE = Path(os.environ.get("AURORA_ENV_FILE", Path.home() / "Dev/aurora-lab-stack/.env"))
LAB_EMAIL = "lab@aurora-lab.local"
TERMINAL = {"complete", "error", "hook_blocked"}
RCA_TIMEOUT_S = 40 * 60


def env_value(key):
    for line in ENV_FILE.read_text().splitlines():
        if line.startswith(key + "="):
            return line.split("=", 1)[1].strip().strip('"')
    return ""


def api(method, path, body=None, auth=True, ident=None):
    headers = {"Content-Type": "application/json"}
    secret = env_value("INTERNAL_API_SECRET")
    if secret:
        headers["X-Internal-Secret"] = secret
    if auth:
        st = ident or json.loads(STATE.read_text())
        headers["X-User-ID"] = st["user_id"]
        headers["X-Org-ID"] = st["org_id"]
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(AURORA + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return r.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"raw": raw.decode(errors="replace")[:2000]}


def sh(*cmd, check=True, cluster=None):
    env = dict(os.environ, LAB_CLUSTER=cluster) if cluster else None
    return subprocess.run(cmd, check=check, text=True, capture_output=True, env=env)


def internal_kubeconfig(cluster):
    """The kubeconfig Aurora gets: API server addressed by node name on the kind
    network. Context, cluster and user names are rewritten to kind-aurora-lab so
    every lane looks the same to Aurora (node names still differ)."""
    kc = sh("kind", "get", "kubeconfig", "--internal", "--name", cluster).stdout
    if cluster != "aurora-lab":
        kc = kc.replace(f"kind-{cluster}", "kind-aurora-lab")
    return kc


def upload_kubeconfig(ident, cluster):
    code, out = api("POST", "/api/kubeconfig/upload",
                    {"kubeconfigs": [{"filename": "aurora-lab.yaml", "content": internal_kubeconfig(cluster)}]},
                    ident=ident)
    if code >= 300 or out.get("errors"):
        raise RuntimeError(f"kubeconfig upload failed: {code} {out}")
    code, out = api("GET", "/api/kubeconfig/clusters", ident=ident)
    if not out.get("clusters"):
        raise RuntimeError(f"no cluster visible after upload: {code} {out}")
    return out["clusters"]


def fresh_identity(run_id, sid, n):
    """Register a new user and org for one (scenario, repeat)."""
    tag = f"{run_id}-{sid[:2]}-{n}-{secrets.token_hex(3)}"
    code, me = api("POST", "/api/auth/register", {
        "email": f"lab+{tag}@aurora-lab.local", "password": secrets.token_urlsafe(18),
        "name": "Aurora Lab", "org_name": f"Aurora Lab {tag}",
    }, auth=False)
    if code not in (200, 201):
        raise RuntimeError(f"register failed: {code} {me}")
    return {"user_id": me["id"], "org_id": me["orgId"], "email": f"lab+{tag}@aurora-lab.local"}


def setup():
    password = env_value("LAB_USER_PASSWORD") or "aurora-lab-" + env_value("AUTH_SECRET")[:16]
    code, me = api("POST", "/api/auth/register", {
        "email": LAB_EMAIL, "password": password, "name": "Aurora Lab", "org_name": "Aurora Lab",
    }, auth=False)
    if code not in (200, 201):
        code, me = api("POST", "/api/auth/login", {"email": LAB_EMAIL, "password": password}, auth=False)
    if code != 200 and code != 201:
        sys.exit(f"could not register or log in the lab user: {code} {me}")
    STATE.write_text(json.dumps({"user_id": me["id"], "org_id": me["orgId"]}, indent=2))
    print(f"lab user {me['id']} org {me['orgId']}")

    # Aurora reaches the cluster from inside its containers on the kind network,
    # so it gets the internal kubeconfig (API server addressed by node name).
    kubeconfig = internal_kubeconfig("aurora-lab")
    code, out = api("GET", "/api/kubeconfig/clusters")
    already = [c for c in (out.get("clusters") or []) if "aurora-lab" in json.dumps(c)]
    if not already:
        code, out = api("POST", "/api/kubeconfig/upload",
                        {"kubeconfigs": [{"filename": "aurora-lab.yaml", "content": kubeconfig}]})
        if code >= 300 or out.get("errors"):
            sys.exit(f"kubeconfig upload failed: {code} {out}")
    code, out = api("GET", "/api/kubeconfig/clusters")
    print("clusters:", json.dumps(out, indent=1)[:800])


def load_scenario(sid):
    d = next((p for p in sorted((ROOT / "scenarios").iterdir()) if p.name.startswith(sid)), None)
    if not d:
        sys.exit(f"unknown scenario {sid}")
    meta = {}
    # scenario.yaml is flat enough to read without a YAML dependency for the
    # fields the runner needs; grade.py reads the whole file.
    for line in (d / "scenario.yaml").read_text().splitlines():
        for key in ("id", "title", "alert"):
            if line.startswith(key + ":"):
                meta[key] = line.split(":", 1)[1].strip().strip('"')
    return d, meta


UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def isolation_check(timeline, incident_id):
    """In a fresh org, list_incidents must show no incident but this one."""
    calls = [s for s in timeline.get("steps") or [] if s.get("tool_name") == "list_incidents"]
    foreign = sorted({u for s in calls for u in UUID.findall(str(s.get("tool_output") or ""))} - {incident_id})
    return {"list_incidents_calls": len(calls), "foreign_incident_ids": foreign,
            "first_output": str(calls[0].get("tool_output"))[:300] if calls else None}


def run_one(sid, n, run_dir, run_id, cluster, log):
    d, meta = load_scenario(sid)
    out = run_dir / d.name / f"r{n}"
    out.mkdir(parents=True, exist_ok=True)
    t0 = datetime.now(timezone.utc)
    lab = str(ROOT / "lab.sh")
    br = sh(lab, "break", d.name, check=False, cluster=cluster)
    (out / "break.log").write_text(br.stdout + br.stderr)
    if br.returncode != 0:
        log(f"{d.name} r{n} [{cluster}]: fault did not appear, skipping")
        return None
    sh(lab, "evidence", d.name, str(out / "evidence-before"), cluster=cluster)

    ident = fresh_identity(run_id, d.name, n)
    clusters = upload_kubeconfig(ident, cluster)
    body = {
        "issue_description": meta["alert"] + " Cluster: aurora-lab (kubeconfig). Investigate and find the root cause.",
        "title": meta["alert"].split(":")[0],
        "service": "shop",
        "severity": "high",
    }
    code, trig = api("POST", "/api/incidents/trigger-rca", body, ident=ident)
    (out / "trigger.json").write_text(json.dumps(
        {"request": body, "status": code, "response": trig, "cluster": cluster,
         "user_id": ident["user_id"], "org_id": ident["org_id"], "aurora_clusters": clusters}, indent=2))
    incident_id = trig.get("incident_id")
    if not incident_id:
        log(f"{d.name} r{n} [{cluster}]: trigger failed {code} {trig}")
        return None
    log(f"{d.name} r{n} [{cluster}]: incident {incident_id}")

    status, inc = "", {}
    deadline = time.time() + RCA_TIMEOUT_S
    while time.time() < deadline:
        time.sleep(15)
        code, inc = api("GET", f"/api/incidents/{incident_id}", ident=ident)
        status = (inc.get("incident") or {}).get("auroraStatus", "")
        if status in TERMINAL:
            break
    # The summary is written by a separate task after the investigation ends.
    for _ in range(20):
        if (inc.get("incident") or {}).get("summary"):
            break
        time.sleep(6)
        code, inc = api("GET", f"/api/incidents/{incident_id}", ident=ident)
    code, timeline = api("GET", f"/api/monitor/incidents/{incident_id}/timeline", ident=ident)
    (out / "incident.json").write_text(json.dumps(inc, indent=2))
    (out / "timeline.json").write_text(json.dumps(timeline, indent=2))
    # The timeline API truncates tool output at 4000 chars; keep the full rows too.
    full = sh("docker", "exec", "aurora-lab-postgres-1", "psql", "-U", env_value("POSTGRES_USER"),
              "-d", env_value("POSTGRES_DB"), "-At", "-c",
              "SELECT coalesce(json_agg(row_to_json(e) ORDER BY e.started_at, e.step_index), '[]') "
              f"FROM execution_steps e WHERE e.incident_id = '{incident_id}'", check=False)
    (out / "steps-full.json").write_text(full.stdout or full.stderr)
    summary = (inc.get("incident") or {}).get("summary") or ""
    (out / "aurora-rca.md").write_text(summary)
    s = timeline.get("summary") or {}
    result = {
        "scenario": d.name,
        "repeat": n,
        "cluster": cluster,
        "incident_id": incident_id,
        "user_id": ident["user_id"],
        "org_id": ident["org_id"],
        "aurora_status": status or "timeout",
        "started_at": t0.isoformat(),
        "duration_seconds": s.get("duration_seconds"),
        "tool_calls": s.get("total_tool_calls"),
        "tool_errors": s.get("tool_errors"),
        "llm_calls": s.get("total_llm_calls"),
        "tokens": s.get("total_tokens"),
        "cost_usd": s.get("total_cost"),
        "isolation": isolation_check(timeline, incident_id),
    }
    (out / "result.json").write_text(json.dumps(result, indent=2))
    log(f"{d.name} r{n} [{cluster}]: {result['aurora_status']} in {result['duration_seconds']}s, "
        f"{result['tool_calls']} tool calls, ${result['cost_usd']}, "
        f"foreign incidents {len(result['isolation']['foreign_incident_ids'])}")
    return result


def image_provenance():
    """Image IDs and the code each lab container actually runs."""
    out = {}
    for c in ("aurora-lab-aurora-server-1", "aurora-lab-celery_worker-1", "aurora-lab-chatbot-1"):
        r = sh("docker", "inspect", c, "--format", "{{.Config.Image}} {{.Image}}", check=False)
        tag, _, image_id = r.stdout.strip().partition(" ")
        out[c] = {"image": tag, "image_id": image_id}
    return out


def run(ids, run_id, repeats, clusters):
    if not ids:
        ids = [p.name for p in sorted((ROOT / "scenarios").iterdir()) if p.is_dir()]
    ids = [load_scenario(i)[0].name for i in ids]
    run_dir = ROOT / "runs" / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    stack = ENV_FILE.parent
    aurora_commit = sh("git", "-C", str(stack), "rev-parse", "HEAD", check=False).stdout.strip()
    dirty = sh("git", "-C", str(stack), "status", "--porcelain", "--untracked-files=no", check=False).stdout.strip()
    (run_dir / "run.json").write_text(json.dumps({
        "run_id": run_id,
        # server code is bind-mounted from the stack worktree, so this is the code that ran
        "aurora_commit": aurora_commit,
        "aurora_worktree_dirty": bool(dirty),
        "aurora_branch": sh("git", "-C", str(stack), "rev-parse", "--abbrev-ref", "HEAD", check=False).stdout.strip(),
        "images": image_provenance(),
        "rca_model": env_value("RCA_MODEL"),
        "orchestrator_enabled": env_value("ORCHESTRATOR_ENABLED"),
        "scenarios": ids,
        "repeats": repeats,
        "clusters": clusters,
        "isolation": "fresh user and org per (scenario, repeat)",
    }, indent=2))
    jobs = queue.Queue()
    # repeat-major order, so a short run still covers every scenario once
    for n in range(1, repeats + 1):
        for sid in ids:
            jobs.put((sid, n))
    lock = threading.Lock()
    logf = open(run_dir / "run.log", "a")

    def log(msg):
        line = f"{datetime.now().strftime('%H:%M:%S')} {msg}"
        with lock:
            print(line, flush=True)
            logf.write(line + "\n")
            logf.flush()

    def lane(cluster):
        while True:
            try:
                sid, n = jobs.get_nowait()
            except queue.Empty:
                break
            if (ROOT / "runs" / run_id / "STOP").exists():
                log(f"[{cluster}] STOP file present, lane exits")
                break
            try:
                run_one(sid, n, run_dir, run_id, cluster, log)
            except Exception as e:  # keep the lane going; the error is in the log
                log(f"{sid} r{n} [{cluster}]: ERROR {e!r}")
        sh(str(ROOT / "lab.sh"), "reset", check=False, cluster=cluster)

    threads = []
    for i, c in enumerate(clusters):
        t = threading.Thread(target=lane, args=(c,))
        t.start()
        threads.append(t)
        time.sleep(20)  # stagger the lanes a little
    for t in threads:
        t.join()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["setup", "run"])
    ap.add_argument("scenarios", nargs="*")
    ap.add_argument("--run-id", default=datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ"))
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--clusters", default=os.environ.get("LAB_CLUSTER", "aurora-lab"),
                    help="comma-separated kind clusters, one lane each")
    a = ap.parse_args()
    if a.cmd == "setup":
        setup()
    else:
        run(a.scenarios, a.run_id, a.repeats, a.clusters.split(","))


if __name__ == "__main__":
    main()
