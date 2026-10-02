kubectl -n shop get events --field-selector reason=FailedScheduling -o jsonpath='{.items[*].message}' | grep -q 'Insufficient cpu'
