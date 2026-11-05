import json, sys, os, time
sys.path.insert(0, os.environ["HERE"] + "/harness")
from lib import *
B = "http://localhost:18080"; TAG = "v1.9.23"; KEY = "lab-api-key-0123456789"

class Nxs(Tool):
    name = "nxs-anomaly"
    def dc(self, a, **k): return self.sh(f"docker compose -f docker-compose.yml -f override.yml {a}", cwd=self.work + "/src", **k)
    def install(self):
        self.r["version"] = TAG
        self.sh(f"git clone -q --depth 1 -b {TAG} https://github.com/nixys/nxs-anomaly.git src", check=True)
        self.step("git clone at the release tag, cp .env.example .env and fill in the version, Postgres password and admin password")
        open(self.work + "/src/.env", "w").write(open(self.work + "/src/.env.example").read() + f"\nNXS_ANOMALY_VERSION={TAG}\nPOSTGRES_PASSWORD=lab-password-1\nNXS_ANOMALY_BOOTSTRAP_ADMIN_PASSWORD=lab-password-1\nNXS_ANOMALY_API_KEY={KEY}\nNXS_ANOMALY_BLOCK_PRIVATE_WEBHOOKS_EXCEPT=172.16.0.0/12,10.0.0.0/8\n")
        self.sh("grep -nE 'ports|127.0.0.1|8080' docker-compose.yml | head -20; tail -12 .env", cwd=self.work + "/src")
        open(self.work + "/src/override.yml", "w").write('services:\n  app:\n    ports: ["18080:8080"]\n')
        open(self.work + "/teardown.sh", "w").write(f"cd {self.work}/src && docker compose -f docker-compose.yml -f override.yml down -v\n")
        self.step("docker compose up -d --wait")
        self.dc("up -d --wait --wait-timeout 180", timeout=400)
        self.r["boot_seconds"] = round(self.wait_http(B + "/health"), 1)
        self.hdr = {"X-API-Key": KEY}
    def minimal(self):
        self.step("create an integration of type alertmanager in the UI or API")
        c, j, t = self.http("POST", B + "/api/v1/integrations", {"name": "prometheus", "type": "alertmanager"})
        self.intg = j; self.url = f"{B}/integrations/v1/alertmanager/{j['key']}"
    def post(self, body):
        c, j, t = self.http("POST", self.url, bytes(body)); return c, t
    def alerts(self):
        c, j, t = self.http("GET", B + "/api/v1/alert-groups", quiet=True)
        items = (j or {}).get("items") or (j if isinstance(j, list) else [])
        return [{"title": x.get("title"), "status": x.get("status"), "alert_count": x.get("alert_count"), "id": x.get("id")} for x in items]
    def oncall(self):
        u = {}
        for n in ("alice", "bob"):
            c, j, t = self.http("POST", B + "/api/v1/users", {"name": n, "username": n, "email": n + "@example.com", "notification_targets": [{"type": "webhook", "target": f"{SINK}/nxs/{n}"}]})
            u[n] = j["id"]
        c, tm, t = self.http("POST", B + "/api/v1/teams", {"name": "platform", "member_ids": list(u.values())})
        c, s, t = self.http("POST", B + "/api/v1/schedules", {"name": "primary", "team_id": tm["id"], "timezone": "UTC", "enabled": True, "rotation": {"enabled": True, "start_at": iso(hours=-1), "handoff_interval": 1, "handoff_unit": "days", "participant_ids": [u["alice"], u["bob"]]}})
        self.http("GET", f"{B}/api/v1/schedules/{s['id']}/on-call")
        c, ch, t = self.http("POST", B + "/api/v1/escalation-chains", {"name": "checkout", "team_id": tm["id"], "steps": [{"kind": "NOTIFY_SCHEDULE", "schedule_id": s["id"]}, {"kind": "WAIT", "delay_minutes": 1}, {"kind": "NOTIFY_USER", "user_ids": [u["bob"]]}]})
        self.http("PUT", f"{B}/api/v1/integrations/{self.intg['id']}", {"name": "prometheus", "type": "alertmanager", "team_id": tm["id"], "default_chain_id": ch["id"]})
        self.http("GET", B + "/api/v1/readiness")
        t0 = time.time(); self.post(FIRING)
        a = self.wait_sink("/nxs/alice", 1, 60); t1 = time.time()
        b = self.wait_sink("/nxs/bob", 1, 150); t2 = time.time()
        self.post(FIRING); time.sleep(20)
        self.r["escalation"] = {"first_page_s": round(t1 - t0, 1) if a else None, "second_page_s": round(t2 - t0, 1) if b else None, "alice_posts": len(self.sink("/nxs/alice")), "bob_posts": len(self.sink("/nxs/bob")), "sample": (a or [{}])[0].get("body", "")[:500]}
        self.dc("logs worker --tail=30")
        self.http("GET", B + "/api/v1/notifications")
        self.snap("during_escalation"); self.post(RESOLVED); self.snap("after_final_resolve", wait=6)
        self.log("--- E. PagerDuty Events v2 body, as Alertmanager's pagerduty_configs sends it")
        c, j, t = self.http("POST", B + "/api/v1/integrations", {"name": "pd", "type": "pagerduty"})
        if j and j.get("key"):
            c, _, t = self.http("POST", f"{B}/integrations/v1/pagerduty/{j['key']}", PD.replace(b"PLACEHOLDER_ROUTING_KEY", j["key"].encode()))
            self.r["pagerduty_events_v2_http"] = c; self.snap("after_pagerduty_event")
    def after(self):
        self.sh("docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'")
Nxs().run()
