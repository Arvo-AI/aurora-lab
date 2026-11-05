"""Grafana OnCall hobby stack, used for upstream OSS and for the Appwrite fork."""
import json, os, sys, time
from lib import *
G = "http://localhost:3000"; E_ = "http://localhost:8080"
AUTH = {"Authorization": "Basic YWRtaW46YWRtaW4="}
MAILPIT = """
  mailpit:
    image: axllent/mailpit:v1.33.0
    ports: ["8025:8025"]
"""
class OnCall(Tool):
    repo = ""; tag = ""; compose_url = ""; extra_env = ""
    def dc(self, a, **k): return self.sh(f"docker compose -f docker-compose.yml -f override.yml {a}", **k)
    def install(self):
        self.r["version"] = self.tag
        self.step("download docker-compose.yml")
        self.sh(f"curl -fsSL {self.compose_url} -o docker-compose.yml", check=True)
        self.step("write .env: DOMAIN, COMPOSE_PROFILES=with_grafana, SECRET_KEY")
        open(self.work + "/.env", "w").write(f"DOMAIN=http://localhost:8080\nCOMPOSE_PROFILES=with_grafana\nSECRET_KEY=lab_only_secret_key_more_than_32_chars_long\n{self.extra_env}")
        open(self.work + "/override.yml", "w").write(self.override())
        open(self.work + "/teardown.sh", "w").write(f"cd {self.work} && docker compose -f docker-compose.yml -f override.yml down -v\n")
        self.step("docker compose pull && docker compose up -d")
        self.dc("pull", timeout=400)
        self.dc("up -d --wait --wait-timeout 300", timeout=420)
        self.sh("docker compose -f docker-compose.yml -f override.yml ps -a --format '{{.Service}} {{.Image}} {{.Status}}'")
        self.wait_http(E_ + "/health/", timeout=200, ok=(200,))
        self.wait_http(G + "/api/health", timeout=120)
        self.sh("docker compose -f docker-compose.yml -f override.yml logs grafana --tail=40 | grep -iE 'plugin|oncall|error' | tail -15")
        self.http("GET", G + "/api/health"); 
        self.http("GET", G + "/api/plugins/grafana-oncall-app/settings", headers=AUTH, trim=500)
        self.step("provision the plugin: POST .../settings then POST .../resources/plugin/install")
        self.http("POST", G + "/api/plugins/grafana-oncall-app/settings", {"enabled": True, "jsonData": {"stackId": 5, "orgId": 100, "onCallApiUrl": "http://engine:8080", "grafanaUrl": "http://grafana:3000"}}, headers=AUTH)
        for i in range(20):
            c, j, t = self.http("POST", G + "/api/plugins/grafana-oncall-app/resources/plugin/install", headers=AUTH, trim=300)
            time.sleep(3); c, st, t = self.http("GET", G + "/api/plugins/grafana-oncall-app/resources/plugin/status", headers=AUTH, trim=500)
            if st and all(v.get("ok") for v in st["pluginConnection"].values()):
                self.r["plugin_install_attempts"] = i + 1; break
            time.sleep(3)
    def override(self):
        return "services:\n" + MAILPIT + self.env_block()
    def env_block(self):
        e = """
      EMAIL_HOST: mailpit
      EMAIL_PORT: "1025"
      EMAIL_USE_TLS: "False"
      EMAIL_FROM_ADDRESS: oncall@example.com
      FEATURE_EMAIL_INTEGRATION_ENABLED: "True"
"""
        return "  engine:\n    environment:" + e + "  celery:\n    environment:" + e + self.grafana_block()
    def grafana_block(self): return ""
    def minimal(self):
        self.http("POST", G + "/api/plugins/grafana-oncall-app/resources/plugin/sync", headers=AUTH, trim=300)
        time.sleep(3)
        c, j, t = self.http("POST", G + "/api/plugins/grafana-oncall-app/resources/tokens/", {"name": "lab"}, headers=AUTH)
        if c not in (200, 201) or not j: raise RuntimeError(f"token {c}")
        self.hdr = {"Authorization": j.get("token")}
        self.step("create an integration of type alertmanager (UI or public API)")
        c, j, t = self.http("POST", E_ + "/api/v1/integrations/", {"type": "alertmanager", "name": "prometheus"})
        self.intg = j; self.url = j["link"]; self.route = j["default_route"]["id"]
    def post(self, body):
        c, j, t = self.http("POST", self.url, bytes(body)); return c, t
    def alerts(self):
        c, j, t = self.http("GET", E_ + "/api/v1/alert_groups/", quiet=True)
        return [{"id": x.get("id"), "title": x.get("title"), "state": x.get("state"), "alerts_count": x.get("alerts_count")} for x in (j or {}).get("results", [])]
    def mail(self):
        c, j, t = self.http("GET", "http://localhost:8025/api/v1/messages", quiet=True)
        return [(m["To"][0]["Address"], m["Subject"], m["Created"]) for m in (j or {}).get("messages", [])]
    def oncall(self):
        for n in ("alice", "bob"):
            c, j, t = self.http("POST", G + "/api/admin/users", {"name": n, "email": n + "@example.com", "login": n, "password": "lab-password-1"}, headers=AUTH)
            self.http("PATCH", f"{G}/api/org/users/{j['id']}", {"role": "Editor"}, headers=AUTH)
        ids = {}
        for i in range(40):
            self.http("POST", G + "/api/plugins/grafana-oncall-app/resources/plugin/sync", headers=AUTH, trim=100); time.sleep(8)
            c, j, t = self.http("GET", E_ + "/api/v1/users/", trim=200)
            ids = {u["username"]: u["id"] for u in j["results"]}
            if "alice" in ids and "bob" in ids: self.r["user_sync_seconds"] = (i + 1) * 8; break
        for n in ("alice", "bob"):
            self.http("POST", E_ + "/api/v1/personal_notification_rules/", {"user_id": ids[n], "type": "notify_by_email", "position": 0})
        c, sh, t = self.http("POST", E_ + "/api/v1/on_call_shifts/", {"name": "primary", "type": "rolling_users", "start": iso(hours=-1)[:-1], "duration": 86400, "frequency": "daily", "rolling_users": [[ids["alice"]], [ids["bob"]]], "start_rotation_from_user_index": 0, "time_zone": "UTC"})
        c, s, t = self.http("POST", E_ + "/api/v1/schedules/", {"name": "primary", "type": "calendar", "time_zone": "UTC", "shifts": [sh["id"]]})
        time.sleep(5); self.http("GET", f"{E_}/api/v1/schedules/{s['id']}/")
        c, ch, t = self.http("POST", E_ + "/api/v1/escalation_chains/", {"name": "checkout"})
        for i, p in enumerate(({"type": "notify_on_call_from_schedule", "notify_on_call_from_schedule": s["id"]}, {"type": "wait", "duration": 60}, {"type": "notify_persons", "persons_to_notify": [ids["bob"]]})):
            self.http("POST", E_ + "/api/v1/escalation_policies/", dict(p, escalation_chain_id=ch["id"], position=i))
        self.http("PUT", f"{E_}/api/v1/routes/{self.route}/", {"escalation_chain_id": ch["id"]})
        t0 = time.time(); self.post(FIRING); ta = tb = None
        while time.time() - t0 < 170:
            m = self.mail()
            if ta is None and any(x[0].startswith("alice") for x in m): ta = time.time() - t0
            if tb is None and any(x[0].startswith("bob") for x in m): tb = time.time() - t0; break
            time.sleep(2)
        self.post(FIRING); time.sleep(20)
        self.r["escalation"] = {"first_page_s": ta and round(ta, 1), "second_page_s": tb and round(tb, 1), "mail": self.mail()}
        self.snap("during_escalation"); self.post(RESOLVED); self.snap("after_final_resolve", wait=8)
        self.dc("logs celery --tail=15")
        self.untested("SMS and phone: needs your own Twilio, Exotel or Zvonok account since Grafana's Cloud Connection stopped serving OSS. Mobile push does not work. Delivery was tested with email to a local Mailpit.")
    def after(self):
        self.sh("docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'")
