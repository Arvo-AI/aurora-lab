#!/usr/bin/env bash
# Everything the exit-code-143 runbook shows. Runs after break.sh, with kubectl on
# the lab cluster, and writes to $OUT. Each part is independent; PARTS picks them.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
F="$HERE/files"
PARTS="${PARTS:-signal docker compose scenario k8s compare evict audit}"
NS=t143
JDK=eclipse-temurin:21-jdk-alpine
PY=python:3.12-alpine
k() { kubectl -n "$NS" "$@"; }
say() { echo; echo "\$ $*"; }
run() { say "$*"; "$@" 2>&1; }

part_signal() {
  local o="$OUT/01-signal.txt"
  {
    say 'kill -l 15'; bash -c 'kill -l 15'
    say 'kill -l 143'; bash -c 'kill -l 143'
    say 'sleep 60 & pid=$!; kill -TERM $pid; wait $pid; echo $?'
    bash -c 'sleep 60 & pid=$!; kill -TERM $pid; wait $pid 2>/dev/null; echo $?'
    say 'sleep 60 & pid=$!; kill -KILL $pid; wait $pid; echo $?'
    bash -c 'sleep 60 & pid=$!; kill -KILL $pid; wait $pid 2>/dev/null; echo $?'
  } > "$o" 2>&1
}

# ---- what each process does with SIGTERM when it is PID 1 ------------------
dt() { # label, then docker run args
  local label="$1"; shift
  docker rm -f x143 >/dev/null 2>&1
  docker run -d --name x143 "$@" >/dev/null || { echo "$label|RUN FAILED"; return; }
  sleep "${WAIT:-4}"
  local comm cmd sig t0 t1 code
  comm=$(docker exec x143 cat /proc/1/comm 2>/dev/null)
  sig=$(docker inspect -f '{{.Config.StopSignal}}' x143)
  t0=$(date +%s.%N); docker stop -t 5 x143 >/dev/null; t1=$(date +%s.%N)
  code=$(docker inspect -f '{{.State.ExitCode}}' x143)
  printf '%s | PID1=%s | stopsignal=%s | exit=%s | stop_took=%.1fs\n' "$label" "$comm" "${sig:-default}" "$code" "$(echo "$t1 - $t0" | bc)"
  docker logs x143 2>&1 | grep -v -E '^(Note:|WARNING)' | sed 's/^/    log: /' | head -6
  docker rm -f x143 >/dev/null
}

