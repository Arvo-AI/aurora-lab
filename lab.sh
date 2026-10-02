#!/usr/bin/env bash
# Aurora lab driver.
#
#   ./lab.sh up                      create the kind cluster
#   ./lab.sh reset                   restore the healthy shop app
#   ./lab.sh break <scenario>        reset, inject the fault, wait until it shows
#   ./lab.sh evidence <scenario> <dir>   capture cluster state into <dir>
#   ./lab.sh selftest [scenario...]  break each scenario and prove the fault appears
#   ./lab.sh down                    delete the cluster
#
# LAB_CLUSTER picks the kind cluster (default aurora-lab). Each cluster has its
# own kubeconfig: .kubeconfig for aurora-lab, .kubeconfig-<name> for others.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
CLUSTER="${LAB_CLUSTER:-aurora-lab}"
CTX="kind-$CLUSTER"
# The lab uses its own kubeconfig holding only the kind cluster, so no command
# here can ever reach another context on this machine.
if [[ "$CLUSTER" == aurora-lab ]]; then
  export KUBECONFIG="$ROOT/.kubeconfig"
else
  export KUBECONFIG="$ROOT/.kubeconfig-$CLUSTER"
fi
k() { kubectl --context "$CTX" "$@"; }

scenario_dir() {
  local d
  d="$(find "$ROOT/scenarios" -maxdepth 1 -type d -name "$1*" | head -1)"
  [[ -n "$d" ]] || { echo "unknown scenario: $1" >&2; exit 2; }
  echo "$d"
}

up() {
  kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --config "$ROOT/cluster/kind.yaml" --kubeconfig "$KUBECONFIG" --wait 180s
  kind get kubeconfig --name "$CLUSTER" > "$KUBECONFIG"
  metrics_server
  k get nodes
}

# metrics-server so that `kubectl top` works as on a real cluster. kind's
# kubelets use self-signed certs, hence --kubelet-insecure-tls.
metrics_server() {
  k apply -f "$ROOT/cluster/metrics-server.yaml" >/dev/null
  k -n kube-system wait --for=condition=Available deploy/metrics-server --timeout=180s >/dev/null
}

reset() {
  k delete namespace shop --ignore-not-found --wait=true >/dev/null
  k apply -f "$ROOT/app/shop.yaml" >/dev/null
  k -n shop wait --for=condition=Available deploy --all --timeout=240s >/dev/null
  # loadgen must see a healthy app before we break anything
  for _ in $(seq 1 30); do
    k -n shop logs deploy/loadgen --tail=1 2>/dev/null | grep -q -- '-> 200' && return 0
    sleep 2
  done
  echo "baseline never became healthy" >&2
  return 1
}

break_scenario() {
  local d; d="$(scenario_dir "$1")"
  reset
  (cd "$d" && bash -euo pipefail -c "source break.sh") >/dev/null
  local timeout="${BREAK_TIMEOUT:-240}" waited=0
  until (cd "$d" && bash -c "source check.sh"); do
    sleep 5; waited=$((waited + 5))
    if (( waited >= timeout )); then
      echo "FAIL $(basename "$d"): fault did not appear within ${timeout}s" >&2
      return 1
    fi
  done
  # let the failure settle into its steady state (backoffs, repeated events)
  sleep "${SETTLE:-45}"
  echo "broken $(basename "$d") after ${waited}s"
}

evidence() {
  local out="$2"; mkdir -p "$out"
  k version -o yaml > "$out/versions.yaml" 2>&1 || true
  kind version >> "$out/versions.yaml"
  k -n shop get all,pvc,endpointslices,cm,secrets,networkpolicy,resourcequota -o wide > "$out/get-all.txt" 2>&1
  k -n shop get events --sort-by=.lastTimestamp > "$out/events.txt" 2>&1
  k -n shop describe deploy > "$out/describe-deploy.txt" 2>&1
  k -n shop describe pods > "$out/describe-pods.txt" 2>&1
  k -n shop describe svc > "$out/describe-svc.txt" 2>&1
  k -n shop describe pvc > "$out/describe-pvc.txt" 2>&1 || true
  k -n shop get deploy,svc,cm,pvc -o yaml > "$out/manifests.yaml" 2>&1
  mkdir -p "$out/logs"
  for p in $(k -n shop get pods -o name); do
    for c in $(k -n shop get "$p" -o jsonpath='{.spec.containers[*].name}'); do
      n="${p#pod/}.$c"
      k -n shop logs "$p" -c "$c" --tail=200 > "$out/logs/$n.log" 2>&1 || true
      k -n shop logs "$p" -c "$c" --previous --tail=200 > "$out/logs/$n.previous.log" 2>&1 || rm -f "$out/logs/$n.previous.log"
    done
  done
}

selftest() {
  local ids=("$@") pass=0 fail=0
  if [[ ${#ids[@]} -eq 0 ]]; then
    while IFS= read -r d; do ids+=("$(basename "$d")"); done < <(find "$ROOT/scenarios" -mindepth 1 -maxdepth 1 -type d | sort)
  fi
  local out="$ROOT/runs/selftest-$(date -u +%Y%m%dT%H%M%SZ)-$CLUSTER"
  for id in "${ids[@]}"; do
    if break_scenario "$id"; then
      evidence "$id" "$out/$id"; pass=$((pass + 1))
    else
      evidence "$id" "$out/$id"; fail=$((fail + 1))
    fi
  done
  reset
  echo "selftest: $pass passed, $fail failed, evidence in ${out#$ROOT/}"
  (( fail == 0 ))
}

case "${1:-}" in
  up) up ;;
  metrics-server) metrics_server ;;
  reset) reset ;;
  break) break_scenario "$2" ;;
  evidence) evidence "$2" "$3" ;;
  selftest) shift; selftest "$@" ;;
  down) kind delete cluster --name "$CLUSTER" ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
