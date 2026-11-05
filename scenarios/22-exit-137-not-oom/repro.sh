#!/usr/bin/env bash
# Runs after the fault is injected. Writes every capture to $OUT/. All memory
# limits below are small on purpose. Each section stands alone: a failure in one
# must not stop the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NS=exit137
W=aurora-lab-worker
W2=aurora-lab-worker2
k() { kubectl "$@"; }
# say prints the command then runs it, so transcripts read like a terminal session.
say() { echo "\$ $*"; eval "$@"; echo "[exit $?]"; }
TERM_FMT='{.status.containerStatuses[0].state.terminated}'
LAST_FMT='{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\t"}{.status.containerStatuses[0].lastState.terminated.reason}{"\t"}{.status.containerStatuses[0].lastState.terminated.exitCode}{"\t"}{.status.containerStatuses[0].lastState.terminated.startedAt}{"\t"}{.status.containerStatuses[0].lastState.terminated.finishedAt}{"\n"}'

# Pod-level cgroup on the node; survives container restarts.
podcg() {
  local node=$1 uid
  uid=$(k -n "$3" get pod "$2" -o jsonpath='{.metadata.uid}')
  docker exec "$node" find /sys/fs/cgroup -type d \( -name "*pod${uid//-/_}*" -o -name "pod$uid" \) | head -1
}
memevents() {
  local node=$1 pod=$2 ns=${3:-$NS} cg
  cg=$(podcg "$node" "$pod" "$ns")
  echo "== $pod pod cgroup: $cg"
  [ -n "$cg" ] && docker exec "$node" cat "$cg/memory.events"
}
wait_restart() {
  local pod=$1 n=${2:-1} i
  for i in $(seq 1 60); do
    [ "$(k -n $NS get pod "$pod" -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null)" -ge "$n" ] 2>/dev/null && return 0
    sleep 3
  done
  echo "timeout waiting for $pod restart $n"
}

section_shop() {
  local pod node
  pod=$(k -n shop get pods -l app=worker -o jsonpath='{.items[0].metadata.name}')
  node=$(k -n shop get pod "$pod" -o jsonpath='{.spec.nodeName}')
  say "kubectl -n shop get pods -l app=worker -o wide"
  say "kubectl -n shop describe pod $pod"
  say "kubectl -n shop get events --field-selector involvedObject.name=$pod --sort-by=.lastTimestamp"
  say "kubectl -n shop top pod $pod --containers"
  say "kubectl -n shop get pod $pod -o jsonpath='$LAST_FMT'"
  memevents "$node" "$pod" shop
}

section_oom() {
  k apply -f "$HERE/causes/stop.yaml" >/dev/null   # namespace and code ConfigMap, pods released below
  k apply -f "$HERE/causes/others.yaml" >/dev/null
  wait_restart oom-limit 1
  say "kubectl -n $NS get pod oom-limit -o jsonpath='$LAST_FMT'"
  say "kubectl -n $NS get pod oom-limit -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'"
  say "kubectl -n $NS describe pod oom-limit"
  say "kubectl -n $NS get events --field-selector involvedObject.name=oom-limit --sort-by=.lastTimestamp"
  say "kubectl get events -A --field-selector involvedObject.kind=Node --sort-by=.lastTimestamp"
  echo "== memory.events from inside the replacement container"
  say "kubectl -n $NS exec oom-limit -- cat /sys/fs/cgroup/memory.events"
  say "kubectl -n $NS exec oom-limit -- cat /sys/fs/cgroup/memory.oom.group"
  echo "== memory.events on the node, pod cgroup"
  memevents $W oom-limit
  echo "== kernel log"
  docker exec $W dmesg | grep -E 'oom-kill:|Memory cgroup out of memory|Killed process' | tail -6
  echo "== crictl"
  say "docker exec $W crictl ps -a --name app --pod \$(docker exec $W crictl pods --name oom-limit -q) -o json | python3 -c 'import json,sys; [print(c[\"id\"], c[\"state\"]) for c in json.load(sys.stdin)[\"containers\"]]'"
  cid=$(docker exec $W crictl ps -a --state exited --name app --pod "$(docker exec $W crictl pods --name oom-limit -q)" -q | head -1)
  say "docker exec $W crictl inspect $cid | python3 -c 'import json,sys; s=json.load(sys.stdin)[\"status\"]; print(s[\"reason\"], s[\"exitCode\"], s[\"message\"])'"
  echo "== containerd log"
  docker exec $W journalctl -u containerd --no-pager | grep -i 'TaskOOM' | tail -3
}

