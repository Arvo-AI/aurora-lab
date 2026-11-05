# Fault: the uploader logged a reset or a broken pipe, and the api is fully
# rolled out with endpoints, so nothing in the cluster reports a problem.
kubectl -n shop logs deploy/uploader --tail=50 | grep -Eq 'import failed .*(ConnectionResetError|BrokenPipeError)' &&
kubectl -n shop rollout status deploy/api --timeout=5s >/dev/null &&
[ -n "$(kubectl -n shop get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{.items[*].endpoints[*].addresses[*]}')" ]
