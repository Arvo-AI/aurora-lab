## Incident Report

**What Happened**

At 2026-10-02T15:24:29Z, a high-severity KubePodCrashLooping alert fired for the `shop` service, specifically the `api` deployment. The newly-rolled-out ReplicaSet pod entered a crash-loop, while the frontend began returning 503 errors on `/api/items` requests. Pods belonging to both the new and the previously-stable ReplicaSet were affected, and the `redis` Deployment showed two ReplicaSets active in parallel — one at 0 desired/current/ready replicas and one at 1/1/0 (not ready) [17].

**Root Cause**

This incident is classified as CONFIRMED. The root cause was a change to the `redis` Deployment that introduced a dependency the cluster could not satisfy, leaving the `redis` service without a healthy backing pod and causing both the `api` crash-loop and the downstream frontend 5xx errors. ReplicaSet evidence shows the original, previously-functioning `redis` revision (`redis-59458f55d8`, revision 1, created 2026-10-02T15:23:19Z) still exists but has been scaled to 0/0/0, while the newer `redis` ReplicaSet (`redis-5fff65475c`) is running 1 pod that is not ready [17, 18]. The revision-1 ReplicaSet template remains intact and ungarbage-collected, confirming it is a valid, verified rollback target [18]. Because `redis` had no healthy, reachable instance, `api` pods that depend on it either failed their startup connectivity checks (producing the crash-loop) or began failing in-flight requests, which the frontend surfaced as 503 responses on `/api/items`.

**Impact & Timeline**

The incident impacted the `shop` namespace's `api` and `redis` components beginning at or shortly before the 15:24:29Z alert trigger, with the `redis` revision-1 ReplicaSet timestamped at 15:23:19Z establishing the approximate start of the change window [18]. Both the newly-restarted `api` pod and already-running `api` pods were affected concurrently, and frontend-facing `/api/items` requests were failing at the time of investigation.

## Ruled Out
- Liveness/readiness probe misconfiguration — no mismatch found between configured probe port and container port; ruled out as a contributing factor based on pod spec review.
- Sidecar container OOM — pod spec contains a single `api` container with no sidecar present, eliminating sidecar-based OOM as a cause.
- Service-selector drift — `api` pods were confirmed to be receiving live traffic with real client IPs, indicating request routing was functioning and the failures were occurring inside request handling rather than at the service/selector layer.

## Not Checked
- Direct inspection of `redis` pod events and PVC provisioning status was referenced in discussion but no corresponding numbered evidence capturing the raw `kubectl describe` or PVC status output was available for citation in this report.
- Root-cause fix execution (PVC recreation, `redis` Deployment rollback) was not performed — the session operated in read-only mode, so remediation remains unapplied and unverified in a live cluster state.
- Historical/prior incident entries referenced in the Incident Index artifact were not cross-analyzed in detail for this report beyond confirming the artifact update mechanism itself.