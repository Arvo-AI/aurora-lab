#!/usr/bin/env bash
# Runs after break.sh. Captures the scenario's fault, the fix, then each other
# way to get a 503 from nginx, and how to tell them apart. Writes to $OUT.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:?}"
ING=http://ingress-nginx-controller.ingress-nginx.svc
ctrl() { kubectl -n ingress-nginx logs deploy/ingress-nginx-controller "$@"; }
cx() { kubectl -n r503 exec curl -- "$@"; }
run() { echo "\$ $*"; eval "$*" 2>&1; echo; }

# ---------- 1. the scenario's fault, as it stands after break.sh
{
  echo "# $(date -u +%FT%TZ) fault state"
  kubectl apply -f "$HERE/causes/causes.yaml" >/dev/null 2>"$OUT/causes-apply.err"
  kubectl -n r503 create configmap backend-code --from-file="$HERE/causes/backend.py" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n r503 wait --for=condition=Ready pod/curl --timeout=120s >/dev/null
  run 'kubectl -n r503 exec curl -- curl -si http://ingress-nginx-controller.ingress-nginx.svc/items'
  run 'kubectl -n r503 exec curl -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://ingress-nginx-controller.ingress-nginx.svc/items'
  sleep 2
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=400 | grep -E 'GET /items' | tail -3"
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=400 | grep 'active Endpoint' | tail -3"
  run 'kubectl -n shop get pods -l app=api -o wide'
  run 'kubectl -n shop get endpointslices -l kubernetes.io/service-name=api'
  run 'kubectl -n shop get endpointslices -l kubernetes.io/service-name=api -o yaml | grep -E "ready|serving|terminating|addresses|- 10\."'
  run "kubectl -n shop describe pod -l app=api | grep -E 'Readiness|Warning' | sort | uniq -c | tail -6"
  run 'kubectl -n shop get events --field-selector reason=Unhealthy --sort-by=.lastTimestamp | tail -3'
  run 'kubectl -n shop logs deploy/loadgen --tail=4'
  run "kubectl -n shop logs -l app=frontend --tail=100 --prefix | grep -v healthz | tail -4"
  run 'kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /dbg backends get shop-api-8080'
  API_IP="$(kubectl -n shop get pods -l app=api -o jsonpath='{.items[0].status.podIP}')"
  run "kubectl -n r503 exec curl -- curl -si --max-time 5 http://$API_IP:8080/items"
  run "kubectl -n r503 exec curl -- curl -si --max-time 5 http://$API_IP:8080/healthz"
} > "$OUT/01-fault.txt" 2>&1

# ---------- 2. restore redis: how fast does it heal, then what the same outage
# looks like when readiness does not depend on redis
{
  echo "# $(date -u +%FT%TZ) restore redis"
  run 'kubectl -n shop scale deploy/redis --replicas=1'
  run 'kubectl -n shop rollout status deploy/redis --timeout=120s'
  t0=$(date +%s)
  until [ "$(kubectl -n r503 exec curl -- curl -s -o /dev/null -w '%{http_code}' $ING/items)" = 200 ]; do sleep 1; done
  echo "ingress returned 200 $(( $(date +%s) - t0 ))s after redis was Available"
  run 'kubectl -n shop get endpointslices -l kubernetes.io/service-name=api'
  run "kubectl -n shop patch deploy api --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/readinessProbe/httpGet/path\",\"value\":\"/healthz\"}]'"
  run 'kubectl -n shop rollout status deploy/api --timeout=120s'
  echo "# $(date -u +%FT%TZ) same redis outage, readiness on /healthz"
  run 'kubectl -n shop scale deploy/redis --replicas=0'
  sleep 25
  run 'kubectl -n shop get pods -l app=api'
  run 'kubectl -n shop get endpointslices -l kubernetes.io/service-name=api'
  run 'kubectl -n r503 exec curl -- curl -si http://ingress-nginx-controller.ingress-nginx.svc/items'
  run 'kubectl -n r503 exec curl -- curl -s -o /dev/null -w "%{http_code} %{time_total}s\n" http://ingress-nginx-controller.ingress-nginx.svc/items'
  run 'kubectl -n shop exec deploy/loadgen -- wget -S -O - -T 5 http://frontend/api/items'
  sleep 2
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=400 | grep -E 'GET /items' | tail -3"
  run 'kubectl -n shop logs -l app=api --tail=3 --prefix'
  run 'kubectl -n shop logs deploy/loadgen --tail=3'
  echo "# $(date -u +%FT%TZ) fix verified: redis back, readiness on /healthz"
  run 'kubectl -n shop scale deploy/redis --replicas=1'
  run 'kubectl -n shop rollout status deploy/redis --timeout=120s'
  sleep 40
  run 'kubectl -n shop logs deploy/loadgen --tail=5'
  run 'kubectl -n r503 exec curl -- sh -c "for i in 1 2 3 4 5 6 7 8 9 10; do curl -s -o /dev/null -w \"%{http_code}\n\" http://ingress-nginx-controller.ingress-nginx.svc/items; done | sort | uniq -c"'
} > "$OUT/02-fix.txt" 2>&1

