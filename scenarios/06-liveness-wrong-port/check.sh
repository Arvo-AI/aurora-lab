# broken once the kubelet has restarted an api container after failed liveness probes
kubectl -n shop get events --field-selector reason=Unhealthy -o jsonpath='{.items[*].message}' | grep -q 'Liveness probe failed' &&
kubectl -n shop get pods -l app=api -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' | grep -Eq '[1-9]'
