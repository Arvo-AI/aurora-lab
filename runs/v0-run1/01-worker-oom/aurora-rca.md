## Incident Report

**What Happened**

At 2026-10-02T14:40:07, a high-severity KubePodCrashLooping alert fired for the `shop` service's `worker` workload. The pod `worker-86f68b9bf6-t2rwq` was observed in a crash loop, repeatedly terminating with OOMKilled (exit code 137) and entering BackOff [5]. Cluster events show two worker ReplicaSets were created roughly 9 seconds apart immediately prior to the alert: `worker-6cf88d4b58` (revision 1) was scaled up and then down to 0 replicas, while `worker-86f68b9bf6` (revision 2) was scaled up to become the active ReplicaSet [6, 7]. Other `shop` services (api, frontend) were running normally (1/1 Ready) at the time of investigation and were not affected [3].

**Root Cause**

The root cause was a deployment rollout that increased the worker's `BATCH_SIZE` environment variable from 500 to 2500 without a corresponding increase to the pod's 192Mi memory limit [7]. The worker's code allocates `BATCH_SIZE × 100KiB` of buffer per cycle [10]; at BATCH_SIZE=2500 this requires approximately 244MiB, which exceeds the unchanged 192Mi memory limit before accounting for interpreter overhead, resulting in a guaranteed OOMKill on every cycle [10, 7]. This directly explains the observed OOMKilled terminations and restart behavior on `worker-86f68b9bf6-t2rwq` [5]. The prior ReplicaSet (revision 1, BATCH_SIZE=500, same 192Mi limit) remains present in-cluster at 0 replicas and was not garbage-collected, confirming it as a valid, intact rollback target [7].

**Impact & Timeline**

Revision 1 (`worker-6cf88d4b58`) was created at 14:39:07 and scaled down roughly 9 seconds later as revision 2 (`worker-86f68b9bf6`, BATCH_SIZE=2500) was created at 14:39:16 and scaled up [6, 7]. The affected pod subsequently entered a crash loop, with OOMKilled terminations recorded at 14:39:57 and 14:40:40, reaching a restart count of 4 and BackOff status by the time of investigation [5]. The alert fired at 14:40:07, within this crash-loop window. Impact was isolated to the `worker` component of the `shop` service; `api` and `frontend` pods remained healthy and Ready [3].

## Ruled Out

- Node resource pressure / insufficient cluster capacity — node `aurora-lab-worker` showed `MemoryPressure: False` with ~20GB allocatable and only 416Mi committed in limits, indicating ample headroom; the constraint was the pod's own memory limit, not node capacity [9].
- API/frontend "connection refused" readiness events as related cause — these occurred at pod startup and both services were confirmed 1/1 Running shortly after, consistent with normal startup race rather than any worker-related failure [3, 6].

## Not Checked

- Full `worker.py` ConfigMap content could not be retrieved via jsonpath query (empty output), so the complete code logic beyond the known buffer-allocation line was not directly re-verified in this session [8, 10].
- `kubectl rollout history deployment/worker` was blocked by organizational read-only policy, so the deployment's full revision history/annotations could not be directly inspected beyond the ReplicaSet YAML [11].
- No remediation (rollback or memory limit increase) was executed, as mutating kubectl operations are blocked under this session's policy; actual resolution and post-fix validation remain pending engineer action.