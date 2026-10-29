#!/usr/bin/env bash
# Drive the alert-fatigue run on the rfat kind cluster.
#   phase "baseline": healthy shop app, record alerts for BASE_MIN minutes
#   then each scenario: ./lab.sh break <id>, record alerts for WIN_MIN minutes
# Every 30 s the full Prometheus /api/v1/alerts payload is appended to
# alerts.jsonl with the phase name. Alertmanager notifications are captured
# separately from the pager-log pod (pager-log.jsonl).
set -uo pipefail
LAB=~/Claude/aurora-lab
OUT="${OUT:-$(cd "$(dirname "$0")" && pwd)}"; mkdir -p "$OUT"
export KUBECONFIG=$LAB/.kubeconfig-rfat
CTX=kind-rfat
URL='/api/v1/namespaces/monitoring/services/kps-kube-prometheus-stack-prometheus:9090/proxy/api/v1/alerts'
BASE_MIN=${BASE_MIN:-20}; WIN_MIN=${WIN_MIN:-18}

snap() { # phase
  local body
  body="$(kubectl --context $CTX --request-timeout=20s get --raw "$URL" 2>/dev/null)" || { echo "{\"t\":\"$(date -u +%FT%TZ)\",\"phase\":\"$1\",\"error\":true}" >> "$OUT/alerts.jsonl"; return; }
  python3 -c 'import json,sys; d=json.loads(sys.argv[3]); print(json.dumps({"t":sys.argv[1],"phase":sys.argv[2],"alerts":d["data"]["alerts"]}))' "$(date -u +%FT%TZ)" "$1" "$body" >> "$OUT/alerts.jsonl"
}
watch_for() { # phase minutes
  local end=$(( $(date +%s) + $2 * 60 ))
  while (( $(date +%s) < end )); do snap "$1"; sleep 30; done
}
log() { echo "$(date -u +%FT%TZ) $*" | tee -a "$OUT/driver.log"; }

ids=("$@")
if [[ ${#ids[@]} -eq 0 || "${RUN_BASELINE:-0}" == 1 ]]; then
  (cd $LAB && LAB_CLUSTER=rfat ./lab.sh reset) >> "$OUT/driver.log" 2>&1
  log "phase baseline start"; watch_for baseline "$BASE_MIN"; log "phase baseline end"
fi
if [[ ${#ids[@]} -eq 0 ]]; then
  while IFS= read -r d; do ids+=("$(basename "$d")"); done < <(find "$LAB/scenarios" -mindepth 1 -maxdepth 1 -type d | sort)
fi
for id in "${ids[@]}"; do
  log "phase $id break start"
  if (cd $LAB && LAB_CLUSTER=rfat ./lab.sh break "$id" >> "$OUT/driver.log" 2>&1); then
    log "phase $id broken"
  else
    log "phase $id BREAK FAILED"
  fi
  watch_for "$id" "$WIN_MIN"
  log "phase $id end"
done
(cd $LAB && LAB_CLUSTER=rfat ./lab.sh reset) && log "final reset ok"
kubectl --context $CTX -n monitoring logs deploy/pager-log > "$OUT/pager-log.jsonl"
log "done"
