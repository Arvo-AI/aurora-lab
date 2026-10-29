#!/bin/bash
export KUBECONFIG=$HOME/Claude/aurora-lab/.kubeconfig-rcrash
out=$HOME/Claude/aurora-lab/runs/search-2026-10-29/crashloopbackoff-repro/state-samples.tsv
echo -e "sample_utc\tpod\trestarts\tstate_kind\treason\tkubectl_STATUS" > $out
for i in $(seq 1 120); do
  t=$(date -u +%H:%M:%S)
  kubectl -n crash get pods --request-timeout=10s -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].restartCount}{"\t"}{.status.containerStatuses[0].state}{"\n"}{end}' 2>/dev/null | python3 -I -c "
import sys,json
for l in sys.stdin:
  n,r,s=l.rstrip('\n').split('\t',2)
  d=json.loads(s); k=list(d)[0]; print('$t',n,r,k,d[k].get('reason',''),sep='\t')" >> $out
  sleep 5
done
