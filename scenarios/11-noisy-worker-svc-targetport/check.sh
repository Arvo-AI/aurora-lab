kubectl -n shop logs deploy/loadgen --tail=5 | grep -q -- '-> 502' &&
kubectl -n shop logs -l app=worker --tail=20 | grep -q DeprecationWarning
