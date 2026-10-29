#!/usr/bin/env bash
# Pass: the last 10 loadgen requests are all 200 and no frontend pod logged
# "upstream prematurely closed connection" in the last 30 s. Non-zero otherwise.
set -uo pipefail
CTX="${1:?kube context}"
k() { kubectl --context "$CTX" "$@"; }
sleep 30
last="$(k -n shop logs deploy/loadgen --tail=10)"
echo "$last"
bad="$(k -n shop logs -l app=frontend --since=30s --tail=-1 | grep -c 'upstream prematurely closed connection' || true)"
echo "prematurely closed lines in the last 30 s: $bad"
[ "$(echo "$last" | grep -c -- '-> 200$')" -eq 10 ] && [ "$bad" -eq 0 ]
