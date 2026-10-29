#!/usr/bin/env bash
# Confirm, Scope and Isolate commands from the runbook, in order, with output.
#   KUBECONFIG=.kubeconfig-<cluster> bash scenarios/20-*/diagnose.sh <ctx> <outdir>
set -uo pipefail
CTX="${1:?kube context}"; OUT="${2:?output dir}"; mkdir -p "$OUT"
run() { local a=("$@"); [[ $1 == k ]] && a[0]=kubectl; echo "\$ ${a[*]}"; "$@" 2>&1; echo; }
k() { kubectl --context "$CTX" "$@"; }
FE="$(k -n shop get pods -l app=frontend -o name | head -1)"
API_IP="$(k -n shop get pods -l app=api -o jsonpath='{.items[0].status.podIP}')"
{
  echo "# $(date -u +%FT%TZ) context $CTX"
  # Confirm: what the client sees, then what nginx says about each 502
  run k -n shop logs deploy/loadgen --tail=5
  run k -n shop logs "$FE" --tail=6
  echo "\$ kubectl -n shop logs -l app=frontend --tail=500 | grep -oE '\[(error|crit|warn)\] .*while [a-z ]+ upstream' | sed -E 's/[0-9]+#[0-9]+: \*[0-9]+ //' | sort | uniq -c"
  k -n shop logs -l app=frontend --tail=500 | grep -oE '\[(error|crit|warn)\] .*while [a-z ]+ upstream' | sed -E 's/[0-9]+#[0-9]+: \*[0-9]+ //' | sort | uniq -c; echo
  # Scope: pods, endpoints, Service
  run k -n shop get pods -o wide
  run k -n shop get endpointslices -l kubernetes.io/service-name=api
  run k -n shop get svc api -o wide
  # Isolate: ask the upstream directly, skipping nginx, then skipping the Service
  run k -n shop exec "$FE" -c nginx -- curl -sS -o /dev/null -w '%{http_code}\n' --max-time 3 http://api:8080/healthz
  run k -n shop exec "$FE" -c nginx -- curl -sS -v --max-time 3 http://api:8080/items
  run k -n shop exec "$FE" -c nginx -- curl -sS -v --max-time 3 "http://$API_IP:8080/items"
  run k -n shop logs -l app=api --tail=16
  # Since when, and after which change
  run k -n shop get rs -l app=api -o wide
  run k -n shop rollout history deploy/api
  echo "\$ kubectl -n shop get cm api-code -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.time}{\"\\n\"}{end}'"
  k -n shop get cm api-code -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.time}{"\n"}{end}'; echo
  run k -n shop get deploy api -o jsonpath='{.spec.template.spec.containers[0].env}'
  echo
  # What changed against the manifest in source control (server-side dry run, read-only)
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  run k diff -f "$ROOT/app/shop.yaml"
  echo
} > "$OUT/diagnose.txt"
