import json, os, sys, time, uuid
sys.path.insert(0, os.environ["HERE"] + "/harness")
from lib import *
B = "http://localhost"
def oid(): return str(uuid.uuid4())

class OU(Tool):
    name = "oneuptime"
    def install(self):
        self.step("git clone --branch release the repo")
        self.sh("git clone -q --depth 1 --single-branch --branch release https://github.com/OneUptime/oneuptime.git src", check=True)
        self.r["version"] = self.sh("cat src/VERSION; git -C src log -1 --format=%cd")[1].strip()
        self.step("cp config.example.env config.env")
        self.sh("cp config.example.env config.env", cwd=self.work + "/src")
        open(self.work + "/teardown.sh", "w").write(f"cd {self.work}/src && sh ./Scripts/Install/WithConfig.sh docker compose down -v\n")
        self.step("npm start (needs Node on the host, at least 8 GB of memory per the README)")
        self.sh("npm start", cwd=self.work + "/src", timeout=900, trim=3000)
        self.sh("docker ps --format '{{.Names}} {{.Image}} {{.Status}}'")
        self.wait_http(B + "/", timeout=240, ok=(200, 301, 302))
    def api(self, m, p, body=None, **k):
        return self.http(m, B + p, body, **k)
    def minimal(self):
        self.step("register the first user and create a project in the web UI")
        for path in ("/identity/signup", "/api/identity/signup"):
            c, j, t = self.api("POST", path, {"data": {"email": "admin@example.com", "password": "Lab-password-1!", "name": "admin", "companyName": "lab", "companyPhoneNumber": "+15145550100"}}, trim=600)
            if c == 200: break
        self.log("cookies", [k.name for k in self.cj])
        tok = None
        if j:
            tok = j.get("token") or (j.get("value") or {}).get("token") if isinstance(j, dict) else None
        c, p, t = self.api("POST", "/api/project", {"data": {"name": "lab"}}, trim=900)
        self.pid = p.get("_id") or (p.get("data") or {}).get("_id")
        self.hdr = {"tenantid": self.pid}
        def first(path, sel, q=None):
            c, j, t = self.api("POST", f"/api{path}/get-list?skip=0&limit=50", {"query": q or {"projectId": self.pid}, "select": sel, "sort": {}}, trim=900)
            return (j or {}).get("data", [])
        st = first("/monitor-status", {"_id": True, "name": True, "isOperationalState": True, "isOfflineState": True})
        self.log("statuses", st)
        online = [x for x in st if x["name"] == "Operational"][0]["_id"]; off = [x for x in st if x["name"] == "Offline"][0]["_id"]
        sev = first("/incident-severity", {"_id": True, "name": True}); self.log("sev", sev)
        sev0 = sev[0]["_id"]
        self.step("create an Incoming Request monitor with two criteria: request body contains \"status\":\"firing\" opens an incident, \"status\":\"resolved\" brings it back; turn on grouping by requestBody.alerts[*].fingerprint")
        self.online, self.off, self.sev0 = online, off, sev0
        steps = self.steps([])
        c, m, t = self.api("POST", "/api/monitor", {"data": {"name": "Alertmanager", "projectId": self.pid, "monitorType": "Incoming Request", "monitorSteps": steps}}, trim=500)
        self.mon = m; self.url = self.hook(m)
    def hook(self, m):
        c, g, t = self.api("POST", f"/api/monitor/{m['_id']}/get-item", {"select": {"incomingRequestSecretKey": True}}, trim=300)
        key = g["incomingRequestSecretKey"]; key = key.get("value") if isinstance(key, dict) else key
        return f"{B}/heartbeat/{key}"
    def steps(self, policies):
        online, off, sev0 = self.online, self.off, self.sev0
        crit = lambda sid, flt, inc, name: {"_type": "MonitorCriteriaInstance", "value": {"id": oid(), "monitorStatusId": {"_type": "ObjectID", "value": sid}, "filterCondition": "Any",
            "filters": [{"checkOn": "Request Body", "filterType": "Contains", "value": flt}], "incidents": inc, "alerts": [], "createAlerts": False, "createIncidents": bool(inc), "changeMonitorStatus": True, "name": name, "description": name}}
        inc = [{"title": "{{requestBody.commonLabels.alertname}}", "description": "{{requestBody.commonAnnotations.summary}}", "incidentSeverityId": {"_type": "ObjectID", "value": sev0}, "autoResolveIncident": True, "id": oid(), "onCallPolicyIds": policies}]
        firing = crit(off, '"status":"firing"', inc, "firing"); firing["value"]["incidentGrouping"] = {"groupByJSONPath": "requestBody.alerts[*].fingerprint", "resolvedWhenJSONPath": "requestBody.alerts[*].status", "resolvedWhenValue": "resolved"}
        return {"_type": "MonitorSteps", "value": {"defaultMonitorStatusId": {"_type": "ObjectID", "value": online}, "monitorStepsInstanceArray": [{"_type": "MonitorStep", "value": {"id": oid(), "monitorDestination": None, "requestType": "GET",
            "monitorCriteria": {"_type": "MonitorCriteria", "value": {"monitorCriteriaInstanceArray": [firing, crit(online, '"status":"resolved"', [], "resolved")]}}}}]}}
    def post(self, body):
        c, j, t = self.http("POST", self.url, bytes(body)); return c, t
    def alerts(self):
        c, j, t = self.api("POST", "/api/incident/get-list?skip=0&limit=50", {"query": {"projectId": self.pid}, "select": {"title": True, "incidentNumber": True, "currentIncidentState": {"name": True}}, "sort": {}}, quiet=True)
        return [{"n": x.get("incidentNumber"), "title": x.get("title"), "state": (x.get("currentIncidentState") or {}).get("name")} for x in (j or {}).get("data", [])]
    def oncall(self):
        P = self.pid
        c, me, t = self.api("POST", "/api/user/get-list?skip=0&limit=5", {"query": {}, "select": {"_id": True, "email": True}, "sort": {}}, trim=300)
        uid = (me or {}).get("data", [{}])[0].get("_id") if me else None
        c, pol, t = self.api("POST", "/api/on-call-duty-policy", {"data": {"name": "checkout", "projectId": P}}, trim=300)
        c, sch, t = self.api("POST", "/api/on-call-duty-policy-schedule", {"data": {"name": "primary", "projectId": P}}, trim=300)
        for o, name in ((1, "first"), (2, "second")):
            c, rule, t = self.api("POST", "/api/on-call-duty-policy-escalation-rule", {"data": {"name": name, "projectId": P, "onCallDutyPolicyId": pol["_id"], "order": o, "escalateAfterInMinutes": 1}}, trim=300)
            if uid and rule: self.api("POST", "/api/on-call-duty-policy-escalation-rule-user", {"data": {"projectId": P, "onCallDutyPolicyId": pol["_id"], "onCallDutyPolicyEscalationRuleId": rule["_id"], "userId": uid}}, trim=300)
        c, m2, t = self.api("POST", "/api/monitor", {"data": {"name": "Alertmanager paged", "projectId": P, "monitorType": "Incoming Request", "monitorSteps": self.steps([pol["_id"]])}}, trim=300)
        self.url = self.hook(m2)
        self.post(FIRING); time.sleep(100)
        c, j, t = self.api("POST", "/api/on-call-duty-policy-execution-log/get-list?skip=0&limit=10", {"query": {"projectId": P}, "select": {"status": True, "statusMessage": True, "lastEscalationRuleExecutedAt": True, "lastExecutedEscalationRuleOrder": True, "executeNextEscalationRuleInMinutes": True, "createdAt": True}, "sort": {}}, trim=1800)
        self.r["escalation"] = {"execution_log": (j or {}).get("data"), "raw_http": c}
        self.api("POST", "/api/on-call-duty-policy-execution-log-timeline/get-list?skip=0&limit=10", {"query": {"projectId": P}, "select": {"status": True, "statusMessage": True, "createdAt": True}, "sort": {}}, trim=2500)
        self.snap("during_escalation", wait=1); self.post(RESOLVED); self.snap("after_final_resolve", wait=20)
        self.untested("Delivery: no SMTP or Twilio was configured on OneUptime, so we read its on-call execution log. Schedules were created but a rotation layer was not exercised.")
    def after(self):
        self.sh("docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'")
OU().run()
