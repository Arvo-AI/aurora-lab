#!/usr/bin/env bash
# The fix: put the api code back (the ConfigMap is the release here) and roll the
# api so the pods load it. Rollback: re-run break.sh.
set -euo pipefail
CTX="${1:?kube context}"; ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
k() { kubectl --context "$CTX" "$@"; }
python3 - "$ROOT/app/shop.yaml" <<'PY' | k apply -f -
import sys
docs = open(sys.argv[1]).read().split("\n---\n")
print(next(d for d in docs if "name: api-code" in d))
PY
k -n shop rollout restart deploy/api
k -n shop rollout status deploy/api --timeout=120s
