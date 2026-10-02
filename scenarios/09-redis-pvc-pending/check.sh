kubectl -n shop get pvc redis-data -o jsonpath='{.status.phase}' | grep -q Pending &&
kubectl -n shop get pods -l app=api -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' | grep -Eq '[1-9]'
