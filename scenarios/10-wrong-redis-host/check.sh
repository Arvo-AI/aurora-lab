kubectl -n shop get pods -l app=api -o jsonpath='{.items[*].status.containerStatuses[0].lastState.terminated.exitCode}' | grep -q 1
