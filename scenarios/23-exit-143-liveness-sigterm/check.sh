# Passes once a restarted api container reports exit code 143 and the kubelet has
# recorded the liveness kill that caused it.
kubectl -n shop get pods -l app=api -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.exitCode}' | tr ' ' '\n' | grep -qx 143 &&
kubectl -n shop get events --field-selector reason=Killing | grep -q 'failed liveness probe'
