#!/usr/bin/env bash
# Runs on a kind cluster after break.sh. Builds the test image, then reproduces
# every cause on the runbook and writes each transcript to $OUT/rst/.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; C="$HERE/causes"; R="$OUT/rst"; mkdir -p "$R"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"

# scenario evidence from shop, before anything else
{ echo '$ kubectl -n shop logs deploy/uploader --tail=20'; kubectl -n shop logs deploy/uploader --tail=20
  echo '$ kubectl -n shop get pods'; kubectl -n shop get pods
  echo '$ kubectl -n shop get events --sort-by=.lastTimestamp | tail -20'; kubectl -n shop get events --sort-by=.lastTimestamp | tail -20; } > "$R/00-shop-scenario.txt" 2>&1

docker build -q -t resetlab:24 "$C"
kind load docker-image resetlab:24 --name aurora-lab
kubectl apply -f "$C/rst.yaml"
kubectl -n rst rollout status deploy/srv --timeout=180s
kubectl -n rst wait --for=condition=Ready pod/client pod/sshbox --timeout=180s

c() { kubectl -n rst exec client -- "$@"; }
sh_c() { kubectl -n rst exec client -- sh -c "$1"; }
SVC=$(kubectl -n rst get svc srv -o jsonpath='{.spec.clusterIP}')
EMPTY=$(kubectl -n rst get svc empty -o jsonpath='{.spec.clusterIP}')
CLIENT_IP=$(kubectl -n rst get pod client -o jsonpath='{.status.podIP}')
srvpod() { kubectl -n rst get pods -l app=srv --field-selector=status.phase=Running -o name | head -1; }
srvip() { kubectl -n rst get pods -l app=srv --field-selector=status.phase=Running -o jsonpath='{.items[0].status.podIP}'; }
ready() { sleep 2; kubectl -n rst rollout status deploy/srv --timeout=120s >/dev/null; kubectl -n rst wait --for=condition=Ready pod -l app=srv --timeout=120s >/dev/null; sleep 2; }

{ date -u; kubectl version; kubectl get nodes -o wide
  sh_c 'cat /etc/alpine-release; uname -r; curl --version | head -1; python3 -V; python3 -c "import requests,urllib3;print(\"requests\",requests.__version__,\"urllib3\",urllib3.__version__)"; cat /app/goversion; node -v; tcpdump --version 2>&1 | head -2; ssh -V 2>&1'
  kubectl -n rst get pods -o wide; kubectl -n rst get svc; } > "$R/versions-image.txt" 2>&1

cap_on() { sh_c "tcpdump -l -nn -p -i eth0 -tttt -v 'tcp port 8080 or tcp port 8081 or tcp port 2222 or icmp' > /tmp/cap.txt 2>/tmp/cap.err & echo \$! > /tmp/cap.pid; sleep 1"; }
cap_off() { sleep 1; sh_c 'kill $(cat /tmp/cap.pid); sleep 1; cat /tmp/cap.txt'; }
srv_cap() { kubectl -n rst logs "$(srvpod)" -c cap --since="${1:-30s}" 2>/dev/null | grep -F -- "$CLIENT_IP" -B1 | grep -v '^--'; }
say() { echo; echo "\$ $*"; }

# 01 baseline and refused
{
echo "# healthy request: normal close uses FIN"; cap_on
say curl -sS -o /dev/null -w '%{http_code}\n' http://$SVC:8080/ok; c curl -sS -o /dev/null -w '%{http_code}\n' http://$SVC:8080/ok
echo "--- client capture"; cap_off
} > "$R/01-baseline-fin.txt" 2>&1
{
echo "# nothing listening: port 9 on the server pod IP"; IP=$(srvip); cap_on
sh_c "tcpdump -l -nn -p -i eth0 -tttt -v 'tcp port 9' > /tmp/cap9.txt 2>/dev/null & echo \$! > /tmp/cap9.pid; sleep 1"
say curl -sS http://$IP:9/; c curl -sS http://$IP:9/
c python3 /app/py_client.py get http://$IP:9/
c /app/rstclient one http://$IP:9/
c node /app/node_client.js get http://$IP:9/
sleep 1; echo "--- client capture"; sh_c 'kill $(cat /tmp/cap9.pid); sleep 1; cat /tmp/cap9.txt'; cap_off >/dev/null
echo "# ClusterIP with no endpoints"; cap_on
say curl -sS --max-time 5 http://$EMPTY:8080/; c curl -sS --max-time 5 http://$EMPTY:8080/
echo "--- client capture"; cap_off
} > "$R/02-refused.txt" 2>&1

