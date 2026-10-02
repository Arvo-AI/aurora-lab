# broken when the worker's last termination reason is OOMKilled
kubectl -n shop get pods -l app=worker -o jsonpath='{.items[*].status.containerStatuses[0].lastState.terminated.reason}' | grep -q OOMKilled
