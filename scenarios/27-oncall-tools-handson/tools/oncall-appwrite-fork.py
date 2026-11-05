import sys, os
sys.path.insert(0, os.environ["HERE"] + "/harness")
from oncall_common import *
class T(OnCall):
    name = "oncall-appwrite-fork"; tag = "v1.24.14"; extra_env = "ONCALL_VERSION=1.24.14\n"
    compose_url = "https://raw.githubusercontent.com/appwrite/grafana-oncall/v1.24.14/docker-compose.yml"
T().run()
