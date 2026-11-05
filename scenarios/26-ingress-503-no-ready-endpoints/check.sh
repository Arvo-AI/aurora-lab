# Fault is visible when a request through the controller gets 503, both api pods
# are Running but not Ready, the api Service has no ready address and the
# controller logged the missing endpoints.
[ "$(kubectl -n shop get pods -l app=api --field-selector=status.phase=Running -o name | wc -l)" -eq 2 ] &&
[ -z "$(kubectl -n shop get pods -l app=api -o jsonpath='{.items[*].status.containerStatuses[?(@.ready==true)].name}')" ] &&
kubectl -n shop exec deploy/loadgen -- wget -q -S -O /dev/null -T 5 http://ingress-nginx-controller.ingress-nginx.svc/items 2>&1 | grep -q 'HTTP/1.1 503' &&
kubectl -n ingress-nginx logs deploy/ingress-nginx-controller --tail=200 | grep -q 'does not have any active Endpoint'