# 03 rollout, no drain, requests in flight, two read speeds
for v in slowreader fastreader; do
  q=""; [ $v = fastreader ] && q="?fast=1"
  {
  echo "# rollout restart with no drain. server reads: $v"; ready
  sh_c 'head -c 41943040 /dev/zero > /tmp/body'; cap_on; OLD=$(srvpod)
  echo "old pod $OLD"; 
  sh_c "(curl -sS -o /dev/null -H 'Expect:' --limit-rate 1M --data-binary @/tmp/body 'http://$SVC:8080/upload$q' > /tmp/o.curl 2>&1; echo curl exit=\$? >> /tmp/o.curl) & 
        (python3 /app/py_client.py upload 'http://$SVC:8080/upload$q' > /tmp/o.py 2>&1) &
        (/app/rstclient one -X POST -mb 40 'http://$SVC:8080/upload$q' > /tmp/o.go 2>&1) &
        (node /app/node_client.js upload 'http://$SVC:8080/upload$q' > /tmp/o.node 2>&1) &
        (curl -sS -o /dev/null 'http://$SVC:8080/slow?ms=60000' > /tmp/o.slow 2>&1; echo slow-get curl exit=\$? >> /tmp/o.slow) &
        (curl -sS -o /dev/null 'http://$SVC:8080/stream' > /tmp/o.stream 2>&1; echo stream curl exit=\$? >> /tmp/o.stream) &
        (python3 /app/py_client.py get 'http://$SVC:8080/slow?ms=60000' > /tmp/o.slowpy 2>&1) &
        (/app/rstclient one 'http://$SVC:8080/stream' > /tmp/o.streamgo 2>&1) &
        sleep 0" < /dev/null >/dev/null 2>&1 &
  sleep 4
  say kubectl -n rst rollout restart deploy/srv; date -u +%T.%N; kubectl -n rst rollout restart deploy/srv; kubectl -n rst rollout status deploy/srv --timeout=120s
  date -u +%T.%N; sleep 8
  for f in curl py go node slow slowpy stream streamgo; do echo "--- client $f"; sh_c "cat /tmp/o.$f"; done
  sh_c 'pkill curl; pkill python3; pkill rstclient; pkill node' 
  echo "--- client capture"; cap_off
  } > "$R/03-rollout-$v.txt" 2>&1
done

# 04 error counts during rollouts, three configs
kubectl -n rst scale deploy/srv --replicas=3
rollcount() {
  echo "# config: $1"; ready
  sh_c "(/app/rstclient load -d 70s -c 8 'http://$SVC:8080/slow?ms=200' > /tmp/l.new 2>&1) & (/app/rstclient load -d 70s -c 8 -keepalive 'http://$SVC:8080/slow?ms=200' > /tmp/l.keep 2>&1) & sleep 0" </dev/null >/dev/null 2>&1 &
  sleep 3
  for i in 1 2 3; do kubectl -n rst rollout restart deploy/srv >/dev/null; kubectl -n rst rollout status deploy/srv --timeout=120s >/dev/null; sleep 1; done
  echo "rollouts done at $(date -u +%T)"; sh_c 'while pgrep rstclient >/dev/null; do sleep 1; done'
  echo "--- new connection per request"; sh_c 'cat /tmp/l.new'
  echo "--- keepalive"; sh_c 'cat /tmp/l.keep'
}
{
kubectl -n rst set env deploy/srv -c srv DRAIN=0 IDLE_MS=60000 >/dev/null
rollcount "A: exit on SIGTERM, no preStop"
kubectl -n rst set env deploy/srv -c srv DRAIN=1 >/dev/null
rollcount "B: graceful Shutdown on SIGTERM, no preStop"
kubectl -n rst patch deploy srv -p '{"spec":{"template":{"spec":{"containers":[{"name":"srv","lifecycle":{"preStop":{"sleep":{"seconds":5}}}}]}}}}'
rollcount "C: graceful Shutdown on SIGTERM, preStop sleep 5"
} > "$R/04-rollout-counts.txt" 2>&1
kubectl -n rst patch deploy srv --type=json -p '[{"op":"remove","path":"/spec/template/spec/containers/0/lifecycle"}]'
kubectl -n rst set env deploy/srv -c srv DRAIN- IDLE_MS=2000 >/dev/null
kubectl -n rst scale deploy/srv --replicas=1; ready

