# The fault shows when the kubelet has recorded the deadline message and the api
# rollout is stuck with old pods still serving.
kubectl -n shop get events --field-selector reason=Unhealthy -o jsonpath='{.items[*].message}' | grep -q 'context deadline exceeded (Client.Timeout exceeded while awaiting headers)' &&
[ "$(kubectl -n shop get deploy api -o jsonpath='{.status.availableReplicas}')" -ge 1 ] &&
[ "$(kubectl -n shop get deploy api -o jsonpath='{.status.unavailableReplicas}')" -ge 1 ]
