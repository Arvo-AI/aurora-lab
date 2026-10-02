## Incident Report

**Alert:** KubePodCrashLooping — Service: shop — Severity: High — Triggered: 2026-10-02T21:18:35Z

### What Happened
At approximately 21:17:43 UTC on 2026-10-02, a pod in the shop namespace's frontend deployment (frontend-7d466b6bcc-lhp6p, ReplicaSet frontend-7d466b6bcc) entered CrashLoopBackOff with 3 restarts and container exit code 1 [6, 7]. This pod belongs to a newly created ReplicaSet that appeared alongside the pre-existing, healthy ReplicaSet frontend-76d98597b9, whose two pods remained 1/1 Running with 0 restarts throughout [4]. The deployment's availableReplicas/readyReplicas remained at 2/2 for the duration, meaning the old ReplicaSet continued serving traffic (/healthz and /api/items returning 200) while the new ReplicaSet churned [13, 10].

### Root Cause
The root cause is CONFIRMED: the nginx container in the new pod fails to start because the mounted ConfigMap frontend-nginx contains an invalid directive, `proxy_conect_timeout` (missing an "n"), instead of `proxy_connect_timeout`, on line 9 of default.conf [8]. nginx validates its configuration on startup and exits with `nginx: [emerg] unknown directive "proxy_conect_timeout" in /etc/nginx/conf.d/default.conf:9`, producing exit code 1 and the observed CrashLoopBackOff [6, 7]. The pod's `kubectl.kubernetes.io/restartedAt: 2026-10-02T17:17:43-04:00` annotation and deployment revision "2" with an otherwise identical pod template indicate a `kubectl rollout restart` was issued, which forced new pods to be created and read the already-malformed ConfigMap fresh at startup [7, 10, 9]. The pre-existing pods on frontend-76d98597b9 are unaffected because their nginx processes loaded the valid configuration at an earlier startup and do not re-read conf.d at runtime [4, 13].

### Impact & Timeline
The crash-looping pod was created at 21:17:43 UTC and had accumulated 3 restarts by the time of investigation (~90 seconds later) [7]. Despite the alert firing as "high" severity, the shop frontend remained available throughout: the old ReplicaSet's two pods continued serving /healthz and /api/items with 200 responses at 21:19–21:20 UTC [13], and deployment status showed 2/2 available/ready replicas [10]. The impact was therefore confined to a wedged rollout generating repeated restart events on a single pod, rather than a user-facing outage.

## Ruled Out
- Resource exhaustion (CPU/memory pressure) — all pods in the namespace showed trivial usage (1–14 MiB memory, 1–4m CPU) [12]
- Node-level failure — all three cluster nodes reported Ready status [11]
- Image pull failure — pod events showed image already present and container Created/Started successfully [7]
- Full service outage — old ReplicaSet pods were actively serving healthy 200 responses on /healthz and /api/items [13], and deployment reported 2/2 availableReplicas/readyReplicas [10]
- Readiness probe misconfiguration as root cause — probe failures are a downstream symptom of nginx never binding to port 80 due to the config validation failure, not an independent cause [6, 7]

## Not Checked
- Rollback execution (`kubectl rollout undo`) was not performed; investigation was read-only and the fix/mitigation were validated but not applied [per investigator notes]
- No prior incident history or memory entries existed for the shop service/cluster to compare against [2]
- Broader cluster-wide or multi-namespace impact beyond the shop namespace was not examined, as no symptoms indicated an issue outside shop