#!/usr/bin/env bash
# How the captures in this folder were produced, 2026-10-29 (UTC 15:47 to 16:12).
# Kept as a record of the exact commands; it was run step by step, not as one script.
# Cluster: kind v0.33.0, Kubernetes v1.37.0, containerd 2.3.4, arm64 nodes on OrbStack.
set -euo pipefail
cd ~/Claude/aurora-lab
export KUBECONFIG=$PWD/.kubeconfig-rpull
k() { kubectl --context kind-rpull "$@"; }

# 1. Cluster and scenario 03 (mistyped tag) -> 01-tag-not-found.txt
LAB_CLUSTER=rpull ./lab.sh up
LAB_CLUSTER=rpull SETTLE=5 ./lab.sh break 03

# 2. Local registry with basic auth (throwaway user, never a real credential)
mkdir -p /tmp/rpull-reg/auth
htpasswd -Bbn labuser labpass123 > /tmp/rpull-reg/auth/htpasswd
docker run -d --name rpull-registry --network kind \
  -e REGISTRY_AUTH=htpasswd -e REGISTRY_AUTH_HTPASSWD_REALM=rpull \
  -e REGISTRY_AUTH_HTPASSWD_PATH=/auth/htpasswd \
  -v /tmp/rpull-reg/auth:/auth -p 127.0.0.1:5055:5000 registry:2
echo labpass123 | docker login 127.0.0.1:5055 -u labuser --password-stdin
docker tag busybox:1.37 127.0.0.1:5055/private/busybox:1.37
docker push 127.0.0.1:5055/private/busybox:1.37
# amd64-only single manifest
docker pull --platform linux/amd64 busybox:1.37
docker tag busybox:1.37 127.0.0.1:5055/private/busybox-amd64only:1.37
docker push --platform linux/amd64 127.0.0.1:5055/private/busybox-amd64only:1.37
# image index that lists only linux/amd64
D=sha256:66a6306db78bf2dbf3487f293aa8d6990d8e506fdffab9cc43fe422becf886e4  # busybox:1.37 linux/amd64
docker buildx imagetools create -t 127.0.0.1:5055/private/busybox-amd64index:1.37 docker.io/library/busybox@$D

# 3. Public-side causes -> 02-causes.txt (pods-a.yaml)
#    At this point containerd had no registry config, so rpull-registry:5000 was tried over HTTPS.
k apply -f runs/search-2026-10-29/imagepullbackoff-causes/pods-a.yaml

# 4. Teach the workers' containerd to use HTTP for rpull-registry:5000
for n in rpull-worker rpull-worker2; do
  docker exec "$n" bash -c '
    mkdir -p "/etc/containerd/certs.d/rpull-registry:5000"
    printf "server = \"http://rpull-registry:5000\"\n\n[host.\"http://rpull-registry:5000\"]\n  capabilities = [\"pull\", \"resolve\"]\n" > "/etc/containerd/certs.d/rpull-registry:5000/hosts.toml"
    printf "\n[plugins.\"io.containerd.grpc.v1.cri\".registry]\n  config_path = \"/etc/containerd/certs.d\"\n" >> /etc/containerd/config.toml
    systemctl restart containerd'
done

# 5. Credentials and architecture -> 03-private-and-arch.txt (pods-b.yaml)
k -n pulltest create secret docker-registry regcred --docker-server=rpull-registry:5000 --docker-username=labuser --docker-password=labpass123
k -n pulltest create secret docker-registry regcred-wrong --docker-server=rpull-registry:5000 --docker-username=labuser --docker-password=wrongpass
k -n default create secret docker-registry othercred --docker-server=rpull-registry:5000 --docker-username=labuser --docker-password=labpass123
k apply -f runs/search-2026-10-29/imagepullbackoff-causes/pods-b.yaml

# 6. Fix scenario 03 -> 05-fix-verify.txt ; cached private image without a secret -> 06-misc.txt (late.yaml)
k -n shop set image deploy/frontend nginx=nginx:1.27-alpine
k -n shop rollout status deploy/frontend --timeout=120s
k -n pulltest run present --image=nginx:1.27-alpine --overrides='{"spec":{"nodeName":"rpull-worker2"}}'
k apply -f runs/search-2026-10-29/imagepullbackoff-causes/late.yaml

# 7. Backoff timeline -> 07-backoff-timeline-repo-missing.txt
docker exec rpull-worker2 journalctl -u containerd --no-pager | grep 'level=info msg="PullImage \\"docker.io/rpullnoorg'

# 8. Docker Hub rate-limit headers (HEAD, does not count as a pull) -> 04-dockerhub-ratelimit.txt
TOKEN=$(curl -s "https://auth.docker.io/token?service=registry.docker.io&scope=repository:ratelimitpreview/test:pull" | python3 -c 'import json,sys;print(json.load(sys.stdin)["token"])')
curl -s --head -H "Authorization: Bearer $TOKEN" https://registry-1.docker.io/v2/ratelimitpreview/test/manifests/latest

# Cleanup
LAB_CLUSTER=rpull ./lab.sh down
docker rm -f rpull-registry
docker logout 127.0.0.1:5055
