#!/usr/bin/env bash
# Captures "context deadline exceeded" from each caller that can raise it. Every
# section writes to $OUT and tolerates failure so one section cannot lose the rest.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$OUT"
log() { printf '\n$ %s\n' "$*"; }
run() { log "$*"; "$@" 2>&1; echo "[exit $?]"; }
timed() { # timed <cmd...>: prints elapsed seconds
  local s e rc; log "$*"; s=$(date +%s.%N); "$@" 2>&1; rc=$?; e=$(date +%s.%N)
  printf '[exit %s, elapsed %.2fs]\n' "$rc" "$(echo "$e - $s" | bc)"
}
ns=deadline

section_scenario() { # the injected fault
  run kubectl -n shop get pods -l app=api
  run kubectl -n shop rollout status deploy/api --timeout=5s
  run kubectl -n shop get events --field-selector reason=Unhealthy
  p=$(kubectl -n shop get pods -l app=api --sort-by=.metadata.creationTimestamp -o name | tail -1)
  run kubectl -n shop describe "$p"
  run kubectl -n shop exec deploy/loadgen -- sh -c 'wget -q -O - -T 5 http://frontend/api/items; echo'
  # Reach the same path from next to the app, without the kubelet.
  ip=$(kubectl -n shop get "$p" -o jsonpath='{.status.podIP}')
  run kubectl -n shop exec deploy/loadgen -- sh -c "time wget -q -O - -T 20 http://$ip:8080/healthz; echo"
  run kubectl -n shop exec deploy/loadgen -- sh -c "time wget -q -O - -T 5 http://$ip:8080/items; echo"
  run kubectl -n shop get deploy api -o jsonpath='{.spec.template.spec.containers[0].livenessProbe}{"\n"}{.spec.template.spec.containers[0].readinessProbe}{"\n"}'
}

section_probes() {
  kubectl create ns $ns
  kubectl -n $ns apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: srv}
data:
  srv.py: |
    import hashlib, os, re, time
    from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            m = re.match(r"/sleep/([0-9.]+)", self.path)
            if m:
                time.sleep(float(m.group(1)))
            elif self.path == "/cpu":      # about 150 ms of pure CPU on an idle core
                x = b"x"
                t = time.process_time()
                while time.process_time() - t < 0.15:
                    x = hashlib.sha256(x).digest()
            b = b"ok\n"
            self.send_response(200); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
        def log_message(self, *a): pass
    ThreadingHTTPServer(("", 8080), H).serve_forever()
---
apiVersion: v1
kind: Pod
metadata: {name: http-slow-1s5, labels: {t: probe}}
spec:
  volumes: [{name: c, configMap: {name: srv}}]
  containers:
  - {name: app, image: python:3.12-alpine, command: [python, /c/srv.py], volumeMounts: [{name: c, mountPath: /c}],
     readinessProbe: {httpGet: {path: /sleep/1.5, port: 8080}, periodSeconds: 3}}
---
apiVersion: v1
kind: Pod
metadata: {name: http-slow-1s5-timeout3, labels: {t: probe}}
spec:
  volumes: [{name: c, configMap: {name: srv}}]
  containers:
  - {name: app, image: python:3.12-alpine, command: [python, /c/srv.py], volumeMounts: [{name: c, mountPath: /c}],
     readinessProbe: {httpGet: {path: /sleep/1.5, port: 8080}, periodSeconds: 5, timeoutSeconds: 3}}
---
apiVersion: v1
kind: Pod
metadata: {name: http-hung-timeout10, labels: {t: probe}}
spec:
  volumes: [{name: c, configMap: {name: srv}}]
  containers:
  - {name: app, image: python:3.12-alpine, command: [python, /c/srv.py], volumeMounts: [{name: c, mountPath: /c}],
     readinessProbe: {httpGet: {path: /sleep/600, port: 8080}, periodSeconds: 12, timeoutSeconds: 10}}
---
apiVersion: v1
kind: Pod
metadata: {name: http-dropped-host, labels: {t: probe}}
spec:
  containers:
  - {name: app, image: busybox:1.37, command: [sleep, "3600"],
     readinessProbe: {httpGet: {host: 192.0.2.10, path: /, port: 8080}, periodSeconds: 3}}
---
apiVersion: v1
kind: Pod
metadata: {name: tcp-dropped-host, labels: {t: probe}}
spec:
  containers:
  - {name: app, image: busybox:1.37, command: [sleep, "3600"],
     readinessProbe: {tcpSocket: {host: 192.0.2.10, port: 8080}, periodSeconds: 3}}
