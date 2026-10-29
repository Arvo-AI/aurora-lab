#!/usr/bin/env bash
# Reproduce each nginx 502 cause once and print the status code and the
# error.log line it produced. Needs the lab cluster (./lab.sh up, ./lab.sh reset:
# the /redis/ case proxies to the shop namespace's redis).
#   KUBECONFIG=.kubeconfig-<cluster> bash scenarios/20-*/causes/run.sh <ctx> [outdir]
set -euo pipefail
CTX="${1:?kube context}"; OUT="${2:-/dev/stdout}"
HERE="$(cd "$(dirname "$0")" && pwd)"
k() { kubectl --context "$CTX" "$@"; }

k apply -f "$HERE/causes.yaml" >/dev/null
k -n r502x create configmap backend-code --from-file="$HERE/backend.py" --dry-run=client -o yaml | k apply -f - >/dev/null
if ! k -n r502x get secret backend-tls >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$tmp/tls.key" -out "$tmp/tls.crt" -days 30 -subj "/CN=backend" 2>/dev/null
  k -n r502x create secret tls backend-tls --cert="$tmp/tls.crt" --key="$tmp/tls.key" >/dev/null
  rm -rf "$tmp"
fi
k -n r502x rollout status deploy/backend --timeout=180s >/dev/null
k -n r502x rollout status deploy/fenced --timeout=180s >/dev/null
# nginx resolves upstream names at start, so start it only once the names exist
k -n r502x rollout restart deploy/proxy >/dev/null
k -n r502x rollout status deploy/proxy --timeout=120s >/dev/null
sleep 5
P="$(k -n r502x get pods -l app=proxy --sort-by=.metadata.creationTimestamp -o name | tail -1)"

probe() {
  local path="$1" since
  since="$(date -u +%FT%TZ)"
  code="$(k -n r502x exec "$P" -- curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://localhost$path" || true)"
  sleep 1
  echo "### GET $path -> $code"
  k -n r502x logs "$P" --since-time="$since" | grep -E '\[(emerg|alert|crit|error|warn|notice|info)\]' || true
  echo
}

{
  echo "# $(date -u +%FT%TZ) context $CTX"
  k -n r502x exec "$P" -- nginx -v 2>&1
  for p in /ok/ /noep/ /nolistener/ /unexposed/ /fenced/ /pair/ /pair/ /close/ /reset/ /bighdr/ \
           /plain-to-tls/ /tls-to-plain/ /slow/ /redis/ /noresolver/ /shortname/ /fqdn/ /typo/ /headless/ /headless-resolve/; do
    probe "$p"
  done
  echo "### stale headless IPs: restart backend pods, nginx keeps the IPs it resolved at start"
  k -n r502x get endpointslices -l kubernetes.io/service-name=backend-headless -o jsonpath='{.items[*].endpoints[*].addresses[*]}'; echo
  k -n r502x rollout restart deploy/backend >/dev/null
  k -n r502x rollout status deploy/backend --timeout=180s >/dev/null
  sleep 45
  k -n r502x get endpointslices -l kubernetes.io/service-name=backend-headless -o jsonpath='{.items[*].endpoints[*].addresses[*]}'; echo
  probe /headless/
  probe /headless/
  probe /headless-resolve/
  echo "### startup check with an upstream name that does not resolve"
  k -n r502x exec "$P" -- sh -c 'sed "s/server noep:8080;/server noep-typo:8080;/" /etc/nginx/conf.d/default.conf > /tmp/bad.conf && printf "events {}\nhttp { include /tmp/bad.conf; }\n" > /tmp/nginx.conf && nginx -t -c /tmp/nginx.conf' 2>&1 || true
} > "$OUT"
