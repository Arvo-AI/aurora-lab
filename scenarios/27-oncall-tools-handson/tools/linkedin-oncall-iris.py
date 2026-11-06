import json, os, sys, time
sys.path.insert(0, os.environ["HERE"] + "/harness")
from lib import *

class LI(Tool):
    name = "linkedin-oncall-iris"
    def install(self):
        self.step("git clone linkedin/iris and linkedin/oncall")
        self.sh("git clone -q --depth 1 https://github.com/linkedin/iris.git; git clone -q --depth 1 https://github.com/linkedin/oncall.git", check=True)
        self.r["version"] = self.sh("git -C iris log -1 --format='iris %h %cs'; git -C oncall log -1 --format='oncall %h %cs'")[1].strip()
        open(self.work + "/teardown.sh", "w").write(f"cd {self.work}/iris && docker compose down -v; cd {self.work}/oncall && docker compose down -v\n")
        self.step("docker compose up -d --build in each repo (no published images; each builds from its Dockerfile)")
        c1, o = self.sh("docker compose up -d --build", cwd=self.work + "/iris", timeout=500, trim=2500)
        self.r["iris_build_exit"] = c1
        c2, o = self.sh("docker compose up -d --build", cwd=self.work + "/oncall", timeout=500, trim=2500)
        self.r["oncall_build_exit"] = c2
        self.sh("docker ps -a --format '{{.Names}} {{.Image}} {{.Status}}'")
        if c1: raise RuntimeError("iris build failed")
        self.wait_http("http://localhost:16649/", timeout=180, ok=(200, 302, 401, 404))
    def minimal(self):
        self.step("find or create an Iris application and key, plus a plan")
        c, o = self.sh("docker compose exec -T iris-mysql mysql -uroot -p1234 iris -N -e 'select name,`key` from application limit 5'", cwd=self.work + "/iris")
        rows = [l.split("\t") for l in o.splitlines() if "\t" in l]
        self.app, self.key = rows[0] if rows else ("Autoalerts", "")
        self.base = self.count()
        self.sh("docker compose restart iris-web", cwd=self.work + "/iris", timeout=120)
        self.wait_http("http://localhost:16649/", timeout=120, ok=(200, 302, 401, 404))
        time.sleep(15)
        self.sh("docker compose exec -T iris-mysql mysql -uroot -p1234 iris -e 'select id,name,auth_only,allow_other_app_incidents from application'", cwd=self.work + "/iris", trim=800)
        for app, key in rows:
            self.app, self.key = app, key
            c, t = self.post(FIRING)
            self.log("app probe", app, c)
            if c != 401:
                self.note(f"seeded application {app} got past auth with HTTP {c}"); break
    def post(self, body):
        c, j, t = self.http("POST", f"http://localhost:16649/v0/webhooks/alertmanager?application={self.app}&key={self.key}", bytes(body)); return c, t
    def count(self):
        c, o = self.sh("docker compose exec -T iris-mysql mysql -uroot -p1234 iris -N -e 'select count(*) from incident'", cwd=self.work + "/iris", trim=200)
        n = [l for l in o.splitlines() if l.strip().isdigit()]
        return int(n[0]) if n else 0
    def alerts(self):
        n = self.count() - self.base
        return [{"new_incident_rows": n}] if n > 0 else []
    def oncall(self):
        self.log("--- E. same payload with iris_plan added to groupLabels")
        c, o = self.sh("docker compose exec -T iris-mysql mysql -uroot -p1234 iris -N -e 'select name from plan limit 3'", cwd=self.work + "/iris", trim=400)
        names = [l.strip() for l in o.splitlines() if l.strip() and "Warning" not in l and "level=" not in l]
        p = json.loads(FIRING); p["groupLabels"]["iris_plan"] = names[0] if names else "demo-test-foo"
        c, t = self.post(json.dumps(p).encode()); self.r["with_iris_plan_http"] = c; self.r["with_iris_plan_body"] = t[:300]
        self.snap("after_iris_plan")
        self.untested("LinkedIn Oncall schedules and Iris plans: we stopped after the webhook test. Oncall is a calendar and Iris does the paging, and the two are connected by config we did not set up. Senders need your own Twilio or SMTP.")
    def after(self):
        self.sh("docker logs iris-iris-web-1 --tail=15 2>&1 | cut -c1-200")
LI().run()
