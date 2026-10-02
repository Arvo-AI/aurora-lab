## Incident Report

**What Happened:**
At 21:25:40 UTC on 2026-10-02, a high-severity KubePodCrashLooping alert fired for the `shop` service in the `kind-aurora-lab` cluster [1, 3]. The pod `api-869d87b484-rs9d6`, belonging to the newly created ReplicaSet from deployment revision 2 (created at 21:24:38 UTC), was observed in a 0/1 Running state with 3 restarts and repeated "Back-off restarting failed container" events [4, 5, 7]. The previous ReplicaSet, `api-f64486c4c-*` (revision 1), remained healthy at 1/1 Ready throughout, continuing to serve `GET /items` and `GET /healthz` requests with 200 responses [4, 11].

**Root Cause:**
The root cause was a bad environment variable introduced in deployment revision 2 of `deployment/api`: `REDIS_HOST` was changed from `redis` to `redis-master` [12, 13]. The cluster's `shop` namespace only exposes a `redis` Service (ClusterIP 10.96.122.174:6379) — no `redis-master` Service exists [9]. As a result, the application in the revision-2 pod cannot resolve the Redis hostname, logs five consecutive `[Errno -2] Name does not resolve` failures, and exits with code 1 before it can bind to port 8080, which kubelet reports as CrashLoopBackOff [6, 7]. The healthy revision-1 pods, which still use `REDIS_HOST=redis`, confirm that the Service name `redis` is correct and reachable [11, 12], isolating the single changed value as the cause.

**Impact & Timeline:**
Deployment revision 2 was rolled out at 21:24:38 UTC, scaling up `api-869d87b484` [7]. The pod began crash-looping almost immediately, with BackOff events recorded in the 21:25:xx UTC range, matching the alert trigger time of 21:25:40 UTC [1, 5, 7]. Impact was confined to the single new replica (`api-869d87b484-rs9d6`, 0/1 Ready, 3 restarts); the two revision-1 replicas continued serving traffic normally throughout [4, 11], and other `shop` workloads (frontend, worker, redis) were unaffected by this issue.

## Ruled Out
- **OOM/resource exhaustion** — restart reason is application exit code 1 from a DNS resolution failure, not OOMKilled; memory limit (128Mi) is unchanged between revisions [12, 13, 6].
- **Redis Service unreachable/misconfigured** — the `redis` Service exists and is actively serving the healthy revision-1 pods, ruling out a broader Redis outage [9, 11].
- **Readiness/liveness probe misconfiguration** — probe settings are identical between revision 1 and revision 2; failures are a consequence of the process exiting before binding to :8080, not a probe definition change [12, 13].

## Not Checked
- Root cause within the application's retry/backoff logic (e.g., why only 5 attempts before giving up) — not relevant to remediation and not examined.
- Node-level or network policy restrictions on worker2 — no symptoms indicated a node/network issue, and revision-1 pods on the same node were healthy [4].
- Historical deploy audit trail / CHANGE-CAUSE for revisions 1 and 2 — not recorded (`<none>` in rollout history), so who/what triggered the env var change was not determined [10].