kubectl -n shop get pods -l app=api -o jsonpath='{.items[*].status.containerStatuses[0].state.waiting.reason}' | grep -q CreateContainerConfigError
