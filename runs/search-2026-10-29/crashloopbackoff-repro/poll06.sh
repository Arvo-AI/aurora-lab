#!/bin/bash
export KUBECONFIG=$HOME/Claude/aurora-lab/.kubeconfig-rcrash
out=$HOME/Claude/aurora-lab/runs/search-2026-10-29/crashloopbackoff-repro/06-liveness-poll.txt
: > $out
end=$(( $(date +%s) + 1080 ))
prev=""
while [ $(date +%s) -lt $end ]; do
  l=$(kubectl -n shop get pods -l app=api --no-headers --request-timeout=10s -o custom-columns=NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount,STATE:.status.containerStatuses[0].state 2>/dev/null)
  s=$(kubectl -n shop get pods -l app=api --no-headers --request-timeout=10s 2>/dev/null | awk '{print $1,$2,$3}')
  key="$l|$s"
  if [ "$key" != "$prev" ]; then { echo "== $(date -u +%H:%M:%S)"; kubectl -n shop get pods -l app=api --request-timeout=10s 2>&1; } >> $out; prev="$key"; fi
  sleep 3
done
