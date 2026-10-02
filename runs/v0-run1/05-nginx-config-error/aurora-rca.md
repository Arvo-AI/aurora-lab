## Incident Report

**What Happened**

At 2026-10-02T15:01:03Z, a high-severity KubePodCrashLooping alert fired for the `shop` service. Investigation of the live cluster found pod `frontend-d6db5d589-dn4kr` (part of the Deployment `frontend`) in CrashLoopBackOff status with 3 restarts, last terminated with Exit Code 1 [4, 7]. The Deployment showed READY 2/2, AVAILABLE 2, UP-TO-DATE 1/2, indicating only the newest pod was affected while the Deployment overall remained healthy [5, 8].

**Root Cause**

The root cause was a syntax error in the `frontend-nginx` ConfigMap: the directive `proxy_conect_timeout` (missing the "n" in "connect") is invalid, causing nginx to fail config validation at startup with `unknown directive "proxy_conect_timeout" in /etc/nginx/conf.d/default.conf:9` [6, 9]. This typo is present in the ConfigMap's `last-applied-configuration` annotation, indicating it was introduced via a deliberate `kubectl apply` rather than a live edit [9]. A `kubectl rollout restart` was issued at 15:00:12 UTC, per the `kubectl.kubernetes.io/restartedAt` annotation on the pod template, creating a new ReplicaSet (`frontend-d6db5d589`) whose pods read the already-broken ConfigMap on startup and failed immediately [7, 13]. The older ReplicaSet (`frontend-76d98597b9`) pods were already running prior to this and had the config loaded into their nginx master process in memory, so they never re-parsed the file and continued serving traffic normally, as shown by continuous 200 OK responses in their access logs [8, 12]. The timing of the restart annotation, pod creation, and first crash align closely, consistent with this causal chain [7, 13].

**Impact & Timeline**

This is a stuck rolling update rather than a full outage: the two old-revision pods remained healthy and serving all traffic (READY 2/2, AVAILABLE 2) while the single new-revision pod repeatedly crashed [5, 8, 12]. No correlated alerts or downstream service impact were identified [14, 15].

## Ruled Out
- OOM/memory limit exceeded — no OOMKilled events observed, and the container never reached a point to consume memory since it fails at config validation before binding to port 80 [6, 7].
- Image pull failure — the image `nginx:1.27-alpine` was already present and successfully used across both ReplicaSets [5, 8].
- Readiness/liveness probe misconfiguration as root cause — probe failures are a downstream symptom of the process never starting, not the underlying failure [6, 7].
- Stray/live ConfigMap edit — the typo is embedded in the `last-applied-configuration` annotation, showing it was applied intentionally via `kubectl apply`, not a manual live edit [9].
- Rollback as a fix — reverting the Deployment revision would not change the ConfigMap data, leaving the broken config in place for any future pod restart [8, 9].

## Not Checked
- Full rollout history (`kubectl rollout history`) — blocked by organizational policy on mutating kubectl operations [11].
- Prior ConfigMap revisions / diff of what exactly changed before the typo was introduced — not retrievable due to the same rollout-history restriction [11].
- Broader incident correlation beyond the `frontend`/`shop` service — `service_impact` and `get_incident` queries returned no downstream effects, but deeper dependency tracing was not performed [14, 15].