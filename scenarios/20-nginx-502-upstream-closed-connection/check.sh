kubectl -n shop logs deploy/loadgen --tail=5 | grep -q -- '-> 502' &&
kubectl -n shop logs -l app=frontend --tail=50 | grep -q 'upstream prematurely closed connection while reading response header from upstream' &&
[ -n "$(kubectl -n shop get endpointslices -l kubernetes.io/service-name=api -o jsonpath='{.items[*].endpoints[*].addresses[*]}')" ]
