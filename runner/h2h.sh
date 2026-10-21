#!/usr/bin/env bash
# Head-to-head runner: run K8sGPT and HolmesGPT against a broken lab scenario and
# save everything they print, so the same judge that graded Aurora can grade them.
#
#   ./runner/h2h.sh <scenario> [run-dir]
#
# Assumes the fault is already injected (./lab.sh break <scenario>) and the lab
# kubeconfig is at .kubeconfig. Both tools use the same Bedrock model Aurora used
# in v0-run2 (us.anthropic.claude-sonnet-5) through AWS_PROFILE/AWS_REGION.
# K8sGPT gets the whole namespace; HolmesGPT gets the alert text, like Aurora did.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCEN=$1
OUT=${2:-$ROOT/runs/h2h-$(date -u +%Y%m%dT%H%M%SZ)}/$SCEN
mkdir -p "$OUT"
export KUBECONFIG="$ROOT/.kubeconfig"
export AWS_PROFILE=${AWS_PROFILE:-claude-390} AWS_REGION=${AWS_REGION:-us-east-1} AWS_DEFAULT_REGION=${AWS_REGION:-us-east-1}
MODEL=us.anthropic.claude-sonnet-5
ALERT=$(python3 -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['alert'])" "$ROOT/scenarios/$SCEN/scenario.yaml" 2>/dev/null \
  || grep -E '^alert:' "$ROOT/scenarios/$SCEN/scenario.yaml" | sed -E 's/^alert: *"?//; s/"? *$//')
echo "{\"scenario\":\"$SCEN\",\"alert\":$(printf '%s' "$ALERT" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'),\"model\":\"$MODEL\",\"started\":\"$(date -u +%FT%TZ)\"}" > "$OUT/meta.json"

# K8sGPT: analyzers over the shop namespace, explanations on, JSON and text.
# "seconds" covers both passes (that is what h2h-v1 recorded); "seconds_json" is the first pass alone.
t0=$(date +%s)
k8sgpt analyze --explain --namespace shop --output json --no-cache > "$OUT/k8sgpt.json" 2> "$OUT/k8sgpt.err"; rc=$?
t1=$(date +%s)
k8sgpt analyze --explain --namespace shop --no-cache > "$OUT/k8sgpt.txt" 2>> "$OUT/k8sgpt.err"
echo "{\"tool\":\"k8sgpt\",\"version\":\"$(k8sgpt version 2>/dev/null | head -1)\",\"seconds\":$(( $(date +%s) - t0 )),\"seconds_json\":$(( t1 - t0 )),\"exit\":$rc}" > "$OUT/k8sgpt.meta.json"

# HolmesGPT: the alert text as the question, same model, default toolsets (its own allow-list
# refuses commands it does not know, so in practice it ran read-only; the kubeconfig is the admin one).
export PATH="$HOME/.local/bin:$PATH"
t0=$(date +%s)
holmes ask "$ALERT Namespace shop, cluster kind-aurora-lab. Find the root cause and say what changed." \
  --model "bedrock/$MODEL" --max-steps 40 > "$OUT/holmes.md" 2> "$OUT/holmes.err"; rc=$?
echo "{\"tool\":\"holmesgpt\",\"version\":\"$(holmes version 2>/dev/null | head -1)\",\"seconds\":$(( $(date +%s) - t0 )),\"exit\":$rc}" > "$OUT/holmes.meta.json"

echo "saved to $OUT"; ls "$OUT"
