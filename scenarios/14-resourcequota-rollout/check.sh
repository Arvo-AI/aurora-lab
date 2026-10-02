kubectl -n shop get events --field-selector reason=FailedCreate -o jsonpath='{.items[*].message}' | grep -q 'exceeded quota'
