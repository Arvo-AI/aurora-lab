p="$(kubectl -n shop get pods -l app=api -o jsonpath='{range .items[*]}{.metadata.name} {.status.initContainerStatuses[0].state.running.startedAt}{"\n"}{end}' | awk 'NF==2{print $1; exit}')"
[ -n "$p" ] && kubectl -n shop logs "$p" -c wait-for-db --tail=3 | grep -q 'waiting for postgres'