---
apiVersion: v1
kind: Pod
metadata: {name: exec-slow, labels: {t: probe}}
spec:
  containers:
  - {name: app, image: busybox:1.37, command: [sleep, "3600"],
     readinessProbe: {exec: {command: [sleep, "5"]}, periodSeconds: 3}}
---
apiVersion: v1
kind: Pod
metadata: {name: grpc-silent, labels: {t: probe}}
spec:
  containers:
  - {name: app, image: busybox:1.37, command: [nc, -lk, -p, "9000", -e, /bin/sleep, "600"],
     readinessProbe: {grpc: {port: 9000}, periodSeconds: 3}}
---
apiVersion: v1
kind: Pod
metadata: {name: liveness-slow, labels: {t: probe}}
spec:
  volumes: [{name: c, configMap: {name: srv}}]
  containers:
  - {name: app, image: python:3.12-alpine, command: [python, /c/srv.py], volumeMounts: [{name: c, mountPath: /c}],
     livenessProbe: {httpGet: {path: /sleep/1.5, port: 8080}, periodSeconds: 3}}
---
apiVersion: v1
kind: Pod
metadata: {name: cpu-throttled, labels: {t: probe}}
spec:
  volumes: [{name: c, configMap: {name: srv}}]
  containers:
  - {name: app, image: python:3.12-alpine, command: [python, /c/srv.py], volumeMounts: [{name: c, mountPath: /c}],
     resources: {limits: {cpu: 20m, memory: 64Mi}},
     readinessProbe: {httpGet: {path: /cpu, port: 8080}, periodSeconds: 3, initialDelaySeconds: 10}}
---
apiVersion: v1
kind: Pod
metadata: {name: cpu-unthrottled, labels: {t: probe}}
spec:
  volumes: [{name: c, configMap: {name: srv}}]
  containers:
  - {name: app, image: python:3.12-alpine, command: [python, /c/srv.py], volumeMounts: [{name: c, mountPath: /c}],
     resources: {limits: {cpu: 500m, memory: 64Mi}},
     readinessProbe: {httpGet: {path: /cpu, port: 8080}, periodSeconds: 3, initialDelaySeconds: 10}}
---
apiVersion: v1
kind: Pod
metadata: {name: client, labels: {t: client}}
spec:
  containers:
  - {name: app, image: curlimages/curl:8.11.1, command: [sleep, "36000"]}
EOF
  kubectl -n $ns wait --for=condition=PodScheduled pod --all --timeout=60s
  kubectl -n $ns wait --for=condition=Ready pod/client --timeout=120s
  sleep 75
  run kubectl -n $ns get pods -o wide
  run kubectl -n $ns get events --field-selector reason=Unhealthy
  run kubectl -n $ns get events --field-selector reason=Killing
  run kubectl -n $ns describe pod http-slow-1s5
  ip=$(kubectl -n $ns get pod http-slow-1s5 -o jsonpath='{.status.podIP}')
  fast=$(kubectl -n $ns get pod http-slow-1s5 -o jsonpath='{.status.podIP}')
  run kubectl -n $ns exec client -- curl -s -o /dev/null -w 'http=%{http_code} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n' "http://$ip:8080/sleep/1.5"
  ip=$(kubectl -n $ns get pod http-hung-timeout10 -o jsonpath='{.status.podIP}')
  run kubectl -n $ns exec client -- curl -s -m 20 -o /dev/null -w 'http=%{http_code} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n' "http://$ip:8080/sleep/600"
  run kubectl -n $ns exec client -- curl -s -m 5 -o /dev/null -w 'http=%{http_code} connect=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n' "http://192.0.2.10:8080/"
  # CPU throttling: same handler, different limit. Ten sequential timings of each.
  for p in cpu-throttled cpu-unthrottled; do
    ip=$(kubectl -n $ns get pod $p -o jsonpath='{.status.podIP}')
    log "ten requests to $p /cpu"
    for i in 1 2 3 4 5 6 7 8 9 10; do kubectl -n $ns exec client -- curl -s -m 30 -o /dev/null -w '%{http_code} %{time_total}\n' "http://$ip:8080/cpu"; done
    run kubectl -n $ns exec $p -- cat /sys/fs/cgroup/cpu.stat
    run kubectl -n $ns exec $p -- cat /sys/fs/cgroup/cpu.max
  done
  run kubectl top pod -n $ns --containers
  run kubectl -n $ns get pod -o custom-columns=NAME:.metadata.name,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount
  # What the kubelet logs for the same failure, one node.
  node=$(kubectl -n $ns get pod http-slow-1s5 -o jsonpath='{.spec.nodeName}')
  run docker exec "$node" sh -c "journalctl -u kubelet --no-pager | grep -E 'Probe failed|prober' | grep deadline | tail -5"
  run docker exec "$node" sh -c "grep -E 'runtimeRequestTimeout|imagePull|serializeImagePulls' /var/lib/kubelet/config.yaml; cat /var/lib/kubelet/config.yaml | head -60"
  kubectl delete ns $ns --wait=false
}

