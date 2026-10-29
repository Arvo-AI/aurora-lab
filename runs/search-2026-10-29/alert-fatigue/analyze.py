"""Summarise alerts.jsonl (Prometheus /api/v1/alerts every 30 s, tagged by phase)
and pager-log.jsonl (every Alertmanager webhook notification).
Usage: python3 -I analyze.py <run dir>"""
import json, sys, re, collections, os
d = sys.argv[1]
snaps = [json.loads(l) for l in open(os.path.join(d, "alerts.jsonl"))]
DROP = {"pod", "uid", "instance", "endpoint", "service", "prometheus", "job"}

def workload(pod):
    return re.sub(r"-[a-z0-9]{8,10}-[a-z0-9]{5}$", "", pod)

def key(a):
    l = dict(a["labels"])
    if "pod" in l:
        l["workload"] = workload(l["pod"])
    if l.get("namespace") != "shop":
        # keep instance for node / target alerts outside the app
        pass
    for k in DROP:
        if l.get("namespace") == "shop":
            l.pop(k, None)
    l.pop("prometheus", None)
    return tuple(sorted(l.items()))

def short(k):
    l = dict(k)
    bits = [l.get("alertname")]
    for f in ("namespace", "workload", "deployment", "container", "reason", "job", "mountpoint", "persistentvolumeclaim", "horizontalpodautoscaler"):
        if f in l:
            bits.append(f"{f}={l[f]}")
    return " ".join(bits)

phases = collections.OrderedDict()
for s in snaps:
    if s.get("error"):
        phases.setdefault(s["phase"], {"snaps": 0, "err": 0, "alerts": {}})["err"] += 1
        continue
    p = phases.setdefault(s["phase"], {"snaps": 0, "err": 0, "alerts": {}, "first": s["t"]})
    p.setdefault("first", s["t"]); p["last"] = s["t"]
    p["snaps"] += 1
    for a in s["alerts"]:
        if a["labels"]["alertname"] == "Watchdog":
            continue
        k = key(a)
        st = p["alerts"].setdefault(k, {"pending": 0, "firing": 0, "for": None, "activeAt": a.get("activeAt")})
        st[a["state"]] += 1

base = set(phases.get("baseline", {}).get("alerts", {}))
out = {}
for name, p in phases.items():
    new = {k: v for k, v in p["alerts"].items() if k not in base or name == "baseline"}
    fired = sorted(short(k) for k, v in new.items() if v["firing"])
    pend = sorted(short(k) for k, v in new.items() if not v["firing"])
    shop = sorted(short(k) for k, v in p["alerts"].items() if dict(k).get("namespace") == "shop")
    out[name] = {"window": [p.get("first"), p.get("last")], "snapshots": p["snaps"], "errors": p["err"],
                 "new_firing": fired, "new_pending_only": pend, "shop_alerts": shop,
                 "background_alerts": len([k for k in p["alerts"] if k in base])}
    print(f"\n## {name}  snaps={p['snaps']} err={p['err']} window={p.get('first')}..{p.get('last')}")
    print(f"  background (also in baseline): {out[name]['background_alerts']}")
    for x in fired: print("  FIRING ", x)
    for x in pend: print("  pending", x)

# notifications
pl = os.path.join(d, "pager-log.jsonl")
if os.path.exists(pl):
    notes = [json.loads(l) for l in open(pl) if l.startswith("{")]
    windows = [(n, v["window"]) for n, v in out.items()]
    print("\n## notifications")
    per = collections.Counter(); pershop = collections.Counter()
    for n in notes:
        t = n["received"][:19]
        ph = "before-baseline"
        for name, (a, b) in windows:
            if a and a[:19] <= t:
                ph = name
        per[ph] += 1
        names = sorted({a["labels"]["alertname"] for a in n["alerts"] if a["status"] == "firing"})
        ns = (n.get("groupLabels") or {}).get("namespace")
        if ns == "shop": pershop[ph] += 1
        print(f"  {t} [{ph}] {n['status']} group={n.get('groupLabels')} firing={names} n_alerts={len(n['alerts'])}")
    print("\nper phase:", dict(per)); print("shop group per phase:", dict(pershop))
json.dump(out, open(os.path.join(d, "summary.json"), "w"), indent=1)