kubectl -n r503 rollout status deploy/backend --timeout=180s >/dev/null 2>&1
for d in errors mixgood mixbad faila failb inner stock; do kubectl -n r503 rollout status deploy/$d --timeout=180s >/dev/null 2>&1; done
sleep 8

# probe <path>: one request; headers, body, time, then the controller's log lines
probe() {
  local p="$1" since; since="$(date -u +%FT%TZ)"
  echo "### GET $p"
  cx curl -s -D - -o /tmp/body -w 'time_total=%{time_total}\n' --max-time 20 "$ING$p"
  cx cat /tmp/body; echo
  sleep 2
  echo "--- controller log"
  ctrl --since-time="$since" | grep -E " $p|$p |active Endpoint|Error obtaining|does not have|not found" | grep -v -E 'healthz|leaderelection' | tail -8
  echo
}

# ---------- 3. no upstream, in each form; what masks it
{
  echo "# $(date -u +%FT%TZ) no-endpoint variants through ingress-nginx"
  cat "$OUT/causes-apply.err"
  run 'kubectl -n r503 get svc,endpointslices,ingress'
  run 'kubectl -n r503 get pods -o wide'
  for p in /app/ok /scaled /badselector /notready /missing /wrongport /svcup /dflt; do probe "$p"; done
  run 'kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /dbg backends list'
  run "kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /dbg conf | grep -n -E 'server_tokens|more_clear_headers|limit_req_status|limit_conn_status|proxy_next_upstream ' | sort -t: -k2 -u | head -12"
} > "$OUT/03-no-endpoint-variants.txt" 2>&1

burst() { # burst <url> [extra curl args]: 30 requests, 10 at a time; prints status counts
  local u="$1"; shift
  cx sh -c "seq 1 30 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' $* '$u' | sort | uniq -c"
}

