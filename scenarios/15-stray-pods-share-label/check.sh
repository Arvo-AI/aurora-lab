l="$(kubectl -n shop logs deploy/loadgen --tail=30)"
echo "$l" | grep -q -- '-> 500' && echo "$l" | grep -q -- '-> 200'
