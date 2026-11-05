import json, sys, os, time
sys.path.insert(0, os.environ["HERE"] + "/harness")
from lib import *
B = "http://localhost:8080"; TAG = "v1.2.4"

class Regen(Tool):
    name = "regen"
    def install(self):
        self.r["version"] = TAG
        os.makedirs(self.work + "/readme", exist_ok=True)
        self.log("README path: curl the compose file and run it, no clone")
        self.sh(f"curl -fsSLO https://raw.githubusercontent.com/FluidifyAI/Regen/{TAG}/docker-compose.yml && docker compose up -d", cwd=self.work + "/readme", timeout=120)
        self.sh("docker compose down -v", cwd=self.work + "/readme")
        self.sh(f"git clone -q --depth 1 -b {TAG} https://github.com/FluidifyAI/Regen.git src", check=True)
        open(self.work + "/src/override.yml", "w").write("services:\n  app:\n    image: ghcr.io/fluidifyai/regen:1.2.4\n    pull_policy: always\n    build: !reset null\n")
        open(self.work + "/teardown.sh", "w").write(f"cd {self.work}/src && docker compose -f docker-compose.yml -f override.yml down -v\n")
        self.step("git clone the repo and cp .env.example .env")
        self.sh("cp .env.example .env", cwd=self.work + "/src")
        self.log("first start with stock settings")
        self.sh("docker compose -f docker-compose.yml -f override.yml up -d; sleep 12; docker compose -f docker-compose.yml -f override.yml ps -a --format '{{.Service}} {{.Status}}'; docker compose -f docker-compose.yml -f override.yml logs app --tail=200 | grep -m2 'SAML_BASE_URL must'; docker compose -f docker-compose.yml -f override.yml down -v", cwd=self.work + "/src", timeout=200, trim=2500)
        self.sh("docker compose -f docker-compose.yml -f override.yml config | grep -E 'SAML_IDP_METADATA_URL|TEAMS_APP_ID|SLACK_BOT_TOKEN|OPENAI_API_KEY'", cwd=self.work + "/src", trim=1200)
        self.sh("sed -E -i 's/[[:space:]]+#.*$//' .env; docker compose -f docker-compose.yml -f override.yml config | grep -E 'SAML_IDP_METADATA_URL|TEAMS_APP_ID'", cwd=self.work + "/src", trim=800)
        self.step("strip the inline comments from .env: on empty keys they are read as values, so SAML and Teams switch on and the app exits in a loop")
        self.step("docker compose up -d with the app service pointed at the published image ghcr.io/fluidifyai/regen:1.2.4 instead of building")
        self.sh("docker compose -f docker-compose.yml -f override.yml up -d --wait", cwd=self.work + "/src", timeout=400)
        self.sh("docker compose -f docker-compose.yml -f override.yml ps -a; docker compose -f docker-compose.yml -f override.yml logs app --tail=60", cwd=self.work + "/src", trim=6000)
        self.r["boot_seconds"] = round(self.wait_http(B + "/health", timeout=60), 1)
    def minimal(self):
        self.step("create the first admin account (first-run page or POST /api/v1/auth/bootstrap)")
        c, j, t = self.http("POST", B + "/api/v1/auth/bootstrap", {"email": "admin@example.com", "name": "admin", "password": "lab-password-1"})
        self.http("POST", B + "/api/v1/auth/login/setup-token", {"token": j["setup_token"]})
        self.step("point Alertmanager at /api/v1/webhooks/prometheus (no token, no integration object)")
    def post(self, body):
        c, j, t = self.http("POST", B + "/api/v1/webhooks/prometheus", bytes(body)); return c, t
    def alerts(self):
        c, j, t = self.http("GET", B + "/api/v1/alerts?limit=50", quiet=True)
        al = (j or {}).get("data") or (j or {}).get("alerts") or []
        c2, j2, _ = self.http("GET", B + "/api/v1/incidents?limit=50", quiet=True)
        inc = (j2 or {}).get("data") or (j2 or {}).get("incidents") or []
        return [{"alert": x.get("title"), "status": x.get("status"), "id": x.get("external_id")} for x in al] + [{"incident": x.get("title"), "status": x.get("status")} for x in inc]
    def oncall(self):
        for u in ("alice", "bob"):
            self.http("POST", B + "/api/v1/settings/users", {"email": f"{u}@example.com", "name": u, "role": "member", "password": "lab-password-1"})
        c, j, t = self.http("GET", B + "/api/v1/settings/users/limit")
        self.log("user limit probe: add users until refused")
        for i in range(3, 10):
            c, j, t = self.http("POST", B + "/api/v1/settings/users", {"email": f"user{i}@example.com", "name": f"user{i}", "role": "member", "password": "lab-password-1"}, trim=300)
            if c >= 400:
                self.note(f"user {i + 1} refused: HTTP {c} {t[:220]}"); break
        c, s, t = self.http("POST", B + "/api/v1/schedules", {"name": "primary", "timezone": "UTC"})
        c, l, t = self.http("POST", f"{B}/api/v1/schedules/{s['id']}/layers", {"name": "l1", "order_index": 0, "rotation_type": "daily", "rotation_start": iso(hours=-1), "participants": [{"user_name": "alice", "order_index": 0}, {"user_name": "bob", "order_index": 1}]})
        self.http("GET", f"{B}/api/v1/schedules/{s['id']}/oncall")
        c, p, t = self.http("POST", B + "/api/v1/escalation-policies", {"name": "checkout-ep"})
        self.http("POST", f"{B}/api/v1/escalation-policies/{p['id']}/tiers", {"timeout_seconds": 60, "target_type": "schedule", "schedule_id": s["id"]})
        self.http("POST", f"{B}/api/v1/escalation-policies/{p['id']}/tiers", {"timeout_seconds": 60, "target_type": "users", "user_names": ["bob"]})
        self.http("POST", B + "/api/v1/routing-rules", {"name": "all", "priority": 1, "match_criteria": {"source": ["prometheus"]}, "actions": {"create_incident": True, "escalation_policy_id": p["id"]}})
        self.log("the earlier incident stays open and a re-fire of the same fingerprints joins it, so this firing uses new fingerprints to open a new incident under the policy")
        fresh = FIRING.replace(b"d77e5210e3203776", b"aaaa5210e3203776").replace(b"5d3b118068113e9d", b"bbbb118068113e9d")
        t0 = time.time(); self.post(fresh); time.sleep(100)
        self.sh("docker compose -f docker-compose.yml -f override.yml exec -T db psql -U regen -d regen -c 'select status,current_tier_index,last_notified_at,created_at from escalation_states'", cwd=self.work + "/src")
        self.sh("docker compose -f docker-compose.yml -f override.yml logs app --tail=40 | grep -iE 'escalat|notif|dm' | tail -20", cwd=self.work + "/src")
        self.snap("during_escalation", wait=1); self.post(RESOLVED); self.post(fresh.replace(b'"status":"firing"', b'"status":"resolved"')); self.snap("after_final_resolve", wait=6)
        self.untested("Delivery: Regen's escalation engine sends DMs through Slack, Teams or Telegram and has no outbound webhook, so no notification reached a person. We read the escalation state from its database, and it records tier and notification time only.")
    def after(self):
        self.sh("docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'")
Regen().run()
