l="$(kubectl -n shop logs deploy/loadgen --tail=30)"
# The failing frontend pod returns 502 while nginx is still starting and 504 once
# it is up and the upstream connect times out; accept either, alongside 200s from
# the healthy pod. (Before 2026-10-19 this only matched 502.)
echo "$l" | grep -q -E -- '-> 50[24]' && echo "$l" | grep -q -- '-> 200'
