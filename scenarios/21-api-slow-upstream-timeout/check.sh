# The baseline loadgen gives up after 3 s (wget -T 3), long before nginx's 60 s
# proxy_read_timeout, so its requests end as 499 in the nginx log, not 504. This
# check sends one request that waits long enough to see what nginx returns.
kubectl -n shop exec deploy/loadgen -- wget -q -S -O /dev/null -T 90 http://frontend/api/items 2>&1 | grep -q 'HTTP/1.1 504' &&
kubectl -n shop logs -l app=frontend --tail=100 | grep -q 'upstream timed out (110: Operation timed out) while reading response header from upstream' &&
[ -n "$(kubectl -n shop get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{.items[*].endpoints[*].addresses[*]}')" ]
