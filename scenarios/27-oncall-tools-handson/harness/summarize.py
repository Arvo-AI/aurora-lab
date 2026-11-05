import glob, json, sys
for f in sorted(glob.glob(sys.argv[1] + "/*/result.json")):
    r = json.load(open(f))
    print("##", r["tool"], r.get("version", ""), "error:", r.get("error"))
    for k in ("install_seconds", "seconds_to_first_alert", "firing_http", "repeat_http", "resolved_http"): print(" ", k, r.get(k))
    print("  steps:", len(r["steps_to_first_alert"])); [print("   -", s) for s in r["steps_to_first_alert"]]
    print("  first:", json.dumps(r.get("after_first_firing"))[:400]); print("  states:", json.dumps(r.get("alert_states"))[:700]); print("  escalation:", json.dumps(r.get("escalation"))[:900])
    [print("  finding:", x) for x in r["findings"]]; [print("  not tested:", x) for x in r["not_tested"]]
