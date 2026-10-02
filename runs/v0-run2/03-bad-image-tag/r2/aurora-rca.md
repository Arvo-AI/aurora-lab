## Incident Report: KubeDeploymentRolloutStuck — frontend (shop)

**What Happened**

At 2026-10-02T16:58:24Z, a KubeDeploymentRolloutStuck alert fired for the `frontend` deployment in the `shop` service [list_incidents context]. The deployment's rollout to revision 2 failed to progress: 2 replicas desired, only 1 updated, 3 total pods, 2 available, 1 unavailable [4, 7]. The new pod `frontend-7b6c998456-vqcpc`, created at 16:57:31, remained in `ImagePullBackOff`/Pending while the two older `frontend-76d98597b9-*` pods continued running normally at 1/1 [5, 11]. No other workloads in the namespace (api, worker, redis, loadgen) were affected, and all cluster nodes remained Ready with no resource pressure [10, 6].

**Root Cause**

The root cause was a typo'd container image tag introduced in revision 2 of the `frontend` deployment: `nginx:1.27-alpne` instead of `nginx:1.27-alpine` [4, 7]. This tag does not exist in the registry, causing the kubelet to repeatedly fail image pulls with a `NotFound` error for the new pod [11]. Revision 1's ReplicaSet (`frontend-76d98597b9`) was confirmed to use the correct `nginx:1.27-alpine` image and remained healthy at 2/2 ready [9]. Because the deployment's default `maxUnavailable: 25%` strategy keeps the old ReplicaSet available until the new one is ready, Kubernetes preserved the healthy pods but could not complete the rollout since the new pod could never reach Ready state [7, 9].

**Impact & Timeline**

The deployment was created at 16:57:25 and the broken ReplicaSet (revision 2) was created six seconds later at 16:57:31 [7, 11], with the alert firing shortly after at 16:58:24. Service availability was not degraded — the two pre-existing healthy pods on revision 1 continued serving traffic at 2/2 throughout [5, 9] — but the deployment remained stuck in a non-progressing state with one unavailable replica for the duration of the incident [4, 7].

## Ruled Out
- Node/cluster capacity or infrastructure issue — all 3 nodes reported Ready with no resource pressure [10].
- Cluster-wide outage — other workloads (api, worker, redis, loadgen) in the namespace remained healthy and running at expected replica counts [6, 10].
- Transient/retryable image pull issue — kubelet reported a persistent `NotFound` from the registry for the tag, not an intermittent pull failure [11].

## Not Checked
- Full rollout history (`kubectl rollout history`) was not available, as it was blocked by organization mutating-operations policy [8]; revision details were instead confirmed via `describe deployment` and `get rs` [7, 9].
- Source of the deployment change (CI/CD pipeline, manifest, or manual `kubectl set image` command) that introduced the typo was not identified, as no deployment-history or audit-log evidence was available in this investigation.
- Remediation (image tag revert or rollout rollback) was not executed, as mutating kubectl operations are blocked in this environment; fixes are documented as validated recommendations only.