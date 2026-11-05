import json, sys, os, time
sys.path.insert(0, os.environ["HERE"] + "/harness")
from lib import *
B = "http://localhost:8080"; TAG = "v2.4.0"

class IR(Tool):
    name = "incidentrelay"
    def dc(self, a, **k): return self.sh(f"docker compose {a}", cwd=self.work + "/src/docker", **k)
    def install(self):
        self.r["version"] = TAG
        self.sh(f"git clone -q --depth 1 -b {TAG} https://github.com/roxy-wi/IncidentRelay.git src", check=True)
        open(self.work + "/teardown.sh", "w").write(f"cd {self.work}/src/docker && docker compose down -v\n")
        self.step("git clone the repo")
        self.step("cd docker && docker compose up -d")
        open(self.work + "/src/docker/docker-compose.override.yml", "w").write("services:\n" + "".join(f"  {n}:\n    environment:\n      INCIDENTRELAY__SECURITY__OUTBOUND_PRIVATE_NETWORK_ALLOWLIST: 10.0.0.0/8,172.16.0.0/12\n" for n in ("incidentrelay", "incidentrelay-scheduler")))
        self.dc("up -d --wait", timeout=400)
        self.r["boot_seconds"] = round(self.wait_http(B + "/login"), 1)
        self.step("manage.py create-admin inside the container")
        c, o = self.dc("exec -T --user 10001:10001 incidentrelay python manage.py create-admin --username admin --password lab-password-1 --email admin@example.com", trim=700)
        if c:
            self.note("the documented create-admin command exits 1 with: insecure IncidentRelay secret configuration, because exec does not get the runtime config the entrypoint generates. It works with -e INCIDENTRELAY_CONFIG_FILE=/var/lib/incidentrelay/incidentrelay.conf")
            self.dc("exec -T --user 10001:10001 -e INCIDENTRELAY_CONFIG_FILE=/var/lib/incidentrelay/incidentrelay.conf incidentrelay python manage.py create-admin --username admin --password lab-password-1 --email admin@example.com", check=True)
    def minimal(self):
        c, j, t = self.http("POST", B + "/api/auth/login", {"username": "admin", "password": "lab-password-1"}, trim=200)
        self.hdr = {"Authorization": "Bearer " + (j.get("token") or j.get("access_token"))}
        self.step("create a group")
        c, g, t = self.http("POST", B + "/api/groups", {"slug": "prod", "name": "Production"}); self.g = g["id"]
        self.step("create a team")
        c, tm, t = self.http("POST", B + "/api/teams", {"group_id": self.g, "slug": "platform", "name": "Platform"}); self.tm = tm["id"]
        self.step("create a route with source alertmanager and copy its intake token")
        c, r, t = self.http("POST", B + "/api/routes", {"team_id": self.tm, "name": "alertmanager", "source": "alertmanager"}); self.route = r
        self.tok = r.get("intake_token")
    def post(self, body, path="alertmanager"):
        c, j, t = self.http("POST", f"{B}/api/integrations/{path}", bytes(body), headers={"Authorization": "Bearer " + str(self.tok)}); return c, t
    def alerts(self):
        c, j, t = self.http("GET", B + "/api/alert-groups", quiet=True)
        items = (j or {}).get("items") if isinstance(j, dict) else (j or [])
        self.raw_alert = (items or [None])[0]
        return [{"id": x.get("id"), "title": x.get("title"), "status": x.get("status"), "assignee": x.get("assignee_name") or x.get("assignee"), "alerts_count": x.get("alerts_count") or x.get("child_alerts_count") or x.get("occurrence_count")} for x in (items or [])]
    def oncall(self):
        self.log("raw alert group", json.dumps(self.raw_alert)[:1500])
        u = {}
        for n in ("alice", "bob"):
            c, j, t = self.http("POST", B + "/api/admin/users", {"username": n, "email": n + "@example.com", "password": "lab-password-1", "group_id": self.g}); u[n] = j["id"]
            self.http("POST", f"{B}/api/teams/{self.tm}/users", {"user_id": u[n], "role": "responder"})
        c, rot, t = self.http("POST", B + "/api/rotations", {"team_id": self.tm, "name": "primary", "start_at": iso(hours=-1), "rotation_type": "daily", "reminder_interval_seconds": 0})
        for i, n in enumerate(("alice", "bob")):
            self.http("POST", f"{B}/api/rotations/{rot['id']}/members", {"user_id": u[n], "position": i})
        c, ch, t = self.http("POST", B + "/api/channels", {"team_id": self.tm, "name": "lab-sink", "channel_type": "webhook", "config": {"webhook_url": f"{SINK}/incidentrelay/hook"}})
        c, p, t = self.http("POST", B + "/api/escalation-policies", {"team_id": self.tm, "name": "checkout-ep"})
        self.http("POST", f"{B}/api/escalation-policies/{p['id']}/rules", {"position": 1, "delay_seconds": 0, "target_type": "rotation", "target_id": rot["id"]})
        self.http("POST", f"{B}/api/escalation-policies/{p['id']}/rules", {"position": 2, "delay_seconds": 60, "target_type": "user", "target_id": u["bob"]})
        r = self.route
        self.http("PUT", f"{B}/api/routes/{r['id']}", {"team_id": self.tm, "name": "alertmanager", "source": "alertmanager", "rotation_id": rot["id"], "channel_ids": [ch["id"]], "escalation_mode": "policy", "escalation_policy_id": p["id"]})
        t0 = time.time(); self.post(FIRING)
        a = self.wait_sink("/incidentrelay/hook", 1, 60); t1 = time.time()
        for i in range(30):
            self.snap("mid", wait=4)
            b = [x for x in self.r["alert_states"]["mid"] if "bob" in str(x.get("assignee"))]
            if b: break
        t2 = time.time(); self.post(FIRING); time.sleep(20)
        rows = self.sink("/incidentrelay/hook")
        self.r["escalation"] = {"first_page_s": round(t1 - t0, 1) if a else None, "assignee_became_bob_s": round(t2 - t0, 1) if b else None, "posts": len(rows), "sample": [x["body"][:600] for x in rows[:3]]}
        self.snap("during_escalation"); self.post(RESOLVED); self.snap("after_final_resolve", wait=6)
        self.log("--- E. PagerDuty Events v2 body, as Alertmanager's pagerduty_configs sends it")
        c, j, t = self.http("POST", B + "/api/routes", {"team_id": self.tm, "name": "pd", "source": "webhook"})
        if j and j.get("intake_token"):
            c, _, t = self.http("POST", B + "/api/integrations/webhook", PD.replace(b"PLACEHOLDER_ROUTING_KEY", j["intake_token"].encode()))
            self.r["pagerduty_events_v2_http"] = c; self.snap("after_pagerduty_event")
        self.dc("logs incidentrelay-scheduler --tail=20")
        self.untested("Voice calls and SMS: IncidentRelay ships a stub voice provider, and you plug in your own. Delivery was tested with a generic webhook channel pointed at a local sink.")
    def after(self):
                self.sh("docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'")
IR().run()
