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
    def post(self, body):
        c, j, t = self.http("POST", f"http://localhost:16649/v0/webhooks/alertmanager?application={self.app}&key={self.key}", bytes(body)); return c, t
    def alerts(self):
        c, o = self.sh("docker compose exec -T iris-mysql mysql -uroot -p1234 iris -N -e 'select count(*) from incident'", cwd=self.work + "/iris", trim=200)
        n = [l for l in o.splitlines() if l.strip().isdigit()]
        return [{"incident_rows": int(n[0])}] if n and int(n[0]) else []
    def oncall(self):
        self.untested("LinkedIn Oncall is a calendar and Iris does the paging. We stopped once the unchanged payload was refused.")
    def after(self):
        self.sh("docker logs iris-iris-web-1 --tail=15 2>&1 | cut -c1-200")
LI().run()