mk_webhook() { # mk_webhook <name> <rule-namespace-label> <timeoutSeconds|-> <failurePolicy> <service|url> <path>
  local name=$1 label=$2 to=$3 fp=$4 target=$5 path=$6 ts=""
  [ "$to" = - ] || ts="timeoutSeconds: $to"
  { cat <<EOF
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata: {name: $name}
webhooks:
- name: $name.deadline.lab
  admissionReviewVersions: [v1]
  sideEffects: None
  failurePolicy: $fp
  $ts
  namespaceSelector: {matchLabels: {hook: "$label"}}
  rules:
  - {apiGroups: [""], apiVersions: [v1], operations: [CREATE], resources: [configmaps, pods]}
  clientConfig:
    caBundle: $CA
EOF
    if [ "$target" = url ]; then echo "    url: $path"
    else printf '    service: {namespace: webhook, name: %s, port: 443, path: %s}\n' "$target" "$path"; fi
  } | kubectl apply -f -
}

section_webhook() {
  wd=$(mktemp -d); cd "$wd"
  openssl req -x509 -newkey rsa:2048 -nodes -days 2 -keyout tls.key -out tls.crt -subj "/CN=hook.webhook.svc" \
    -addext "subjectAltName=DNS:hook.webhook.svc,DNS:gone.webhook.svc,DNS:guarded.webhook.svc" 2>/dev/null
  CA=$(base64 -w0 tls.crt)
  kubectl create ns webhook
  kubectl -n webhook create secret tls hook-tls --cert=tls.crt --key=tls.key
  kubectl -n webhook create configmap hook --from-file=hook.py="$HERE/hook.py"
  kubectl -n webhook apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: hook}
spec:
  replicas: 1
  selector: {matchLabels: {app: hook}}
  template:
    metadata: {labels: {app: hook}}
    spec:
      volumes:
      - {name: c, configMap: {name: hook}}
      - {name: t, secret: {secretName: hook-tls}}
      containers:
      - {name: hook, image: python:3.12-alpine, command: [python, /c/hook.py], volumeMounts: [{name: c, mountPath: /c}, {name: t, mountPath: /t}]}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: guarded}
spec:
  replicas: 1
  selector: {matchLabels: {app: guarded}}
  template:
    metadata: {labels: {app: guarded}}
    spec:
      volumes:
      - {name: c, configMap: {name: hook}}
      - {name: t, secret: {secretName: hook-tls}}
      containers:
      - {name: hook, image: python:3.12-alpine, command: [python, /c/hook.py], volumeMounts: [{name: c, mountPath: /c}, {name: t, mountPath: /t}]}
---
apiVersion: v1
kind: Service
metadata: {name: hook}
spec: {selector: {app: hook}, ports: [{port: 443, targetPort: 8443}]}
---
apiVersion: v1
kind: Service
metadata: {name: guarded}
spec: {selector: {app: guarded}, ports: [{port: 443, targetPort: 8443}]}
---
apiVersion: v1
kind: Service
metadata: {name: gone}
spec: {selector: {app: nothing-matches}, ports: [{port: 443, targetPort: 8443}]}
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: guarded-pods-only}
spec:
  podSelector: {matchLabels: {app: guarded}}
  policyTypes: [Ingress]
  ingress:
  - from: [{podSelector: {}}]
---
apiVersion: v1
kind: Pod
metadata: {name: client, labels: {t: client}}
spec:
  containers:
  - {name: app, image: curlimages/curl:8.11.1, command: [sleep, "36000"]}
