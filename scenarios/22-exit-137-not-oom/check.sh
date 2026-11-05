# The fault is present once a worker container has been killed with 137 and reason
# Error (the failed probe is what sets it off, and reason OOMKilled would be a
# different fault).
kubectl -n shop get pods -l app=worker -o jsonpath='{range .items[*].status.containerStatuses[*]}{.lastState.terminated.exitCode}/{.lastState.terminated.reason}{"\n"}{end}' | grep -qx '137/Error' &&
kubectl -n shop get events --field-selector reason=Killing | grep -q 'failed liveness probe'