section_stop() {
  k apply -f "$HERE/causes/stop.yaml" >/dev/null
  k -n $NS wait pod -l group=stop --for=condition=Ready --timeout=120s
  sleep 5
  local names p t0
  names=$(k -n $NS get pods -l group=stop -o jsonpath='{.items[*].metadata.name}')
  t0=$(date +%s.%N)
  echo "delete issued at $(date -u +%H:%M:%S.%N)"
  for p in $names; do k -n $NS delete pod "$p" --wait=false & done
  wait
  for i in $(seq 1 40); do
    done=0
    for p in $names; do
      [ -n "$(k -n $NS get pod "$p" -o jsonpath="$TERM_FMT" 2>/dev/null)" ] && done=$((done + 1))
    done
    [ "$done" -eq "$(echo "$names" | wc -w)" ] && break
    sleep 1
  done
  echo "case exit reason deletionTimestamp finishedAt stop_seconds"
  for p in $names; do
    k -n $NS get pod "$p" -o json | python3 -c '
import json, sys
from datetime import datetime
p = json.load(sys.stdin)
t = p["status"]["containerStatuses"][0]["state"].get("terminated") or {}
f = t.get("finishedAt")
d = p["metadata"].get("deletionTimestamp")
secs = "?"
if f:
    secs = round(datetime.fromisoformat(f.replace("Z","+00:00")).timestamp() - float(sys.argv[1]), 1)
print(p["metadata"]["name"], t.get("exitCode"), t.get("reason"), d, f, secs)' "$t0"
  done
  say "kubectl -n $NS get pod no-handler -o jsonpath='{.status.containerStatuses[0].state.terminated}'"
  say "kubectl -n $NS logs no-handler"
  say "kubectl -n $NS logs handled"
  say "kubectl -n $NS logs trap-ignore"
  say "kubectl -n $NS logs prestop-long"
  say "kubectl -n $NS get events --sort-by=.lastTimestamp --field-selector reason=Killing"
  say "kubectl -n $NS get events --sort-by=.lastTimestamp --field-selector reason=FailedPreStopHook"
  say "kubectl -n $NS describe pod no-handler"
  for p in $names; do k -n $NS patch pod "$p" --type merge -p '{"metadata":{"finalizers":null}}' >/dev/null; done
}

section_plain_delete() {
  k -n $NS wait pod plain-delete --for=condition=Ready --timeout=60s
  k -n $NS get pod plain-delete -w --output-watch-events -o jsonpath='{.type} {.status.phase} {.metadata.deletionTimestamp} {.status.containerStatuses[0].state}{"\n"}' > "$OUT/05-plain-delete-watch.txt" 2>&1 &
  local w=$!
  sleep 2
  echo '$ time kubectl -n exit137 delete pod plain-delete'
  time k -n $NS delete pod plain-delete
  sleep 2
  kill $w 2>/dev/null
  say "kubectl -n $NS get pod plain-delete"
  say "kubectl -n $NS get events --field-selector involvedObject.name=plain-delete --sort-by=.lastTimestamp"
  echo "== kubelet log"
  docker exec $W journalctl -u kubelet --no-pager | grep plain-delete | tail -12 | cut -c1-260
}