# 05 keepalive: deterministic late write
{
echo "# server IdleTimeout 2 s. Client writes 3 s after the last response"; cap_on
say python3 /app/raw_idle.py $SVC 8080 3; c python3 /app/raw_idle.py $SVC 8080 3
echo "--- client capture"; cap_off
echo; echo "# same, but the client reads before it writes again"; cap_on
say python3 /app/raw_idle.py $SVC 8080 3 read-first; c python3 /app/raw_idle.py $SVC 8080 3 read-first
echo "--- client capture"; cap_off
} > "$R/05-keepalive-late-write.txt" 2>&1

# 06 keepalive race sweep
{
echo "# Go client, POST (not replayable), reuse at 2 s +/- 5 ms, IdleTimeout 2 s"; cap_on
say rstclient sweep -X POST -idle 2s -window 5ms -c 50 -n 60 http://$SVC:8080/ok; c /app/rstclient sweep -X POST -idle 2s -window 5ms -c 50 -n 60 http://$SVC:8080/ok > "$R/06-sweep-go-post.raw" 2>&1
grep -v '^FAIL' "$R/06-sweep-go-post.raw"; grep -c '^FAIL' "$R/06-sweep-go-post.raw"; grep '^FAIL' "$R/06-sweep-go-post.raw" | head -40
sleep 1; sh_c 'kill $(cat /tmp/cap.pid); sleep 2; wc -l /tmp/cap.txt; grep -c "Flags \[R" /tmp/cap.txt'
sh_c 'cp /tmp/cap.txt /tmp/cap-sweep.txt'
sh_c 'gzip -c /tmp/cap-sweep.txt' > "$R/06-sweep-capture.txt.gz"
echo; echo "# Go client, GET (replayable), same timing"
say rstclient sweep -X GET -idle 2s -window 5ms -c 50 -n 30 http://$SVC:8080/ok; c /app/rstclient sweep -X GET -idle 2s -window 5ms -c 50 -n 30 http://$SVC:8080/ok | grep -v '^FAIL'
echo; echo "# Python requests.Session, POST, same timing"
say python3 /app/py_sweep.py http://$SVC:8080/ok 2 0.005 30 40; c python3 /app/py_sweep.py http://$SVC:8080/ok 2 0.005 30 40
} > "$R/06-keepalive-race.txt" 2>&1

# 07 process exit with a request in flight
{
echo "# 07a: handler has read the whole request, process exits, no response written"; ready; cap_on
say curl -sS http://$SVC:8080/crash; c curl -sS http://$SVC:8080/crash; ready
say python3 /app/py_client.py get http://$SVC:8080/crash; c python3 /app/py_client.py get http://$SVC:8080/crash; ready
say rstclient one http://$SVC:8080/crash; c /app/rstclient one http://$SVC:8080/crash; ready
say node /app/node_client.js get http://$SVC:8080/crash; c node /app/node_client.js get http://$SVC:8080/crash; ready
echo "--- client capture"; cap_off
echo; kubectl -n rst get pods -l app=srv
} > "$R/07a-crash-request-read.txt" 2>&1
kubectl -n rst rollout restart deploy/srv >/dev/null
{
echo "# 07b: upload in flight, another request crashes the process"; ready; cap_on
sh_c "(curl -sS -o /dev/null -H 'Expect:' --limit-rate 1M --data-binary @/tmp/body 'http://$SVC:8080/upload' > /tmp/o.curl 2>&1; echo curl exit=\$? >> /tmp/o.curl) &
      (python3 /app/py_client.py upload 'http://$SVC:8080/upload' > /tmp/o.py 2>&1) &
      (/app/rstclient one -X POST -mb 40 'http://$SVC:8080/upload' > /tmp/o.go 2>&1) &
      (node /app/node_client.js upload 'http://$SVC:8080/upload' > /tmp/o.node 2>&1) &
      sleep 0" </dev/null >/dev/null 2>&1 &
sleep 4; c curl -sS --max-time 3 http://$SVC:8080/crash; sleep 6
for f in curl py go node; do echo "--- client $f"; sh_c "cat /tmp/o.$f"; done
sh_c 'pkill curl; pkill python3; pkill rstclient; pkill node'
echo "--- client capture"; cap_off
} > "$R/07b-crash-upload.txt" 2>&1
kubectl -n rst rollout restart deploy/srv >/dev/null
{
echo "# 07c: single-threaded server. One request in its handler, four queued unaccepted, then the process exits"; ready; cap_on
sh_c "(curl -sS -o /dev/null 'http://$SVC:8081/die?ms=5000' > /tmp/o.first 2>&1; echo first curl exit=\$? >> /tmp/o.first) &
      sleep 1
      (curl -sS -o /dev/null 'http://$SVC:8081/ok' > /tmp/o.curl 2>&1; echo queued curl exit=\$? >> /tmp/o.curl) &
      (python3 /app/py_client.py get 'http://$SVC:8081/ok' > /tmp/o.py 2>&1) &
      (/app/rstclient one 'http://$SVC:8081/ok' > /tmp/o.go 2>&1) &
      (node /app/node_client.js get 'http://$SVC:8081/ok' > /tmp/o.node 2>&1) &
      sleep 0" </dev/null >/dev/null 2>&1 &
sleep 8
for f in first curl py go node; do echo "--- client $f"; sh_c "cat /tmp/o.$f"; done
echo "--- client capture"; cap_off
} > "$R/07c-crash-accept-queue.txt" 2>&1
kubectl -n rst rollout restart deploy/srv >/dev/null
{
echo "# 07d: OOM kill with a GET in its handler and an upload in flight"; ready; POD=$(srvpod); cap_on
sh_c "(curl -sS -o /dev/null -H 'Expect:' --limit-rate 1M --data-binary @/tmp/body 'http://$SVC:8080/upload' > /tmp/o.curl 2>&1; echo upload curl exit=\$? >> /tmp/o.curl) & (curl -sS -o /dev/null 'http://$SVC:8080/oom' > /tmp/o.oom 2>&1; echo oom curl exit=\$? >> /tmp/o.oom) & sleep 0" </dev/null >/dev/null 2>&1 &
sleep 8
for f in curl oom; do echo "--- client $f"; sh_c "cat /tmp/o.$f"; done
sh_c 'pkill curl'
echo "--- client capture"; cap_off
say kubectl -n rst get "$POD" -o jsonpath lastState; kubectl -n rst get "$POD" -o jsonpath='{range .status.containerStatuses[?(@.name=="srv")]}{.restartCount} {.lastState.terminated.reason} {.lastState.terminated.exitCode}{"\n"}{end}'
} > "$R/07d-oomkilled.txt" 2>&1
kubectl -n rst rollout restart deploy/srv >/dev/null

