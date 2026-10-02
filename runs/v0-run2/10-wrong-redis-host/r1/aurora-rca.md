## Incident Report

**What Happened**
At 2026-10-02T16:50:26Z, a KubePodCrashLooping alert fired for the `shop` service's `api` Deployment. The pod `api-869d87b484-9n7bc`, belonging to the newly created ReplicaSet `api-869d87b484` (Deployment revision 2, created 16:49:23Z), was in CrashLoopBackOff with 5 restarts [4, 7]. Two ReplicaSets coexisted at the time of the alert: the prior revision `api-f64486c4c` with 2/2 pods healthy and Running, and the new revision with 1 pod crashing [4].

**Root Cause**
The root cause was a configuration change introduced in Deployment revision 2 that altered the container environment variable `REDIS_HOST` from `redis` to `redis-master` [9, 10]. No Kubernetes Service named `redis-master` exists in the `shop` namespace — the actual Redis Service is named `redis` (ClusterIP 10.96.239.186) and has a live backend endpoint [8, 12]. The crashing pod's logs show repeated `[Errno -2] Name does not resolve` failures when attempting to connect to `redis-master`, followed by the application giving up and exiting with code 1, which triggered kubelet's restart loop [6, 7]. The previous, healthy ReplicaSet's pods use the correct value `REDIS_HOST=redis` and remain Running without issue [9, 4], confirming the env var change in revision 2 as the differentiator between the healthy and crashing pods.

**Impact & Timeline**
Deployment revision 2 was created at 16:49:23Z, and the alert triggered roughly one minute later at 16:50:26Z after 5 restart attempts [7, 4]. At the time of the alert, the Deployment had 2/2 old-revision pods Running and serving traffic, while the single new-revision pod remained unavailable [4], indicating degraded rollout capacity (2 of 3 desired replicas ready) rather than a full service outage.

## Ruled Out
- Resource limits / OOMKilled — pod logs show a clean application-level exit ("giving up: redis unavailable") rather than an OOM termination [6].
- Node or cluster-wide infrastructure issue — other pods (old api replicas, frontend, worker, redis, loadgen) remained healthy on the same nodes [4].
- Image pull or scheduling failure — the container image was present and the pod started and ran (reaching application logic) before failing [6, 7].

## Not Checked
- `kubectl rollout history` for the Deployment was blocked by organizational policy restricting mutating/history kubectl operations, so a formal revision diff beyond the ReplicaSet/env comparison was not obtained [11].
- The validated fix (reverting `REDIS_HOST` to `redis` via `kubectl set env` or `kubectl rollout undo`) was not applied, as write operations are blocked under the current read-only policy; the fix is validated as viable but not executed.
- Broader cluster or deployment pipeline review (e.g., why the env var was changed in the source manifest) was not performed, as no evidence pointed beyond the single Deployment spec change.