section_probe() {
  wait_restart probe-trap 2
  wait_restart probe-no-handler 2
  wait_restart probe-handled 2
  for p in probe-trap probe-no-handler probe-handled; do
    say "kubectl -n $NS get pod $p -o jsonpath='$LAST_FMT'"
  done
  say "kubectl -n $NS describe pod probe-no-handler"
  say "kubectl -n $NS get events --field-selector involvedObject.name=probe-no-handler --sort-by=.lastTimestamp -o custom-columns=FIRST:.firstTimestamp,LAST:.lastTimestamp,COUNT:.count,REASON:.reason,MSG:.message"
  memevents $W probe-no-handler
  memevents $W probe-trap
  memevents $W probe-handled
}

section_nonsignal() {
  wait_restart plain-exit 1
  say "kubectl -n $NS get pod plain-exit -o jsonpath='$LAST_FMT'"
  say "kubectl -n $NS get events --field-selector involvedObject.name=plain-exit --sort-by=.lastTimestamp"
  memevents $W plain-exit
  echo "== SIGKILL from inside the pod does nothing to PID 1"
  k -n $NS wait pod host-kill --for=condition=Ready --timeout=60s
  say "kubectl -n $NS exec host-kill -- python -c 'import os, signal; os.kill(1, signal.SIGKILL); print(\"sent\")'"
  sleep 3
  say "kubectl -n $NS get pod host-kill -o jsonpath='{.status.containerStatuses[0].restartCount}{\"\n\"}'"
  echo "== SIGKILL from the node"
  cid=$(docker exec $W crictl ps --name app --pod "$(docker exec $W crictl pods --name host-kill -q)" -q)
  pid=$(docker exec $W crictl inspect "$cid" | python3 -c 'import json,sys; print(json.load(sys.stdin)["info"]["pid"])')
  say "docker exec $W kill -9 $pid"
  wait_restart host-kill 1
  say "kubectl -n $NS get pod host-kill -o jsonpath='$LAST_FMT'"
  say "kubectl -n $NS get events --field-selector involvedObject.name=host-kill --sort-by=.lastTimestamp"
  memevents $W host-kill
}

section_tally() {
  local round i before after n=40
  for round in 1 2; do
    before=$(docker exec $W dmesg | grep -c 'Memory cgroup out of memory: Killed process')
    for i in $(seq -w 1 $n); do
      cat <<Y
---
apiVersion: v1
kind: Pod
metadata: {name: tally-$round-$i, namespace: $NS, labels: {app: tally}}
spec:
  restartPolicy: Never
  nodeSelector: {kubernetes.io/hostname: $W}
  containers:
  - name: tally
    image: python:3.12-alpine
    command: ["python", "-u", "-c", "b = b'\\\\x01' * (150 << 20); print('allocated')"]
    resources:
      requests: {memory: 128Mi, cpu: 10m}
      limits: {memory: 128Mi}
Y
    done | k apply -f - >/dev/null
    for i in $(seq 1 60); do
      [ "$(k -n $NS get pods -l app=tally --no-headers 2>/dev/null | grep -cE 'Pending|Running|ContainerCreating')" -eq 0 ] && break
      sleep 3
    done
    sleep 5
    after=$(docker exec $W dmesg | grep -c 'Memory cgroup out of memory: Killed process')
    echo "round $round: pods=$n kernel 'Killed process' lines before=$before after=$after"
    k -n $NS get pods -l app=tally -o jsonpath='{range .items[*]}{.status.containerStatuses[0].state.terminated.reason} {.status.containerStatuses[0].state.terminated.exitCode}{"\n"}{end}' | sort | uniq -c
    k -n $NS delete pods -l app=tally --wait=true >/dev/null
  done
}

