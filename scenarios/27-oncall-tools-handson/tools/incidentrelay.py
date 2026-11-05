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
        self.dc("up -d --wait", timeout=400)
        self.r["boot_seconds"] = round(self.wait_http(B + "/login"), 1)
        self.step("manage.py create-admin inside the container")
        self.dc("exec -T --user 10001:10001 incidentrelay python manage.py create-admin --username admin --password lab-password-1 --email admin@example.com", check=True)
    def minimal(self):
        c, j, t = self.http("POST", B + "/api/auth/login", {"username": "admin", "password": "lab-password-1"})
        self.hdr = {"Authorization": "Bearer " + (j.get("token") or j.get("access_token"))}
        self.step("create a group, a team, a rotation, a webhook channel and an alertmanager route")
        c, g, t = self.http("POST", B + "/api/groups", {"slug": "prod", "name": "Production"}); self.g = g["id"]
        c, tm, t = self.http("POST", B + "/api/teams", {"group_id": self.g, "slug": "platform", "name": "Platform"}); self.tm = tm["id"]
        c, r, t = self.http("POST", B + "/api/routes", {"team_id": self.tm, "name": "alertmanager", "source": "alertmanager"}); self.route = r
        self.tok = r.get("intake_token") or r.get("token")
    def post(self, body):
        c, j, t = self.http("POST", B + "/api/integrations/alertmanager", bytes(body), headers={"Authorization": "Bearer " + str(self.tok)}); return c, t
    def alerts(self):
        c, j, t = self.http("GET", B + "/api/alerts", quiet=True)
        items = (j or {}).get("items") or (j or {}).get("alerts") if isinstance(j, dict) else (j or [])
        return [{"id": x.get("id"), "title": x.get("title"), "status": x.get("status"), "count": x.get("alerts_count") or x.get("occurrence_count") or x.get("event_count")} for x in (items or [])]
    def oncall(self):
        self.untested("todo")
    def after(self):
        self.http("GET", B + "/api/openapi.json", trim=200)
        self.sh("docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'")
IR().run()
