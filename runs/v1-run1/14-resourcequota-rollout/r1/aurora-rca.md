## Incident Report

**What Happened**

At 2026-10-02T20:29:03Z, a high-severity alert fired indicating the `api` deployment rollout in the `shop` namespace was stuck (KubeDeploymentRolloutStuck). The deployment showed 2 desired/0 updated/2 total/2 available replicas, with the `ReplicaFailure` condition set to True (reason: FailedCreate) [9]. The new ReplicaSet `api-57f65dc5db` (revision 2) was unable to create any of its 1 desired pod, remaining at 0/1 for the duration of the rollout attempt [6, 7]. The previous ReplicaSet `api-f64486c4c` continued serving traffic normally at 2/2 Running [5, 6], so the running `api` workload itself was not degraded during this event.

**Root Cause**

The root cause was a namespace ResourceQuota (`compute-resources`) with a `requests.memory` hard limit of 200Mi that was already fully consumed by steady-state workloads in the `shop` namespace — 2x api (32Mi each), 2x frontend (16Mi each), loadgen (8Mi), redis (32Mi), and worker (64Mi), summing to exactly 200Mi [10, 11, 13]. The `api` Deployment's RollingUpdate strategy (maxSurge 25%, maxUnavailable 25%) requires one additional surge pod (requesting 32Mi) to exist alongside the existing pods during a rollout [9, 14]. Because the quota had zero headroom, every attempt by the new ReplicaSet to create its surge pod was rejected by quota admission control, producing repeated FailedCreate events on `api-57f65dc5db` [7, 8] and permanently stalling the rollout. The image was unchanged between ReplicaSets (`python:3.12-alpine`) [4], and no scheduling or node-capacity issue was involved, since the pod was rejected at admission before scheduling was ever attempted [7, 10].

**Impact & Timeline**

The ResourceQuota object was created at 2026-10-02T20:28:16Z [13], and the deployment began its rollout (revision 2) shortly after, at 20:28:14Z [9], immediately hitting the quota ceiling. The alert triggered at 20:29:03Z [triggered_at]. Impact was limited to the rollout itself: the new revision could not progress past 0/1, while the existing 2/2 `api` pods on the old ReplicaSet remained available throughout, so end-user-facing capacity was not reduced [5, 6, 9].

## Ruled Out
- Image pull / registry issues — events show the image was "already present on machine" for all pods [8].
- Readiness probe failures — old ReplicaSet pods showed only transient startup connection errors and are now 1/1 Running; unrelated to the new RS's inability to create pods [5].
- Node capacity / scheduling problems — new surge pod was rejected at quota admission before scheduling was ever attempted [7].
- CPU quota exhaustion — the `compute-resources` quota only defines/enforces `requests.memory`; no CPU limit is present [10, 13].

## Not Checked
- `kubectl rollout history` for the deployment was blocked by organization policy (mutating-adjacent command restriction), so prior revision details beyond revision 2 could not be reviewed [12].
- No prior incidents or memory entries exist for this signature, so historical recurrence or prior remediation of this quota configuration could not be assessed [1, 2].
- The exact source/author of the ResourceQuota creation and the `restartedAt` rollout trigger (e.g., which user or automation applied them) was not investigated, as it does not affect the confirmed admission-control mechanism.