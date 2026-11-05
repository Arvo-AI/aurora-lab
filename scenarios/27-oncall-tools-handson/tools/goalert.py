import json, sys, os, time
sys.path.insert(0, os.environ["HERE"] + "/harness")
from lib import *

COMPOSE = """
services:
  db:
    image: postgres:17-alpine
    environment: {POSTGRES_USER: goalert, POSTGRES_PASSWORD: goalert, POSTGRES_DB: goalert}
    healthcheck: {test: [CMD-SHELL, pg_isready -U goalert], interval: 2s, retries: 30}
  goalert:
    image: goalert/goalert:v0.35.0
    depends_on: {db: {condition: service_healthy}}
    ports: ["8081:8081"]
    environment:
      GOALERT_DB_URL: postgres://goalert:goalert@db/goalert?sslmode=disable
      GOALERT_DATA_ENCRYPTION_KEY: lab-only-key
      GOALERT_PUBLIC_URL: http://localhost:8081
"""
B = "http://localhost:8081"

class GoAlert(Tool):
    name = "goalert"
    def gql(self, q, v=None, quiet=False):
        c, j, t = self.http("POST", B + "/api/graphql", {"query": q, "variables": v or {}}, quiet=quiet)
        return j
    def install(self):
        self.r["version"] = "v0.35.0"
        open(self.work + "/compose.yml", "w").write(COMPOSE)
        open(self.work + "/teardown.sh", "w").write(f"cd {self.work} && docker compose -f compose.yml down -v\n")
        self.sh("docker compose -f compose.yml pull", timeout=300)
        self.step("write a compose file: Postgres plus goalert/goalert:v0.35.0 (no compose file ships in the docs, the docs show docker run)")
        self.step("docker compose up -d")
        self.sh("docker compose -f compose.yml up -d --wait", check=True)
        self.r["boot_seconds"] = round(self.wait_http(B + "/health"), 1)
        self.step("goalert add-user --admin (first login needs a CLI step)")
        for u, p in (("admin", "--admin"), ("alice", ""), ("bob", "")):
            self.sh(f"docker compose -f compose.yml exec -T goalert goalert add-user {p} --user {u} --pass lab-password-1 --email {u}@example.com", check=True)
    def login(self, u="admin"):
        c, j, t = self.http("POST", B + "/api/v2/identity/providers/basic?noRedirect=1", {"username": u, "password": "lab-password-1"}, form=True, headers={"Referer": B + "/"})
        self.hdr = {"Cookie": "goalert_session.2=" + t.strip(), "Referer": B + "/"}
    def minimal(self):
        self.login()
        self.step("UI or GraphQL: create a service, an escalation policy and an integration key of type Prometheus Alertmanager")
        j = self.gql("""mutation($i:CreateServiceInput!){createService(input:$i){id name escalationPolicyID integrationKeys{id type href}}}""",
          {"i": {"name": "checkout", "newEscalationPolicy": {"name": "checkout-ep", "repeat": 0}, "newIntegrationKeys": [{"type": "prometheusAlertmanager", "name": "alertmanager"}]}})
        s = j["data"]["createService"]; self.svc = s["id"]; self.ep = s["escalationPolicyID"]; self.url = s["integrationKeys"][0]["href"]
        self.url = self.url if self.url.startswith("http") else B + self.url
    def post(self, body):
        c, j, t = self.http("POST", self.url, bytes(body)); return c, t
    def alerts(self):
        j = self.gql("query{alerts(input:{first:50}){nodes{alertID status summary}}}", quiet=True)
        return j["data"]["alerts"]["nodes"]
    def oncall(self):
        self.gql('mutation{setConfig(input:[{id:"Webhook.Enable",value:"true"}])}')
        ids = {n["name"]: n["id"] for n in self.gql('query{users(first:10){nodes{id name}}}')["data"]["users"]["nodes"]}
        self.log("users", ids)
        for u in ("alice", "bob"):
            cm = self.gql("mutation($i:CreateUserContactMethodInput!){createUserContactMethod(input:$i){id}}",
              {"i": {"userID": ids[u], "name": "lab-sink", "dest": {"type": "builtin-webhook", "args": {"webhook_url": f"{SINK}/goalert/{u}/verify"}}, "newUserNotificationRule": {"delayMinutes": 0}}})["data"]["createUserContactMethod"]["id"]
            self.log("webhook contact methods start disabled, GoAlert posts a code to the URL and it must be typed back")
            self.gql("mutation($i:SendContactMethodVerificationInput!){sendContactMethodVerification(input:$i)}", {"i": {"contactMethodID": cm}})
            rows = self.wait_sink(f"/goalert/{u}/verify", 1, 30)
            code = json.loads(rows[0]["body"])["Code"]
            self.gql("mutation($i:VerifyContactMethodInput!){verifyContactMethod(input:$i)}", {"i": {"contactMethodID": cm, "code": int(code)}})
        rot = self.gql("mutation($i:CreateRotationInput!){createRotation(input:$i){id}}",
              {"i": {"name": "primary", "timeZone": "UTC", "start": iso(hours=-1), "type": "daily", "shiftLength": 1, "userIDs": [ids["alice"], ids["bob"]]}})["data"]["createRotation"]["id"]
        for tgt in ({"id": rot, "type": "rotation"}, {"id": ids["bob"], "type": "user"}):
            self.gql("mutation($i:CreateEscalationPolicyStepInput!){createEscalationPolicyStep(input:$i){id}}", {"i": {"escalationPolicyID": self.ep, "delayMinutes": 1, "targets": [tgt]}})
        time.sleep(12)
        self.gql('query($id:ID!){service(id:$id){onCallUsers{userName stepNumber}}}', {"id": self.svc})
        self.log("firing again, now with a rotation and a two-step policy")
        t0 = time.time(); self.post(FIRING); 
        a = self.wait_sink("/goalert/alice/verify", 2, 60); t1 = time.time()
        b = self.wait_sink("/goalert/bob/verify", 2, 150); t2 = time.time()
        self.post(FIRING); time.sleep(20)
        self.r["escalation"] = {"first_page_s": round(t1 - t0, 1) if a else None, "second_page_s": round(t2 - t0, 1) if b else None,
                                "alice_posts": len(self.sink("/goalert/alice"))-1, "bob_posts": len(self.sink("/goalert/bob"))-1, "sample": a[-1]["body"][:500] if len(a) > 1 else ""}
        self.gql('query{messageLogs(input:{first:20}){nodes{createdAt type status additionalDetails userName}}}')
        self.snap("during_escalation")
        self.post(RESOLVED); self.snap("after_final_resolve", wait=6)
        self.untested("SMS and voice: GoAlert sends these through Twilio, and no Twilio account was used. Delivery was tested with GoAlert's webhook contact method pointed at a local sink.")
    def after(self):
        self.sh("docker compose -f compose.yml logs goalert --tail=30")
        self.sh("docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'")
GoAlert().run()
