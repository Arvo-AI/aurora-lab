#!/usr/bin/env bash
# Installs each self-hostable on-call tool with docker compose and sends every
# tool the same Alertmanager webhook payload. Raw output lands in $OUT/<tool>/.
# Run through .github/workflows/repro.yml with -f kind=false.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
export OUT="${OUT:-$PWD/out}" HERE
mkdir -p "$OUT"
HOST_IP=$(hostname -I | awk '{print $1}')
export SINK_URL="http://$HOST_IP:9099"
{ echo "host_ip $HOST_IP"; docker compose version; python3 --version; nproc; free -m | sed -n 2p; df -h / | tail -1; } >> "$OUT/versions.txt" 2>&1

python3 "$HERE/harness/sink.py" 9099 "$OUT/sink.jsonl" & SINK=$!
trap 'kill $SINK 2>/dev/null' EXIT
sleep 1

# 1. Capture the payload from a real Alertmanager, so every tool gets real bytes.
bash "$HERE/harness/capture-payload.sh" 2>&1 | tee "$OUT/capture-payload.log"
[ -s "$OUT/payload-firing.json" ] || { echo "no payload captured"; exit 1; }

# 2. Run each tool on its own, tear it down, reclaim disk.
for t in $(cat "$HERE/tools.list"); do
  echo "=== $t $(date -u +%FT%TZ)"
  mkdir -p "$OUT/$t"
  timeout "${TOOL_TIMEOUT:-900}" python3 "$HERE/tools/$t.py" 2>&1 | tee "$OUT/$t/driver.log" | tail -40
  echo "exit ${PIPESTATUS[0]}" >> "$OUT/$t/driver.log"
  [ -f "/tmp/lab27/$t/teardown.sh" ] && bash "/tmp/lab27/$t/teardown.sh" >/dev/null 2>&1
  docker ps -aq | xargs -r docker rm -f >/dev/null 2>&1
  docker volume prune -af >/dev/null 2>&1; docker network prune -f >/dev/null 2>&1
  docker image prune -af >/dev/null 2>&1
  df -h / | tail -1
done
python3 "$HERE/harness/summarize.py" "$OUT" | tee "$OUT/summary.txt"
exit 0
