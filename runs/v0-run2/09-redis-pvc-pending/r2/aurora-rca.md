## Incident Report

**Service:** shop | **Severity:** High | **Alert:** KubePodCrashLooping | **Triggered:** 2026-10-02T17:09:42Z

### What Happened

Beginning at approximately 17:08:31–17:08:40Z, the `redis` and `api` Deployments in the `shop` namespace both advanced to revision 2 [10, 11]. The `redis` pod was terminated and its replacement failed to schedule, leaving zero Redis pods running in the namespace [13, 18]. The new `api` pod (`api-5fbff7bdd4-2nzhk`) entered CrashLoopBackOff with 3 restarts within 74 seconds [4, 7]. The two pre-existing `api` pods (`api-f64486c4c-*`) remained in a Ready (1/1) state but began failing live requests [4, 14]. Frontend-facing traffic to `/api/items` returned continuous HTTP 503 responses from 17:09:25Z through at least 17:11:04Z, as recorded in loadgen logs [15].

### Root Cause

The root cause was a configuration change that added a PersistentVolumeClaim (`redis-data`) to the `redis` Deployment referencing `storageClassName: fast-ssd` [11], a StorageClass that does not exist in this cluster — only `standard` is defined [12]. The PVC was left in `Pending` state with a `ProvisioningFailed` event confirming the missing StorageClass [13, 18]. Because the `redis` Deployment uses a strategy that terminates the old pod before the replacement can schedule, this change took Redis fully offline. The `api` container's startup code treats Redis connectivity as a hard dependency, retrying 5 times before exiting with code 1 [8, 9], which produced the observed CrashLoopBackOff on the new `api` pod [7, 8]. The older, already-Ready `api` pods continued passing health checks but failed every real request due to per-request Redis calls, logging `redis error: [Errno 111] Connection refused` paired 1:1 with 503 responses [14], which is the mechanism by which frontend traffic experienced 5xx errors despite "healthy" pod status [4, 14, 15].

### Impact & Timeline

Impact was confined to the `shop` namespace: `/api/items` returned 503 continuously for at least ~1 minute 40 seconds (17:09:25Z–17:11:04Z) during active investigation [15], with no indication of resolution in the evidence collected. One of three `api` pods was in active CrashLoopBackOff [4], and the single `redis` replica was unschedulable [13, 18], leaving the service with no functioning cache/data-layer backend for the affected endpoint.

## Ruled Out
- Node resource exhaustion — no OOM or Evicted events observed; nodes and pods otherwise reported healthy [5].
- Image pull failures — API image was already present on the node and pulls succeeded (no ImagePullBackOff events noted in pod description) [7].
- Network policy blocking Redis traffic — connection failures returned `Connection refused` (no listener), not a timeout, which is inconsistent with a firewall/network-policy block and consistent with Redis simply not running [8, 13, 18].

## Not Checked
- `kubectl rollout history` for both `redis` and `api` Deployments could not be retrieved — blocked by organization policy on mutating kubectl operations [16, 17], so the exact prior-revision config and who/what triggered revision 2 could not be confirmed.
- Previous-container logs for the crashing `api` pod were unavailable (`unable to retrieve container logs`) [6], so only the current crash iteration's logs were analyzed.
- Full `kubectl get events` output was truncated [5]; any additional scheduling or provisioning events beyond those shown were not reviewed.
- No remediation (PVC storageClassName patch or PVC removal) was executed, as both require mutating kubectl operations blocked under current read-only policy.