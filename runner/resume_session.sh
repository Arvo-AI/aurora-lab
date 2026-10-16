#!/usr/bin/env bash
# Keep the unattended v1 session going through Bedrock outages: resume it until
# STATUS.md has a Done section or the deadline passes.
cd "$(dirname "$0")/.."
SID="${1:?session id}"
DEADLINE=$(date -j -f "%Y-%m-%d %H:%M" "2026-10-02 18:45" +%s)
n=0
while (( $(date +%s) < DEADLINE )) && ! grep -q "^## Done" STATUS.md; do
  n=$((n+1))
  log="runs/v1-session-resume$n.jsonl"
  caffeinate -i claude -p --resume "$SID" "You were interrupted at about 13:15 ET by Bedrock 503 errors and are resumed now ($(date '+%H:%M') ET). Background jobs you started may have died; check what is actually running and what results exist before continuing. The new deadline is 18:45 ET, replacing 14:45. Keep following BRIEF-v1.md and every hard rule. Log the outage and this resume in STATUS.md. Do not stop until the Done section of STATUS.md is written." \
    --dangerously-skip-permissions --output-format stream-json --verbose > "$log" 2>&1 < /dev/null
  new=$(grep '"type": *"result"\|"type":"result"' "$log" | tail -1 | python3 -c 'import json,sys; l=sys.stdin.read().strip(); print(json.loads(l).get("session_id","") if l else "")' 2>/dev/null)
  [[ -n "$new" ]] && SID="$new"
  echo "$(date '+%H:%M') resume $n ended, session $SID" >> runs/resume.log
  sleep 60
done
