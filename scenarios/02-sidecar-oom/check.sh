kubectl -n shop get pods -l app=api -o jsonpath='{range .items[*].status.containerStatuses[?(@.name=="log-shipper")]}{.lastState.terminated.reason}{"\n"}{end}' | grep -q OOMKilled
