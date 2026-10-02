kubectl -n shop get pods -l app=frontend -o jsonpath='{.items[*].status.containerStatuses[0].state.waiting.reason}' | grep -Eq 'ImagePullBackOff|ErrImagePull'
