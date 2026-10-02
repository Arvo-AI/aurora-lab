#!/usr/bin/env python3
"""Cancel Aurora's prediscovery tasks in the lab stack while runs are going.

Aurora schedules a prediscovery agent run 10 minutes after a new connector is
added (utils/auth/token_management.py _schedule_prediscovery). The lab adds a
new kubeconfig for every fresh org, so each run would spawn one of these LLM
runs against a cluster that by then belongs to another run. They take celery
slots (concurrency 4) and stall the investigations being measured, and they
cost Bedrock money outside any incident. In a real deployment prediscovery runs
once, long before an incident. This loop revokes them; every revoke is logged.

    python3 runner/no_prediscovery.py runs/prediscovery-revoked.log
"""
import json
import subprocess
import sys
import time

WORKER = "aurora-lab-celery_worker-1"
NAME = "chat.background.prediscovery_task.run_prediscovery"


def inspect(what):
    r = subprocess.run(["docker", "exec", WORKER, "celery", "-A", "celery_config", "inspect", what, "--json"],
                       text=True, capture_output=True)
    lines = [l for l in r.stdout.splitlines() if l.startswith("{")]
    return json.loads(lines[-1]) if lines else {}


def main(log_path):
    seen = set()
    while True:
        found = []
        for what in ("active", "reserved", "scheduled"):
            for tasks in inspect(what).values():
                for t in tasks:
                    req = t.get("request", t)
                    if req.get("name") == NAME and (what == "active", req["id"]) not in seen:
                        found.append((what, req["id"], req.get("kwargs", {}).get("user_id")))
        for what, tid, uid in found:
            # Celery 5 has no "revoke --terminate"; revoke stops queued and ETA
            # tasks, terminate kills one that has already started.
            cmd = ["terminate", "SIGKILL", tid] if what == "active" else ["revoke", tid]
            r = subprocess.run(["docker", "exec", WORKER, "celery", "-A", "celery_config", "control", *cmd],
                               capture_output=True, text=True)
            if r.returncode != 0:
                with open(log_path, "a") as f:
                    f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} FAILED {cmd[0]} {tid}: {r.stderr.strip()[-200:]}\n")
                continue
            seen.add((what == "active", tid))
            with open(log_path, "a") as f:
                f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S%z')} revoked {what} prediscovery {tid} user {uid}\n")
        time.sleep(30)


if __name__ == "__main__":
    main(sys.argv[1])