EOF
  kubectl -n webhook wait --for=condition=Available deploy --all --timeout=180s
  kubectl -n webhook wait --for=condition=Ready pod/client --timeout=120s
  for t in hang dead slow5 ignore netpol pods okfast; do kubectl create ns "wh-$t"; kubectl label ns "wh-$t" hook="$t"; done

  # 1. Hung backend, default timeout: accepts, TLS completes, never answers.
  mk_webhook hung hang - Fail hook /hang
  timed kubectl -n wh-hang create configmap a --from-literal=k=v
  # 2. Same, timeoutSeconds 3.
  mk_webhook hung hang 3 Fail hook /hang
  timed kubectl -n wh-hang create configmap b --from-literal=k=v
  # 3. Failure open: same hang, failurePolicy Ignore.
  mk_webhook hung-ignore ignore 3 Ignore hook /hang
  timed kubectl -n wh-ignore create configmap c --from-literal=k=v
  # 4. No endpoints: a different, instant message.
  mk_webhook noendpoints dead - Fail gone /allow
  timed kubectl -n wh-dead create configmap d --from-literal=k=v
  # 5. Timeout too low: backend always answers in 5 s; 3 then 8.
  mk_webhook slow slow5 3 Fail hook /sleep5
  timed kubectl -n wh-slow5 create configmap e --from-literal=k=v
  mk_webhook slow slow5 8 Fail hook /sleep5
  timed kubectl -n wh-slow5 create configmap f --from-literal=k=v
  # 6. Reachable from pods, not from the API server (NetworkPolicy).
  mk_webhook np netpol 3 Fail guarded /allow
  timed kubectl -n wh-netpol create configmap g --from-literal=k=v
  run kubectl -n webhook exec client -- curl -sk -m 5 -o /dev/null -w 'http=%{http_code} connect=%{time_connect} total=%{time_total}\n' -X POST -d '{"request":{"uid":"x"}}' https://guarded.webhook.svc/allow
  # 7. Controller as the caller: kubectl says created, no pod appears.
  mk_webhook podhook pods 3 Fail hook /hang
  kubectl -n wh-pods create deployment web --image=busybox:1.37 -- sleep 3600
  sleep 25
  run kubectl -n wh-pods get deploy,rs,pods
  rs=$(kubectl -n wh-pods get rs -o name | head -1)
  run kubectl -n wh-pods describe "$rs"
  # 8. Outside the cluster: URL webhook to an address that drops packets.
  kubectl delete ns wh-okfast
  kubectl create ns wh-okfast; kubectl label ns wh-okfast hook=okfast
  mk_webhook dropped okfast 3 Fail url https://192.0.2.10/validate
  timed kubectl -n wh-okfast create configmap h --from-literal=k=v
  # Server-side evidence.
  run kubectl get validatingwebhookconfiguration hung -o jsonpath='{.webhooks[0].timeoutSeconds}{"\n"}'
  log "kubectl get --raw /metrics | grep apiserver_admission_webhook_ (non-zero rejections + request totals)"
  kubectl get --raw /metrics | grep -E '^apiserver_admission_webhook_(rejection_count|request_total|fail_open_count)' | sort | head -40
  log "kubectl get --raw /metrics | grep admission_duration count/sum"
  kubectl get --raw /metrics | grep -E '^apiserver_admission_webhook_admission_duration_seconds_(sum|count)' | sort
  cp=$(kubectl get pods -n kube-system -l component=kube-apiserver -o name | head -1)
  log "kubectl -n kube-system logs $cp | grep -i webhook | tail -12"
  kubectl -n kube-system logs "$cp" | grep -iE 'webhook' | tail -12
  # Clean up: a hanging webhook must not outlive this section.
  kubectl delete validatingwebhookconfiguration hung hung-ignore noendpoints slow np podhook dropped
  kubectl delete ns wh-hang wh-dead wh-slow5 wh-ignore wh-netpol wh-pods wh-okfast webhook --wait=false
  cd "$HERE"
}

section_kubectl() {
  timed kubectl get pods -n shop --request-timeout=1ms
  # Dropped address: client side, real wait.
  cfg=$(mktemp); kubectl config view --raw > "$cfg"
  KUBECONFIG=$cfg kubectl config set-cluster "$(kubectl config view -o jsonpath='{.clusters[0].name}')" --server=https://192.0.2.10:6443 >/dev/null
  timed env KUBECONFIG=$cfg kubectl get pods --request-timeout=3s
  timed env KUBECONFIG=$cfg kubectl get pods --request-timeout=0 --v=0 --insecure-skip-tls-verify=false
  rm -f "$cfg"
  timed kubectl -n shop wait --for=condition=Available deploy/api --timeout=3s
}

