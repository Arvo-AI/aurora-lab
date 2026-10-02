# also proves kindnet enforces NetworkPolicy: without enforcement the api keeps answering 200
kubectl -n shop logs deploy/loadgen --tail=5 | grep -q -- '-> 503' &&
kubectl -n shop logs -l app=api --tail=20 | grep -q 'redis error'