section_node_oom() {
  say "docker update --memory 3g --memory-swap 3g $W2"
  say "docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' $W2"
  k apply -f "$HERE/causes/node-hog.yaml" >/dev/null
  for i in $(seq 1 60); do
    [ -n "$(k -n $NS get pod node-hog -o jsonpath='{.status.containerStatuses[0].lastState.terminated.exitCode}{.status.containerStatuses[0].state.terminated.exitCode}' 2>/dev/null)" ] && break
    sleep 2
  done
  say "kubectl -n $NS get pod node-hog -o jsonpath='{.status.phase} {.status.qosClass} {.status.reason}{\"\n\"}'"
  say "kubectl -n $NS get pod node-hog -o jsonpath='$LAST_FMT'"
  say "kubectl -n $NS get pod node-hog -o jsonpath='{.status.containerStatuses[0].state}{\"\n\"}'"
  say "kubectl -n $NS get pod node-hog -o jsonpath='{.spec.containers[0].resources}{\"\n\"}'"
  say "kubectl -n $NS logs node-hog --previous --tail=2"
  memevents $W2 node-hog
  echo "== kernel log"
  docker exec $W2 dmesg | grep -E 'oom-kill:|Out of memory|Killed process' | tail -4 | cut -c1-420
  say "kubectl -n $NS get events --field-selector involvedObject.name=node-hog --sort-by=.lastTimestamp"
  say "kubectl get events -A --field-selector involvedObject.kind=Node --sort-by=.lastTimestamp"
  say "kubectl describe node $W2 | grep -E 'MemoryPressure|memory:'"
  k -n $NS delete pod node-hog --grace-period=0 --force >/dev/null 2>&1
  docker update --memory 0 --memory-swap 0 $W2 >/dev/null 2>&1 || docker update --memory 12g --memory-swap 12g $W2 >/dev/null 2>&1
}

dkr_events() { docker events --since "$1" --until "$(date +%s)" --filter "container=$2" --format '{{.Action}} signal={{index .Actor.Attributes "signal"}} exitCode={{index .Actor.Attributes "exitCode"}}'; }
state() { docker inspect "$1" --format 'OOMKilled={{.State.OOMKilled}} ExitCode={{.State.ExitCode}} Status={{.State.Status}}'; }
section_docker() {
  local n t
  P=python:3.12-alpine
  say "docker version --format '{{.Server.Version}}'"
  say "stat -fc %T /sys/fs/cgroup"

  echo "=== a: kernel OOM kill"
  n=x137-oom; t=$(date +%s)
  say "docker run --name $n --memory 128m --memory-swap 128m $P python -c 'b = b\"\\x01\" * (200 << 20); print(\"allocated\")'"
  say "docker inspect $n --format '{{json .State}}'"
  dkr_events $t $n

  echo "=== b: docker kill"
  n=x137-kill; t=$(date +%s)
  docker run -d --name $n $P sleep 3600 >/dev/null; sleep 1
  say "docker kill $n"
  say "docker wait $n"
  say "docker inspect $n --format '{{json .State}}'"
  dkr_events $t $n

  echo "=== c: docker stop, process with no SIGTERM handler as PID 1"
  n=x137-stop; t=$(date +%s)
  docker run -d --name $n $P python -c 'import time; time.sleep(3600)' >/dev/null; sleep 2
  say "time docker stop $n"
  state $n
  dkr_events $t $n

  echo "=== d: same process, docker run --init"
  n=x137-init; t=$(date +%s)
  docker run -d --init --name $n $P python -c 'import time; time.sleep(3600)' >/dev/null; sleep 2
  say "time docker stop $n"
  state $n
  dkr_events $t $n

  echo "=== e: plain exit 137, no signal"
  n=x137-plain; t=$(date +%s)
  say "docker run --name $n busybox:1.37 sh -c 'exit 137'"
  state $n
  dkr_events $t $n

  echo "=== f: OOM kills a child, the shell (PID 1) survives and exits 0"
  n=x137-child; t=$(date +%s)
  say "docker run --name $n --memory 128m --memory-swap 128m $P sh -c 'python -c \"b = b\\\"\\\\x01\\\" * (200 << 20)\"; echo child exit \$?; exit 0'"
  state $n
  dkr_events $t $n

  echo "=== g: OOM kills a child, the shell passes its status on"
  n=x137-child2; t=$(date +%s)
  say "docker run --name $n --memory 128m --memory-swap 128m $P sh -c 'python -c \"b = b\\\"\\\\x01\\\" * (200 << 20)\"; exit \$?'"
  state $n

  echo "=== h: compose"
  mkdir -p /tmp/x137c && cat > /tmp/x137c/compose.yaml <<Y
services:
  app:
    image: $P
    command: ["python", "-c", "b = b'\\\\x01' * (200 << 20)"]
    mem_limit: 128m
    memswap_limit: 128m
Y
  say "docker compose -f /tmp/x137c/compose.yaml up --abort-on-container-exit --exit-code-from app"
  docker rm -f x137-oom x137-kill x137-stop x137-init x137-plain x137-child x137-child2 >/dev/null 2>&1
}