section_etcd() {
  e=$(kubectl -n kube-system get pods -l component=etcd -o name | head -1)
  c=/etc/kubernetes/pki/etcd
  run kubectl -n kube-system exec "$e" -- etcdctl version
  # Wrong: no client certs. Short and default command timeouts.
  timed kubectl -n kube-system exec "$e" -- etcdctl --endpoints=https://127.0.0.1:2379 --command-timeout=2s endpoint health
  timed kubectl -n kube-system exec "$e" -- etcdctl --endpoints=https://127.0.0.1:2379 --dial-timeout=2s --command-timeout=2s get /x
  # Right: certs.
  timed kubectl -n kube-system exec "$e" -- etcdctl --endpoints=https://127.0.0.1:2379 --cacert=$c/ca.crt --cert=$c/server.crt --key=$c/server.key endpoint health
  timed kubectl -n kube-system exec "$e" -- etcdctl --endpoints=https://192.0.2.10:2379 --cacert=$c/ca.crt --cert=$c/server.crt --key=$c/server.key --dial-timeout=2s --command-timeout=3s endpoint health
}

section_prometheus() {
  docker network create dl >/dev/null
  docker run -d --name dl-tgt --network dl python:3.12-alpine python -c '
import re,time
from http.server import BaseHTTPRequestHandler as B, ThreadingHTTPServer as S
class H(B):
    def do_GET(self):
        m=re.match(r"/s/([0-9.]+)/metrics",self.path)
        if m: time.sleep(float(m.group(1)))
        b=b"lab_up 1\n"; self.send_response(200); self.send_header("Content-Length",str(len(b))); self.end_headers(); self.wfile.write(b)
    def log_message(self,*a): pass
S(("",9100),H).serve_forever()' >/dev/null
  mkdir -p /tmp/dlprom; cat > /tmp/dlprom/prometheus.yml <<'EOF'
global: {scrape_interval: 5s, scrape_timeout: 2s}
scrape_configs:
- {job_name: fast, metrics_path: /s/0.2/metrics, static_configs: [{targets: ["dl-tgt:9100"]}]}
- {job_name: over, metrics_path: /s/3/metrics, static_configs: [{targets: ["dl-tgt:9100"]}]}
- {job_name: over-raised, metrics_path: /s/3/metrics, scrape_timeout: 4s, static_configs: [{targets: ["dl-tgt:9100"]}]}
- {job_name: hung, metrics_path: /s/600/metrics, scrape_timeout: 4s, static_configs: [{targets: ["dl-tgt:9100"]}]}
- {job_name: dropped, static_configs: [{targets: ["192.0.2.10:9100"]}]}
EOF
  docker run -d --name dl-prom --network dl -p 19090:9090 -v /tmp/dlprom:/etc/prometheus prom/prometheus:v3.5.0 >/dev/null
  sleep 40
  run docker exec dl-prom prometheus --version
  log 'curl -s localhost:19090/api/v1/targets | jq ...'
  curl -s localhost:19090/api/v1/targets | jq -r '.data.activeTargets[] | [.labels.job, .health, .lastScrapeDuration, .scrapeTimeout, .lastError] | @tsv'
  log 'curl -s localhost:19090/api/v1/query --data-urlencode query=scrape_duration_seconds'
  curl -s localhost:19090/api/v1/query --data-urlencode 'query=scrape_duration_seconds' | jq -r '.data.result[] | [.metric.job, .value[1]] | @tsv'
  log 'curl -s localhost:19090/api/v1/query --data-urlencode query=up'
  curl -s localhost:19090/api/v1/query --data-urlencode 'query=up' | jq -r '.data.result[] | [.metric.job, .value[1]] | @tsv'
  docker rm -f dl-prom dl-tgt >/dev/null; docker network rm dl >/dev/null
}

section_docker() {
  docker version --format 'docker {{.Server.Version}}'
  # Dropped address.
  timed timeout 120 docker pull 192.0.2.10:5000/lab/app:1
  # Accepts TCP, says nothing.
  python3 "$HERE/silent.py" 15000 & sp=$!
  host_ip=$(hostname -I | awk '{print $1}')
  timed timeout 120 docker pull "$host_ip:15000/lab/app:1"
  kill $sp
}

