import sys, os
sys.path.insert(0, os.environ["HERE"] + "/harness")
from oncall_common import *
class T(OnCall):
    name = "grafana-oncall-oss"; tag = "v1.16.11"
    compose_url = "https://raw.githubusercontent.com/grafana-cold-storage/oncall/v1.16.11/docker-compose.yml"
    def grafana_block(self):
        return ""
T().run()