section_shell() {
  echo "=== a: SIGKILL in a plain shell"
  say "bash -c 'sleep 100 & kill -9 \$!; wait \$!; echo status \$?'"
  echo "=== b: kernel OOM kill of a service in a cgroup, no container"
  say "sudo systemd-run --wait --pipe --collect --unit=x137-demo -p MemoryMax=128M -p MemorySwapMax=0 python3 -c 'b = b\"\\x01\" * (300 << 20); print(\"allocated\")'"
  say "journalctl -u x137-demo --no-pager | tail -5"
  echo "=== c: same, in a shell"
  say "sudo systemd-run --scope -q -p MemoryMax=128M -p MemorySwapMax=0 bash -c 'python3 -c \"b = b\\\"\\\\x01\\\" * (300 << 20)\"; echo python status \$?'"
  say "sudo dmesg | grep -E 'Killed process' | tail -2 | cut -c1-200"
  echo "=== d: docker build"
  mkdir -p /tmp/x137b && cat > /tmp/x137b/Dockerfile <<'Y'
FROM python:3.12-alpine
RUN python -c "b = b'\x01' * (600 << 20); print('allocated')"
Y
  say "docker buildx create --name x137 --driver docker-container --driver-opt memory=256m --driver-opt memory-swap=256m --bootstrap >/dev/null 2>&1"
  say "docker buildx build --builder x137 --no-cache --progress=plain /tmp/x137b 2>&1 | tail -14"
  docker buildx rm x137 >/dev/null 2>&1
}

{ uname -a; docker exec $W sh -c 'containerd --version; crictl --version; cat /etc/os-release | head -2; stat -fc %T /sys/fs/cgroup'; grep -i cgroupDriver /dev/null; docker exec $W grep -i cgroupDriver /var/lib/kubelet/config.yaml; free -m; docker inspect python:3.12-alpine busybox:1.37 --format '{{.RepoDigests}}' 2>/dev/null; docker exec $W crictl images | grep -E 'python|busybox'; } > "$OUT/env.txt" 2>&1

section_shop        > "$OUT/01-shop-worker.txt" 2>&1
section_oom         > "$OUT/02-oom-limit.txt" 2>&1
section_probe       > "$OUT/03-liveness.txt" 2>&1
section_stop        > "$OUT/04-stop.txt" 2>&1
section_plain_delete > "$OUT/05-plain-delete.txt" 2>&1
section_nonsignal   > "$OUT/06-not-oom-other.txt" 2>&1
k -n $NS delete pod oom-limit probe-trap probe-no-handler probe-handled plain-exit host-kill --wait=false >/dev/null 2>&1
section_tally       > "$OUT/07-tally.txt" 2>&1
section_node_oom    > "$OUT/08-node-oom.txt" 2>&1
section_docker      > "$OUT/09-docker.txt" 2>&1
section_shell       > "$OUT/10-shell-and-build.txt" 2>&1
exit 0