section_image_pull() {
  # A registry that accepts and then says nothing, HTTP via hosts.toml, on the
  # Docker bridge so that nodes can reach it.
  docker rm -f dl-reg >/dev/null 2>&1
  docker run -d --name dl-reg --network kind -v "$HERE":/h:ro python:3.12-alpine python /h/silent.py 5000 >/dev/null
  reg=$(docker inspect dl-reg -f '{{(index .NetworkSettings.Networks "kind").IPAddress}}')
  # Stalls in the blob: answers /v2/ and the manifest, then hangs. Port 5001.
  docker rm -f dl-reg2 >/dev/null 2>&1
  docker run -d --name dl-reg2 --network kind -v "$HERE":/h:ro python:3.12-alpine python /h/stall_registry.py 5001 >/dev/null
  for n in $(kind get nodes --name aurora-lab); do
    for port in 5000 5001; do
      docker exec "$n" sh -c "mkdir -p /etc/containerd/certs.d/$reg:$port; printf 'server = \"http://$reg:$port\"\n[host.\"http://$reg:$port\"]\n  capabilities = [\"pull\",\"resolve\"]\n' > /etc/containerd/certs.d/$reg:$port/hosts.toml"
    done
  done
  n=$(kind get nodes --name aurora-lab | grep worker | head -1)
  run docker exec "$n" sh -c "containerd --version; grep -nE 'config_path|image_pull_progress_timeout|runtime_request' /etc/containerd/config.toml; containerd config dump | grep -E 'image_pull_progress_timeout|config_path'"
  kubectl create ns img
  kubectl -n img apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: pull-dropped}
spec:
  nodeName: $n
  containers: [{name: a, image: "192.0.2.10:5000/lab/app:1"}]
---
apiVersion: v1
kind: Pod
metadata: {name: pull-silent}
spec:
  nodeName: $n
  containers: [{name: a, image: "$reg:5000/lab/app:1"}]
---
apiVersion: v1
kind: Pod
metadata: {name: pull-stalled-blob}
spec:
  nodeName: $n
  containers: [{name: a, image: "$reg:5001/lab/app:1"}]
EOF
  date -u
  sleep 180
  run kubectl -n img get pods -o wide
  run kubectl -n img get events --sort-by=.lastTimestamp
  date -u
  sleep 240
  date -u
  run kubectl -n img get pods -o wide
  run kubectl -n img get events --sort-by=.lastTimestamp
  run docker exec "$n" sh -c "journalctl -u containerd --no-pager | grep -iE 'lab/app' | grep -iE 'cancel|deadline|timeout|fail' | tail -10"
  run docker logs --tail 20 dl-reg2
  timed docker exec "$n" crictl --timeout 5s pull "$reg:5000/lab/app:2"
  kubectl delete ns img --wait=false
  docker rm -f dl-reg dl-reg2 >/dev/null
}

section_helm() {
  run helm version --short
  d=$(mktemp -d); mkdir -p "$d/c/templates"
  printf 'apiVersion: v2\nname: lab\nversion: 0.1.0\n' > "$d/c/Chart.yaml"
  cat > "$d/c/templates/d.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata: {name: lab}
spec:
  selector: {matchLabels: {a: lab}}
  template:
    metadata: {labels: {a: lab}}
    spec:
      containers:
      - {name: a, image: busybox:1.37, command: [sleep, "3600"], readinessProbe: {exec: {command: ["false"]}, periodSeconds: 2}}
EOF
  kubectl create ns helmlab
  timed helm upgrade --install lab "$d/c" -n helmlab --wait --timeout 20s
  timed helm install lab2 "$d/c" -n helmlab --wait --timeout 20s --set x=1
  kubectl delete ns helmlab --wait=false
}

section_go() {
  run go version
  d=$(mktemp -d); cp "$HERE/repro-go/main.go" "$d/"; cd "$d"
  go mod init labdeadline >/dev/null 2>&1
  go get google.golang.org/grpc@v1.68.0 >/dev/null 2>&1
  go mod tidy >/dev/null 2>&1
  run go run .
  grep -E 'google.golang.org/grpc ' go.mod
  cd "$HERE"
}

for s in scenario probes webhook kubectl etcd prometheus docker helm go image_pull; do
  if [ -n "${ONLY:-}" ] && [[ " $ONLY " != *" $s "* ]]; then continue; fi
  echo "=== section $s"
  { echo "# $(date -u +%FT%TZ)"; section_$s; } > "$OUT/$s.txt" 2>&1
done