# ---------- 4. rate limits
{
  echo "# $(date -u +%FT%TZ) limit_req on a healthy backend, ingress-nginx"
  run "kubectl -n r503 get ingress limited -o jsonpath='{.metadata.annotations}'"
  run 'kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /dbg conf | grep -n -E "limit_req |limit_req_zone|limit_conn " | head -12'
  echo "\$ 30 requests, 10 at a time, GET /limited/ok"; burst "$ING/limited/ok"
  sleep 2
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=300 | grep -E 'limiting requests' | tail -3"
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=300 | grep -E 'GET /limited/ok' | grep ' 503 ' | tail -3"
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=300 | grep -E 'GET /limited/ok' | grep ' 200 ' | tail -2"
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=300 | grep -c 'limiting requests'"
  run "kubectl -n r503 logs -l app=backend --tail=500 | grep -c 'GET /limited'"
  sleep 12
  # one rejected body against one no-endpoint body
  cx sh -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do curl -si $ING/limited/ok -o /tmp/l.\$i & done; wait; grep -l ' 503 ' /tmp/l.* | head -1 | xargs -I{} cp {} /tmp/limit.resp"
  cx curl -si $ING/scaled -o /tmp/noep.resp
  echo "\$ curl -si (limit_req rejection)"; cx cat /tmp/limit.resp; echo
  echo "\$ curl -si (Service with no endpoints)"; cx cat /tmp/noep.resp; echo
  echo "\$ cmp, bodies and headers, Date line removed"
  cx sh -c "grep -v -E '^Date' /tmp/limit.resp > /tmp/a; grep -v -E '^Date' /tmp/noep.resp > /tmp/b; cmp /tmp/a /tmp/b && echo identical; md5sum /tmp/a /tmp/b"
  echo

  echo "# $(date -u +%FT%TZ) X-Forwarded-For does not move the limit key by default"
  sleep 10
  cx sh -c "seq 1 30 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Forwarded-For: 198.51.100.{}' $ING/limited/ok | sort | uniq -c"
  echo
  echo "# $(date -u +%FT%TZ) use-forwarded-headers true in the controller ConfigMap"
  run "kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge -p '{\"data\":{\"use-forwarded-headers\":\"true\"}}'"
  sleep 15
  cx sh -c "seq 1 30 | xargs -P 10 -I{} curl -s -o /dev/null -w '%{http_code}\n' -H 'X-Forwarded-For: 198.51.100.{}' $ING/limited/ok | sort | uniq -c"
  echo
  run "kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=json -p '[{\"op\":\"remove\",\"path\":\"/data/use-forwarded-headers\"}]'"
  sleep 15

  echo "# $(date -u +%FT%TZ) limit-req-status-code 429"
  run "kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=merge -p '{\"data\":{\"limit-req-status-code\":\"429\"}}'"
  sleep 15
  echo "\$ 30 requests, 10 at a time, GET /limited/ok"; burst "$ING/limited/ok"
  run 'kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /dbg conf | grep -E "limit_req_status" | sort | uniq -c'
  sleep 8
  cx sh -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do curl -si $ING/limited/ok -o /tmp/m.\$i & done; wait; grep -l ' 429 ' /tmp/m.* | head -1 | xargs cat"
  echo
  run "kubectl -n ingress-nginx patch configmap ingress-nginx-controller --type=json -p '[{\"op\":\"remove\",\"path\":\"/data/limit-req-status-code\"}]'"
  sleep 15

  echo "# $(date -u +%FT%TZ) limit-whitelist with the client's IP"
  IP="$(kubectl -n r503 get pod curl -o jsonpath='{.status.podIP}')"
  run "kubectl -n r503 annotate ingress limited nginx.ingress.kubernetes.io/limit-whitelist=$IP/32 --overwrite"
  sleep 8
  echo "\$ 30 requests, 10 at a time, GET /limited/ok"; burst "$ING/limited/ok"
  run 'kubectl -n r503 annotate ingress limited nginx.ingress.kubernetes.io/limit-whitelist-'
  sleep 8

  echo "# $(date -u +%FT%TZ) limit-connections 2, six slow requests at once"
  cx sh -c "seq 1 6 | xargs -P 6 -I{} curl -s -o /dev/null -w '%{http_code}\n' $ING/connlim/sleep/2 | sort | uniq -c"
  sleep 2
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=100 | grep -E 'limiting connections' | tail -2"
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=100 | grep -E 'GET /connlim' | tail -6"
} > "$OUT/04-rate-limit.txt" 2>&1

