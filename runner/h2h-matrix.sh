#!/usr/bin/env bash
# Run HolmesGPT and K8sGPT on every scenario, one repeat per invocation.
#   ./runner/h2h-matrix.sh runs/h2h-v1 r1
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd); OUT=$1; REP=${2:-r1}
for d in "$ROOT"/scenarios/*/; do
  s=$(basename "$d")
  echo "== $s $(date -u +%T)"
  "$ROOT/lab.sh" break "$s" > "$OUT.$s.$REP.break.log" 2>&1 || { echo "break failed for $s"; continue; }
  "$ROOT/runner/h2h.sh" "$s" "$OUT/$REP" >/dev/null 2>&1
  tail -c 300 "$OUT/$REP/$s/holmes.md" | tr '\n' ' ' | cut -c1-200; echo
done
"$ROOT/lab.sh" reset >/dev/null 2>&1
echo "matrix done $(date -u +%T)"
