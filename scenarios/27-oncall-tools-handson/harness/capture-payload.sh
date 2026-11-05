#!/usr/bin/env bash
# Starts a real Alertmanager, posts two alerts to it, and saves the webhook body
# it delivers (firing, then resolved) to $OUT/payload-{firing,resolved}.json.
set -u
AM=prom/alertmanager:v0.34.2
W=/tmp/lab27/am; mkdir -p "$W"
cat > "$W/alertmanager.yml" <<YML
route:
  receiver: capture
  group_by: [alertname, service]
  group_wait: 1s
  group_interval: 5s
  repeat_interval: 1h
receivers:
  - name: capture
    webhook_configs:
      - url: $SINK_URL/capture
        send_resolved: true
YML
docker run -d --name lab27-am -p 9093:9093 -v "$W/alertmanager.yml:/etc/alertmanager/alertmanager.yml:ro" "$AM" >/dev/null
docker image inspect "$AM" --format '{{index .RepoDigests 0}}' >> "$OUT/versions.txt"
for i in $(seq 1 30); do curl -fs localhost:9093/-/ready >/dev/null && break; sleep 1; done
docker logs lab27-am 2>&1 | grep -m1 'Starting Alertmanager'
alert() { # $1 = endsAt suffix json
  python3 - "$1" <<'PY' > /tmp/lab27/am/alerts.json
import datetime, json, sys
now = datetime.datetime.now(datetime.timezone.utc)
base = {"annotations": {"summary": "checkout returns 5xx above 5%", "description": "5xx ratio on checkout is above 5% for 5 minutes"},
        "generatorURL": "http://prometheus:9090/graph?g0.expr=checkout_5xx_ratio"}
items = []
for pod in ("checkout-0", "checkout-1"):
    a = dict(base); a["labels"] = {"alertname": "CheckoutHighErrorRate", "service": "checkout", "severity": "critical", "namespace": "shop", "pod": pod}
    if sys.argv[1] == "end":
        a["endsAt"] = (now - datetime.timedelta(seconds=1)).isoformat()
    items.append(a)
print(json.dumps(items))
PY
  curl -s -XPOST -H 'Content-Type: application/json' -d @/tmp/lab27/am/alerts.json localhost:9093/api/v2/alerts; echo
}
alert fire
for i in $(seq 1 30); do grep -q '"path": "/capture"' "$OUT/sink.jsonl" 2>/dev/null && break; sleep 1; done
alert end
for i in $(seq 1 90); do [ "$(grep -c '"path": "/capture"' "$OUT/sink.jsonl")" -ge 2 ] && break; sleep 1; done
python3 - <<'PY'
import json, os
out = os.environ["OUT"]
rows = [json.loads(l) for l in open(out + "/sink.jsonl")]
rows = [r for r in rows if r["path"] == "/capture"]
for r in rows:
    body = json.loads(r["body"]); name = "payload-%s.json" % body["status"]
    if not os.path.exists(f"{out}/{name}"):
        open(f"{out}/{name}", "w").write(r["body"])
        print(name, len(r["body"]), "bytes", "alerts:", len(body["alerts"]), "groupKey:", body["groupKey"])
PY
docker rm -f lab27-am >/dev/null
