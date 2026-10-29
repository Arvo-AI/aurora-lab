#!/bin/bash
export KUBECONFIG=$HOME/Claude/aurora-lab/.kubeconfig-rcrash
out=$HOME/Claude/aurora-lab/runs/search-2026-10-29/crashloopbackoff-repro/backoff-poll.tsv
echo -e "sample_utc\trestartCount\tstate\tstartedAt(current or last)\tfinishedAt(last)" > $out
prev=""
end=$(( $(date +%s) + 1500 ))
while [ $(date +%s) -lt $end ]; do
  l=$(kubectl -n crash get pods -l app=exit1 --request-timeout=10s -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}{"\t"}{.items[0].status.containerStatuses[0].state}{"\t"}{.items[0].status.containerStatuses[0].lastState.terminated.startedAt}{"\t"}{.items[0].status.containerStatuses[0].lastState.terminated.finishedAt}' 2>/dev/null)
  if [ -n "$l" ] && [ "$l" != "$prev" ]; then echo -e "$(date -u +%H:%M:%S)\t$l" >> $out; prev="$l"; fi
  sleep 1
done