part_docker() {
  local o="$OUT/02-pid1-table.txt" w; w=$(mktemp -d)
  cp "$F"/*.py "$F"/*.sh "$F"/Server.java "$w"/; chmod -R a+rX "$w"
  cat > "$w/main.go" <<'EOF'
package main

import "time"

func main() { time.Sleep(time.Hour) }
EOF
  docker run --rm -v "$w:/w" -w /w -e CGO_ENABLED=0 golang:1.24-alpine go build -o /w/gosleep main.go
  for t in shell-alpine shell-slim shell-two; do
    mkdir -p "$w/$t"; cp "$F/app.py" "$w/$t/app.py"
  done
  printf 'FROM python:3.12-alpine\nCOPY app.py /app/app.py\nCMD python3 -u /app/app.py\n' > "$w/shell-alpine/Dockerfile"
  printf 'FROM python:3.12-slim\nCOPY app.py /app/app.py\nCMD python3 -u /app/app.py\n' > "$w/shell-slim/Dockerfile"
  printf 'FROM python:3.12-alpine\nCOPY app.py /app/app.py\nCMD echo starting && python3 -u /app/app.py\n' > "$w/shell-two/Dockerfile"
  for t in shell-alpine shell-slim shell-two; do docker build -q -t "x143-$t" "$w/$t" >/dev/null; done
  {
    echo "# docker stop -t 5 against each container. Measured with docker $(docker version --format '{{.Server.Version}}')."
    echo "## no signal code in the app"
    dt 'python, no handler' $PY python -c 'import time; time.sleep(600)'
    dt 'python, no handler, docker --init' --init $PY python -c 'import time; time.sleep(600)'
    dt 'node, no handler' node:22-alpine node -e 'setInterval(()=>{},1000)'
    dt 'node, no handler, docker --init' --init node:22-alpine node -e 'setInterval(()=>{},1000)'
    dt 'go, no handler' -v "$w:/w:ro" alpine:3.20 /w/gosleep
    dt 'go, no handler, docker --init' --init -v "$w:/w:ro" alpine:3.20 /w/gosleep
    WAIT=8 dt 'java, no handler' -v "$w:/w:ro" -e MODE=nohook $JDK java /w/Server.java
    WAIT=8 dt 'java, shutdown hook' -v "$w:/w:ro" -e MODE=hook $JDK java /w/Server.java
    dt 'nginx' nginx:1.27-alpine
    dt 'redis' redis:7.4-alpine
    echo "## with a handler"
    dt 'python, handler exits 0' -v "$w:/app:ro" $PY python3 -u /app/app.py
    dt 'node, handler exits 0' node:22-alpine node -e "process.on('SIGTERM',()=>process.exit(0));setInterval(()=>{},1000)"
    WAIT=8 dt 'java, handler exits 0' -v "$w:/w:ro" -e MODE=handler $JDK java /w/Server.java
    echo "## shell in front of an app that handles SIGTERM (app.py logs when it gets it)"
    dt 'Dockerfile shell form, alpine' x143-shell-alpine
    dt 'Dockerfile shell form, slim (dash)' x143-shell-slim
    dt 'Dockerfile shell form, two commands' x143-shell-two
    dt 'sh -c two commands, alpine' -v "$w:/app:ro" $PY sh -c 'echo starting; python3 -u /app/app.py'
    dt 'bash -c two commands, slim' -v "$w:/app:ro" python:3.12-slim bash -c 'echo starting; python3 -u /app/app.py'
    dt 'entrypoint script, no exec' -v "$w:/app:ro" $PY sh /app/wrap-noexec.sh
    dt 'entrypoint script, no exec, slim' -v "$w:/app:ro" python:3.12-slim sh /app/wrap-noexec.sh
    dt 'entrypoint script, exec' -v "$w:/app:ro" $PY sh /app/wrap-exec.sh
    dt 'entrypoint script, trap with foreground child' -v "$w:/app:ro" $PY sh /app/wrap-trap-foreground.sh
    dt 'entrypoint script, trap forwards to background child' -v "$w:/app:ro" $PY sh /app/wrap-trap-forward.sh
    dt 'entrypoint script, no exec, docker --init' --init -v "$w:/app:ro" $PY sh /app/wrap-noexec.sh
  } > "$o" 2>&1
  for img in $PY python:3.12-slim node:22-alpine alpine:3.20 $JDK golang:1.24-alpine nginx:1.27-alpine redis:7.4-alpine; do
    echo "$img $(docker inspect -f '{{index .RepoDigests 0}}' "$img" 2>/dev/null)"
  done > "$OUT/02-images.txt"
  docker run --rm $JDK java -version >> "$OUT/02-images.txt" 2>&1
  docker run --rm node:22-alpine node -v >> "$OUT/02-images.txt" 2>&1
  docker run --rm golang:1.24-alpine go version >> "$OUT/02-images.txt" 2>&1
  docker run --rm $PY python -V >> "$OUT/02-images.txt" 2>&1
  docker run --rm $PY sh -c 'ls -l /bin/sh; busybox --help | head -1' >> "$OUT/02-images.txt" 2>&1
  docker run --rm python:3.12-slim sh -c 'ls -l /bin/sh; dpkg-query -W dash' >> "$OUT/02-images.txt" 2>&1
}

part_compose() {
  local o="$OUT/03-compose.txt" w; w=$(mktemp -d)
  cp "$F/Server.java" "$w/"
  cat > "$w/compose.yaml" <<EOF
services:
  web:
    image: $JDK
    command: ["java", "/w/Server.java"]
    volumes: ["./:/w:ro"]
  migrate:
    image: alpine:3.20
    command: ["sh", "-c", "sleep 10; echo migrate done"]
EOF
  ( cd "$w"
    { run docker compose version
      say 'docker compose up --abort-on-container-exit'
      docker compose -p x143 up --abort-on-container-exit --no-color 2>&1 | grep -v -E 'Pulling|Pulled|Waiting|Downloading|Extracting|Verifying'
      echo "(exit status of docker compose: ${PIPESTATUS[0]})"
      say 'docker compose ps -a --format "table {{.Service}}\t{{.Status}}"'
      docker compose -p x143 ps -a --format 'table {{.Service}}\t{{.Status}}' 2>&1
      docker compose -p x143 down 2>&1 | tail -0
      say 'docker compose up web, and from a second shell: docker compose stop web'
      docker compose -p x143 up --no-color web > "$w/up.log" 2>&1 &
      local up=$!
      sleep 12
      docker compose -p x143 stop web 2>&1
      wait $up
      grep -E 'web-1' "$w/up.log"
      docker compose -p x143 down 2>&1 | tail -0
    } > "$o" 2>&1 )
}

part_scenario() {
  local o="$OUT/04-scenario-liveness.txt" p
  p=$(kubectl -n shop get pods -l app=api -o json | jq -r '.items[] | select(.status.containerStatuses[0].lastState.terminated.exitCode==143) | .metadata.name' | head -1)
  {
    run kubectl -n shop get pods -l app=api
    run kubectl -n shop describe pod "$p"
    say "kubectl -n shop get events --field-selector involvedObject.name=$p --sort-by=.lastTimestamp"
    kubectl -n shop get events --field-selector involvedObject.name="$p" --sort-by=.lastTimestamp
    say "kubectl -n shop get pod $p -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'"
    kubectl -n shop get pod "$p" -o jsonpath='{.status.containerStatuses[0].lastState.terminated}'; echo
    say "kubectl -n shop logs $p --previous --tail=8"
    kubectl -n shop logs "$p" --previous --tail=8
    say "kubectl -n shop get pods -o custom-columns=POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST_EXIT:.status.containerStatuses[0].lastState.terminated.exitCode,LAST_REASON:.status.containerStatuses[0].lastState.terminated.reason"
    kubectl -n shop get pods -o 'custom-columns=POD:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,LAST_EXIT:.status.containerStatuses[0].lastState.terminated.exitCode,LAST_REASON:.status.containerStatuses[0].lastState.terminated.reason'
    say 'kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp'
    kubectl get events -A --field-selector reason=Killing --sort-by=.lastTimestamp
  } > "$o" 2>&1
  {
    say 'revert: remove the time.sleep(2) from /healthz in the api-code ConfigMap, then restart'
    kubectl -n shop get cm api-code -o json | python3 -c '
import json, sys
cm = json.load(sys.stdin)
cm["data"]["api.py"] = cm["data"]["api.py"].replace("                time.sleep(2)  # stock service check\n", "")
for k in ("resourceVersion", "uid", "creationTimestamp", "managedFields"):
    cm["metadata"].pop(k, None)
print(json.dumps(cm))' | kubectl apply -f -
    run kubectl -n shop rollout restart deploy/api
    run kubectl -n shop rollout status deploy/api --timeout=180s
    sleep 60
    say 'after 60 s: kubectl -n shop get pods -l app=api'; kubectl -n shop get pods -l app=api
    say 'kubectl -n shop exec deploy/loadgen -- wget -qO- http://frontend/api/items'; kubectl -n shop exec deploy/loadgen -- wget -qO- http://frontend/api/items; echo
  } > "$OUT/04-scenario-fix.txt" 2>&1
}

# ---- kubernetes helpers ----------------------------------------------------
setup_ns() {
  kubectl delete ns "$NS" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl create ns "$NS" >/dev/null
  k create cm code --from-file="$F" >/dev/null
}
jvm_pod_spec() { # mode grace extra-container-yaml
  cat <<EOF
    spec:
      terminationGracePeriodSeconds: $2
      containers:
      - name: app
        image: $JDK
        command: ["java", "/code/Server.java"]
        env: [{name: MODE, value: "$1"}]
        ports: [{containerPort: 8080}]
        readinessProbe:
          httpGet: {path: /healthz, port: 8080}
          periodSeconds: 1
$3
        volumeMounts: [{name: code, mountPath: /code}]
      volumes:
      - name: code
        configMap: {name: code}
EOF
}
deploy() { # name replicas mode grace extra
  { cat <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: $1, namespace: $NS}
spec:
  replicas: $2
  selector: {matchLabels: {app: $1}}
  template:
    metadata: {labels: {app: $1}}
EOF
    jvm_pod_spec "$3" "$4" "${5:-}"
    cat <<EOF
---
apiVersion: v1
kind: Service
metadata: {name: $1, namespace: $NS}
spec:
  selector: {app: $1}
  ports: [{port: 8080, targetPort: 8080}]
EOF
  } | kubectl apply -f - >/dev/null
  k rollout status "deploy/$1" --timeout=180s >/dev/null
}
watch_start() { kubectl -n "$NS" get pods -w --output-watch-events -o json > "$1" 2>/dev/null & WPID=$!; sleep 1; }
watch_stop() { sleep 1; kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
term_summary() { # raw watch file -> one line per terminated container
  jq -r 'select(.object.status.containerStatuses != null) | .object as $p
    | $p.status.containerStatuses[] | select(.state.terminated != null) as $c
    | [$p.metadata.name, "exit=\($c.state.terminated.exitCode)", "reason=\($c.state.terminated.reason)",
       "signal=\($c.state.terminated.signal // "none")", "deletionTimestamp=\($p.metadata.deletionTimestamp // "none")",
       "grace=\($p.metadata.deletionGracePeriodSeconds // "none")", "finishedAt=\($c.state.terminated.finishedAt)",
       "disruption=\(([$p.status.conditions[]? | select(.type=="DisruptionTarget") | .reason+"/"+.message]|first) // "none")"]
    | join(" ")' "$1" | awk '!seen[$0]++'
}
pod_of() { k get pods -l app="$1" -o jsonpath='{.items[0].metadata.name}'; }
describe_tail() { k describe pod "$1" | sed -n '/^Containers:/,/^Conditions:/p'; k get events --field-selector involvedObject.name="$1" --sort-by=.lastTimestamp; }

part_k8s() {
  setup_ns
  local p raw
  # 5. healthy rollout
  raw=$(mktemp); deploy web 2 nohook 30
  {
    say 'kubectl -n t143 rollout restart deploy/web (watching pod status while it runs)'
    watch_start "$raw"
    k rollout restart deploy/web; k rollout status deploy/web --timeout=180s
    watch_stop
    say 'terminated containers seen by the watch'; term_summary "$raw"
    say 'kubectl -n t143 get pods'; k get pods -l app=web
    say 'kubectl -n t143 get events --sort-by=.lastTimestamp'; k get events --sort-by=.lastTimestamp | grep -E 'Killing|SuccessfulDelete|ScalingReplicaSet'
  } > "$OUT/05-rollout.txt" 2>&1

  # 6. liveness kill on a process that exits 143
  deploy live 1 nohook 10 '        livenessProbe:
          httpGet: {path: /healthz, port: 8080}
          periodSeconds: 3
          failureThreshold: 2'
  p=$(pod_of live)
  {
    say "kubectl -n t143 exec $p -- wget -qO- localhost:8080/break"; k exec "$p" -- wget -qO- localhost:8080/break
    sleep 25
    say "kubectl -n t143 describe pod $p (trimmed to container and events)"; describe_tail "$p"
  } > "$OUT/06-liveness-143.txt" 2>&1

  # 7. shell wrapper, killed by the same mechanism, kept status shows 137
  for v in noexec exec; do
    cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: wrap-$v, namespace: $NS}
spec:
  terminationGracePeriodSeconds: 5
  containers:
  - name: app
    image: $PY
    command: ["sh", "/app/wrap-$v.sh"]
    livenessProbe:
      exec: {command: ["sh", "-c", "test ! -f /tmp/broken"]}
      periodSeconds: 3
      failureThreshold: 1
    volumeMounts: [{name: code, mountPath: /app}]
  volumes:
  - name: code
    configMap: {name: code}
EOF
    k wait --for=condition=Ready "pod/wrap-$v" --timeout=120s >/dev/null
    sleep 2
    {
      say "kubectl -n t143 exec wrap-$v -- ps -o pid,comm,args"; k exec "wrap-$v" -- ps -o pid,comm,args
      say "kubectl -n t143 exec wrap-$v -- touch /tmp/broken"; k exec "wrap-$v" -- touch /tmp/broken
      sleep 20
      say "kubectl -n t143 describe pod wrap-$v (trimmed)"; describe_tail "wrap-$v"
      say "kubectl -n t143 logs wrap-$v --previous"; k logs "wrap-$v" --previous
    } > "$OUT/07-wrapper-$v.txt" 2>&1
  done

  # 8. SIGTERM from inside the container: no Killing event
  deploy inside 1 nohook 10
  p=$(pod_of inside)
  {
    say "kubectl -n t143 exec $p -- kill -TERM 1"; k exec "$p" -- kill -TERM 1
    sleep 15
    say "kubectl -n t143 describe pod $p (trimmed)"; describe_tail "$p"
  } > "$OUT/08-inside-kill.txt" 2>&1

  # 9. preStop paths, status kept by a liveness restart or read from the watch
  deploy hookfail 1 hook 15 '        livenessProbe:
          httpGet: {path: /healthz, port: 8080}
          periodSeconds: 3
          failureThreshold: 2
        lifecycle:
          preStop:
            exec: {command: ["sh", "-c", "echo prestop failing; exit 3"]}'
  p=$(pod_of hookfail)
  {
    say "kubectl -n t143 exec $p -- wget -qO- localhost:8080/break"; k exec "$p" -- wget -qO- localhost:8080/break
    sleep 25
    say "kubectl -n t143 describe pod $p (trimmed)"; describe_tail "$p"
    say "kubectl -n t143 logs $p --previous --tail=5"; k logs "$p" --previous --tail=5
  } > "$OUT/09-prestop-fails.txt" 2>&1

  deploy hooklong 1 hook 5 '        lifecycle:
          preStop:
            exec: {command: ["sh", "-c", "sleep 30"]}'
  p=$(pod_of hooklong); raw=$(mktemp)
  {
    echo "# preStop sleeps 30 s, terminationGracePeriodSeconds is 5"
    watch_start "$raw"
    say "kubectl -n t143 delete pod $p"; date -u +%FT%TZ; k delete pod "$p" --wait=false
    for i in $(seq 1 40); do k get pod "$p" >/dev/null 2>&1 || break; sleep 1; done
    date -u +%FT%TZ
    watch_stop
    say 'terminated containers seen by the watch'; term_summary "$raw"
    say "kubectl -n t143 get events --field-selector involvedObject.name=$p"; k get events --field-selector involvedObject.name="$p" --sort-by=.lastTimestamp
  } > "$OUT/09-prestop-too-long.txt" 2>&1
  kubectl delete ns "$NS" --wait=true >/dev/null 2>&1
}

# ---- in-flight requests across a rollout ------------------------------------
one_variant() { # name
  local n="$1" raw i
  raw=$(mktemp)
  for i in 1 2 3; do
    k exec client -- rm -f /tmp/stop
    watch_start "$raw"
    k exec client -- python -u /code/client.py "$n" 12 > "$OUT/.c" 2>&1 &
    local cp=$!
    sleep 5
    local t0 t1
    t0=$(date +%s)
    k rollout restart "deploy/$n" >/dev/null
    k rollout status "deploy/$n" --timeout=240s >/dev/null
    t1=$(date +%s)
    sleep 12
    k exec client -- touch /tmp/stop
    wait $cp
    watch_stop
    echo "$n rollout $i (${t0:+$((t1 - t0))s}): $(cat "$OUT/.c")"
    sleep 3
  done
  echo "$n exit codes seen: $(term_summary "$raw" | awk '{print $2, $3}' | sort | uniq -c | tr '\n' ';')"
  rm -f "$OUT/.c"
}
part_compare() {
  setup_ns
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: client, namespace: $NS}
spec:
  containers:
  - name: client
    image: $PY
    command: ["sleep", "7200"]
    volumeMounts: [{name: code, mountPath: /code}]
  volumes:
  - name: code
    configMap: {name: code}
EOF
  k wait --for=condition=Ready pod/client --timeout=120s >/dev/null
  deploy nohook 2 nohook 30
  deploy hook 2 hook 30
  deploy handler 2 handler 30
  deploy prestop 2 handler 30 '        lifecycle:
          preStop:
            sleep: {seconds: 5}'
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: apps/v1
kind: Deployment
metadata: {name: pid1, namespace: $NS}
spec:
  replicas: 2
  selector: {matchLabels: {app: pid1}}
  template:
    metadata: {labels: {app: pid1}}
    spec:
      terminationGracePeriodSeconds: 8
      containers:
      - name: app
        image: $PY
        command: ["python", "-u", "/code/slow.py"]
        readinessProbe:
          httpGet: {path: /healthz, port: 8080}
          periodSeconds: 1
        volumeMounts: [{name: code, mountPath: /code}]
      volumes:
      - name: code
        configMap: {name: code}
---
apiVersion: v1
kind: Service
metadata: {name: pid1, namespace: $NS}
spec:
  selector: {app: pid1}
  ports: [{port: 8080, targetPort: 8080}]
EOF
  k rollout status deploy/pid1 --timeout=120s >/dev/null
  {
    echo "# 12 client threads, one 1-second request per connection, no retries, across three rollout restarts of 2 replicas"
    for n in nohook hook handler prestop pid1; do one_variant "$n"; done
  } > "$OUT/10-inflight.txt" 2>&1
  kubectl delete ns "$NS" --wait=true >/dev/null 2>&1
}

part_evict() {
  setup_ns
  local raw p node alloc victim
  # 11. kubectl drain, which goes through the Eviction API
  raw=$(mktemp); deploy drainme 1 nohook 30
  p=$(pod_of drainme); node=$(k get pod "$p" -o jsonpath='{.spec.nodeName}')
  {
    watch_start "$raw"
    say "kubectl drain $node --ignore-daemonsets --delete-emptydir-data --force"
    kubectl drain "$node" --ignore-daemonsets --delete-emptydir-data --force --timeout=120s 2>&1 | grep -E "$p|drained|cordoned"
    watch_stop
    say 'terminated containers seen by the watch'; term_summary "$raw"
    say "kubectl -n t143 get events --field-selector involvedObject.name=$p"; k get events --field-selector involvedObject.name="$p" --sort-by=.lastTimestamp
    kubectl uncordon "$node" >/dev/null
  } > "$OUT/11-drain.txt" 2>&1

  # 12. kubelet eviction: ephemeral-storage limit
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata: {name: disk-hog, namespace: $NS}
spec:
  restartPolicy: Never
  terminationGracePeriodSeconds: 10
  containers:
  - name: app
    image: $JDK
    command: ["sh", "-c", "dd if=/dev/zero of=/tmp/fill bs=1M count=200 2>/dev/null; exec java /code/Server.java"]
    resources:
      limits: {ephemeral-storage: 64Mi}
    volumeMounts: [{name: code, mountPath: /code}]
  volumes:
  - name: code
    configMap: {name: code}
EOF
  for i in $(seq 1 60); do [ "$(k get pod disk-hog -o jsonpath='{.status.phase}')" = Failed ] && break; sleep 5; done
  {
    run kubectl -n t143 get pod disk-hog
    say 'kubectl -n t143 get pod disk-hog -o json | jq .status'
    k get pod disk-hog -o json | jq '.status | {phase, reason, message, conditions: [.conditions[]? | select(.type=="DisruptionTarget")], containerStatuses: [.containerStatuses[]? | {name, state, lastState}]}'
    say 'kubectl -n t143 get events --field-selector involvedObject.name=disk-hog'; k get events --field-selector involvedObject.name=disk-hog --sort-by=.lastTimestamp
  } > "$OUT/12-kubelet-eviction.txt" 2>&1

  # 13. preemption
  node=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
  alloc=$(kubectl get node "$node" -o json | jq -r '.status.allocatable.cpu | if endswith("m") then rtrimstr("m")|tonumber else tonumber*1000 end')
  victim=$(( alloc * 7 / 10 ))
  cat <<EOF | kubectl apply -f - >/dev/null
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata: {name: t143-high}
value: 100000
---
apiVersion: v1
kind: Pod
metadata: {name: victim, namespace: $NS}
spec:
  nodeSelector: {kubernetes.io/hostname: $node}
  terminationGracePeriodSeconds: 10
  containers:
  - name: app
    image: $JDK
    command: ["java", "/code/Server.java"]
    resources: {requests: {cpu: ${victim}m}}
    volumeMounts: [{name: code, mountPath: /code}]
  volumes:
  - name: code
    configMap: {name: code}
EOF
  k wait --for=condition=Ready pod/victim --timeout=120s >/dev/null
  sleep 6
  raw=$(mktemp)
  {
    watch_start "$raw"
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata: {name: important, namespace: $NS}
spec:
  priorityClassName: t143-high
  nodeSelector: {kubernetes.io/hostname: $node}
  containers:
  - name: app
    image: $PY
    command: ["sleep", "300"]
    resources: {requests: {cpu: ${victim}m}}
EOF
    sleep 30
    watch_stop
    say 'terminated containers seen by the watch'; term_summary "$raw"
    say 'kubectl -n t143 get events --field-selector involvedObject.name=victim'; k get events --field-selector involvedObject.name=victim --sort-by=.lastTimestamp
  } > "$OUT/13-preemption.txt" 2>&1
  kubectl delete priorityclass t143-high >/dev/null 2>&1
  kubectl delete ns "$NS" --wait=true >/dev/null 2>&1
}

part_audit() {
  local w kc o="$OUT/14-audit.txt" node log; w=$(mktemp -d); kc="$w/kubeconfig"
  cat > "$w/policy.yaml" <<'EOF'
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: Metadata
  verbs: ["delete", "deletecollection", "create"]
  resources:
  - group: ""
    resources: ["pods", "pods/eviction"]
- level: None
EOF
  cat > "$w/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        audit-log-path: /var/log/kubernetes/audit.log
        audit-policy-file: /etc/kubernetes/policies/audit-policy.yaml
      extraVolumes:
      - name: audit-policies
        hostPath: /etc/kubernetes/policies
        mountPath: /etc/kubernetes/policies
        readOnly: true
        pathType: DirectoryOrCreate
      - name: audit-logs
        hostPath: /var/log/kubernetes
        mountPath: /var/log/kubernetes
        readOnly: false
        pathType: DirectoryOrCreate
  extraMounts:
  - hostPath: $w/policy.yaml
    containerPath: /etc/kubernetes/policies/audit-policy.yaml
    readOnly: true
- role: worker
EOF
  kind create cluster --name audit143 --config "$w/kind.yaml" --kubeconfig "$kc" --wait 180s > "$OUT/14-audit-cluster.log" 2>&1
  (
    export KUBECONFIG="$kc"
    kubectl create ns "$NS" >/dev/null
    k create cm code --from-file="$F" >/dev/null
    deploy who 3 nohook 2
    local p node
    p=$(pod_of who)
    {
      say "kubectl -n t143 delete pod $p"; k delete pod "$p"
      k rollout status deploy/who --timeout=120s >/dev/null
      say 'kubectl -n t143 rollout restart deploy/who'; k rollout restart deploy/who
      k rollout status deploy/who --timeout=180s >/dev/null
      say 'kubectl -n t143 scale deploy/who --replicas=2'; k scale deploy/who --replicas=2
      sleep 6
      node=audit143-worker
      say "kubectl drain $node --ignore-daemonsets --force --delete-emptydir-data"
      kubectl drain "$node" --ignore-daemonsets --force --delete-emptydir-data --timeout=120s 2>&1 | tail -1
      sleep 3
      kubectl uncordon "$node" >/dev/null
      deploy live 1 nohook 2 '"'"'        livenessProbe:
          httpGet: {path: /healthz, port: 8080}
          periodSeconds: 3
          failureThreshold: 2'"'"'
      local lp; lp=$(pod_of live)
      say "kubectl -n t143 exec $lp -- wget -qO- localhost:8080/break"; k exec "$lp" -- wget -qO- localhost:8080/break
      sleep 15
      say "kubectl -n t143 get pod $lp"; k get pod "$lp"
      say 'on the control plane: jq over /var/log/kubernetes/audit.log'
      docker exec audit143-control-plane cat /var/log/kubernetes/audit.log |
        jq -r 'select(.stage=="ResponseComplete" and .objectRef.namespace=="t143" and .objectRef.resource=="pods" and (.verb=="delete" or .objectRef.subresource=="eviction"))
               | [.stageTimestamp, .verb, (.objectRef.resource + (if .objectRef.subresource then "/"+.objectRef.subresource else "" end)), .objectRef.name, .user.username, (.userAgent|split(" ")[0]), .responseStatus.code] | @tsv' |
        grep -v '^$' | sort -u
      say 'kubectl -n t143 get events | grep Killing | head -3'; k get events --sort-by=.lastTimestamp | grep Killing | head -3
      say "audit entries for the liveness-killed pod $lp"; docker exec audit143-control-plane cat /var/log/kubernetes/audit.log | jq -r --arg p "$lp" 'select(.objectRef.name==$p and .verb=="delete")' | wc -l
    } > "$o" 2>&1
  )
  kind delete cluster --name audit143 >/dev/null 2>&1
}

for part in $PARTS; do
  echo "=== $part $(date -u +%T)"
  "part_$part"
done
kubectl version > "$OUT/versions-k8s.txt" 2>&1
kind version >> "$OUT/versions-k8s.txt" 2>&1
kubectl get nodes -o wide >> "$OUT/versions-k8s.txt" 2>&1
echo "=== done $(date -u +%T)"