# 08 closing with unread bytes, nothing dies
{
echo "# 08: server answers 413 on the headers and closes without reading the body"; ready; cap_on
say curl -sS -H 'Expect:' -w '%{http_code}\n' --data-binary @/tmp/body http://$SVC:8081/reject; c curl -sS -H 'Expect:' -w '%{http_code}\n' --data-binary @/tmp/body http://$SVC:8081/reject
c python3 /app/py_client.py upload http://$SVC:8081/reject 8
c /app/rstclient one -X POST -mb 8 http://$SVC:8081/reject
c node /app/node_client.js upload http://$SVC:8081/reject 8
echo "--- client capture"; cap_off | head -60
} > "$R/08-close-unread.txt" 2>&1

# 09 a reset from the middle: the server never sent it
{
echo "# 09: a rule on the client's node rejects with tcp-reset. Capture at both ends"; ready
NODE=$(kubectl -n rst get pod client -o jsonpath='{.spec.nodeName}'); kubectl -n rst get pods -o wide
cap_on
docker exec "$NODE" iptables -I FORWARD -s "$CLIENT_IP" -p tcp --dport 8080 --tcp-flags PSH PSH -j REJECT --reject-with tcp-reset
say curl -sS http://$SVC:8080/ok; c curl -sS http://$SVC:8080/ok
c python3 /app/py_client.py get http://$SVC:8080/ok
c /app/rstclient one http://$SVC:8080/ok
docker exec "$NODE" iptables -D FORWARD -s "$CLIENT_IP" -p tcp --dport 8080 --tcp-flags PSH PSH -j REJECT --reject-with tcp-reset
echo "--- client capture (note ttl)"; cap_off
echo "--- server capture"; srv_cap 20s | tail -30
} > "$R/09-middlebox.txt" 2>&1

# 10 ssh
{
echo "# 10: sshd with MaxStartups=1:100:1. One unauthenticated connection holds the only slot"
SSHIP=$(kubectl -n rst get pod sshbox -o jsonpath='{.status.podIP}'); cap_on
sh_c "(sleep 20 | nc $SSHIP 2222 >/dev/null 2>&1) & sleep 0" </dev/null >/dev/null 2>&1 &
sleep 2
for i in 1 2 3; do
say ssh -o StrictHostKeyChecking=no -o BatchMode=yes -p 2222 root@$SSHIP true; c ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o UserKnownHostsFile=/dev/null -p 2222 root@$SSHIP true
done
echo "--- client capture"; cap_off
kubectl -n rst logs sshbox --tail=10
} > "$R/10-ssh.txt" 2>&1
kubectl -n rst get pods -o wide > "$R/99-final-pods.txt" 2>&1
echo repro done
