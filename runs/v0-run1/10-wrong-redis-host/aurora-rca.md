## Incident Report

**What Happened**

On 2026-10-02 at 15:43:08 UTC, a KubePodCrashLooping alert fired for the `shop` service. At the time of investigation, one api pod (`api-869d87b484-f5hk2`) was in CrashLoopBackOff/Error state with 3 restarts in roughly 95 seconds, while two other api pods (`api-f64486c4c-nqg2f`, `api-f64486c4c-pv44t`) were Running and healthy with 0 restarts [3]. The affected pod belonged to a newly created ReplicaSet (`api-869d87b484`) associated with Deployment revision 2, which was mid-rollout alongside the still-active previous ReplicaSet (`api-f64486c4c`) [6, 9].

**Root Cause**

The root cause was a configuration drift in the `api` Deployment's `REDIS_HOST` environment variable: the live pod template specified `redis-master`, a hostname with no corresponding Service in the `shop` namespace, whereas the originally reviewed `last-applied-configuration` and the two healthy pods both use the correct value, `redis` [9, 11]. Only the `api`, `frontend`, and `redis` Services exist in the namespace [10], so any pod built from the new template fails DNS resolution for `redis-master` on startup. The crashing pod's logs show five consecutive failed Redis connection attempts with `[Errno -2] Name does not resolve`, followed by the process exiting with code 1 and giving up [8], which directly triggered kubelet's restart-and-backoff cycle. This is isolated to the new pod template, not a cluster-wide issue: the healthy pods from the prior ReplicaSet retain `REDIS_HOST=redis` and are unaffected [11], CoreDNS is healthy [17], and all nodes are Ready [16].

**Impact & Timeline**

Impact was limited to one of three api pods; the Service endpoint list for `api` contains only the two healthy pod IPs, confirming the crashing pod was correctly excluded from traffic and was not serving requests [12]. The two remaining pods continued serving `shop/api` traffic normally at the time of the alert, making this a capacity/rollout degradation rather than a user-facing outage at the moment of investigation [3, 12].

## Ruled Out
- Cluster-wide DNS failure — CoreDNS pods are healthy (2/2 Running, 0 restarts) [17]
- Node-level failure — all three cluster nodes report Ready status [16]
- OOMKilled container — pod exited with code 1 from an application-level Redis connection failure, not code 137 [8]
- Unrelated worker BATCH_SIZE/OOM crash mechanism (seen in prior incidents) — the `worker` pod is running normally with `BATCH_SIZE=500` and processing batches without error [14, 15]

## Not Checked
- Full rollout history of `deployment/api` — `kubectl rollout history` was blocked by organization policy, so the exact change event that introduced `REDIS_HOST=redis-master` could not be directly inspected [7]
- Remediation execution — both validated fixes (env var revert, rollout undo) are mutating operations blocked in this read-only session and were not applied