# ---------- 5. an upstream's own 503 through ingress-nginx
{
  echo "# $(date -u +%FT%TZ) upstream 503 through ingress-nginx"
  probe /app/fail503
  run 'kubectl -n r503 exec curl -- curl -si http://backend:8080/app/fail503'
  echo "# an nginx behind the controller answering 503 itself, server_tokens off"
  probe /nginxup
  cx curl -si "$ING/nginxup" -o /tmp/inner.resp
  cx curl -si "$ING/scaled" -o /tmp/noep.resp
  echo "\$ cmp, headers and body, Date line removed"
  cx sh -c "grep -v -E '^Date' /tmp/inner.resp > /tmp/a; grep -v -E '^Date' /tmp/noep.resp > /tmp/b; cmp /tmp/a /tmp/b && echo identical; md5sum /tmp/a /tmp/b"
  echo
  echo "# custom-http-errors: 503 with default-backend: errors"
  probe /masked/fail503
  echo "# default: an upstream 503 is not retried"
  cx sh -c "seq 1 20 | xargs -P 1 -I{} curl -s -o /dev/null -w '%{http_code}\n' $ING/noretry/x | sort | uniq -c"
  sleep 2
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=100 | grep 'GET /noretry/x' | tail -3"
  echo "# proxy-next-upstream: error timeout http_503"
  run "kubectl -n r503 get ingress retry -o jsonpath='{.metadata.annotations}'"
  cx sh -c "seq 1 20 | xargs -P 1 -I{} curl -s -o /dev/null -w '%{http_code}\n' $ING/retry/x | sort | uniq -c"
  sleep 2
  run "kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=100 | grep 'GET /retry/x' | tail -4"
  echo "\$ retry access log lines with two upstream attempts"
  ctrl --tail=100 | grep 'GET /retry/x' | grep -c '503, 200'
} > "$OUT/05-upstream-503.txt" 2>&1

# ---------- 6. stock nginx matrix
ST="$(kubectl -n r503 get pod -l app=stock -o name | head -1)"
SIP="$(kubectl -n r503 get pod -l app=stock -o jsonpath='{.items[0].status.podIP}')"
sp() {
  local p="$1" since; since="$(date -u +%FT%TZ)"
  echo "### GET $p"
  cx curl -s -D - -o /tmp/body -w 'time_total=%{time_total}\n' --max-time 20 "http://$SIP$p"
  cx cat /tmp/body; echo
  sleep 1
  echo "--- nginx log"; kubectl -n r503 logs "$ST" --since-time="$since" | grep -E "$p" | tail -5
  echo
}
sburst() { cx sh -c "seq 1 ${2:-12} | xargs -P ${3:-12} -I{} curl -s -o /dev/null -w '%{http_code}\n' http://$SIP$1 | sort | uniq -c"; }
{
  echo "# $(date -u +%FT%TZ) stock nginx"
  kubectl -n r503 exec "$ST" -- nginx -v
  run "kubectl -n r503 get cm stock-conf -o jsonpath='{.data.default\.conf}'"
  for p in /ok /refused /alldown /maint /app503 /app503-server /intercept /pair /pair; do sp "$p"; done
  echo "### /maxconns, 3 at once"; sburst /maxconns 3 3; sleep 1; kubectl -n r503 logs "$ST" --tail=8 | grep maxconns
  echo "### /limit, 12 at once"; sburst /limit; sleep 1; kubectl -n r503 logs "$ST" --tail=14 | grep -E '/limit' | tail -4
  echo "### /dry, 12 at once (limit_req_dry_run on)"; sburst /dry; sleep 1; kubectl -n r503 logs "$ST" --tail=14 | grep -E '/dry' | tail -4
  echo "### /four29, 12 at once"; sburst /four29; sleep 1
  echo "### /conn, 3 at once"; sburst /conn 3 3; sleep 1; kubectl -n r503 logs "$ST" --tail=8 | grep -E '/conn' | tail -4
} > "$OUT/06-stock-nginx.txt" 2>&1

{
  echo "# versions"
  kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- /nginx-ingress-controller --version
  kubectl -n r503 exec "$ST" -- nginx -v
  kubectl -n r503 exec deploy/backend -- python --version
  cx curl --version | head -1
  kubectl get nodes -o wide
  helm version --short
} > "$OUT/07-versions.txt" 2>&1

# ---------- 8. the same faults on other controllers
bash "$HERE/causes/others.sh" > "$OUT/08-other-controllers.txt" 2>&1 || true
