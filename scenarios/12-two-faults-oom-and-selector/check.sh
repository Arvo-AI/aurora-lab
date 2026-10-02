kubectl -n shop get pods -l app=worker -o jsonpath='{.items[*].status.containerStatuses[0].lastState.terminated.reason}' | grep -q OOMKilled &&
[ -z "$(kubectl -n shop get endpointslices -l kubernetes.io/service-name=frontend -o jsonpath='{.items[*].endpoints[*].addresses[*]}')" ]
