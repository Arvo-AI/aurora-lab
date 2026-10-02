## Incident Report

**What Happened**

At 2026-10-02T14:44:30 a high-severity KubePodCrashLooping alert fired for the shop service's `api` Deployment in the `aurora-lab` cluster. Two pods, `api-7d4b6f6f7d-m29sh` and `api-7d4b6f6f7d-ng552`, were observed at 1/2 Ready with STATUS=OOMKilled and 3 restarts within ~55-57 seconds of pod start [5]. The `api` application container in each pod remained healthy (Running, Ready: True, 0 restarts), while a second container, `log-shipper`, was repeatedly Terminated with Reason OOMKilled, Exit Code 137 [7]. The Deployment's status showed 3 desired replicas with only 1 ready and 2 unavailable, failing its minimum-availability condition [8, 14]. All other shop namespace workloads (frontend, worker, redis, loadgen) remained healthy with 0 restarts [5].

**Root Cause**

The root cause is confirmed. A rollout to revision 2 of the shop/api Deployment introduced a new `log-shipper` sidecar container that is not present in the prior revision 1 ReplicaSet (`api-f64486c4c`, which contains only the single `api` container) [8, 11]. The `log-shipper` container's startup code immediately allocates a 40 MB in-memory buffer, as confirmed by its own log output ("buffering 40 MB before first flush") [12], against a configured container memory limit of only 16Mi [7]. This oversized allocation relative to the limit causes the kubelet to OOMKill the container on every start (Exit Code 137, Restart Count 3) [7], placing the pod's `log-shipper` container into a crash loop that keeps the overall pod at 1/2 Ready and the Deployment below its minimum-availability threshold — the mechanism directly responsible for the KubePodCrashLooping alert [8, 14]. The primary `api` application container is unaffected by this condition [7].

**Impact & Timeline**

Of the Deployment's 3 desired replicas, 2 pods (`api-7d4b6f6f7d-m29sh`, `api-7d4b6f6f7d-ng552`) running revision 2 are actively crash-looping with 1/2 Ready status, while a third pod on the prior revision 1 ReplicaSet (`api-f64486c4c-fkwbq`) remains fully healthy at 1/1 Ready [5, 14]. Because the `api` application container itself continues to serve traffic in all pods, including the two affected ones, user-facing impact is likely limited to reduced capacity/redundancy rather than full service outage, though the Deployment cannot reach its desired replica count until remediated [7, 8].

## Ruled Out
- Node-level resource pressure — all 3 cluster nodes report Ready status [13], and other pods scheduled on the same nodes (frontend, worker, redis, loadgen) show 0 restarts and stable Ready status [5].
- Application/Redis-level failure in the `api` container — the `api` container itself is Running, Ready: True, with 0 restarts, indicating the application logic and its dependencies are functioning normally [7].

## Not Checked
- Historical recurrence of this failure pattern — no prior matching incidents were found in memory [2], so this appears to be a first occurrence (now recorded for future detection [15]).
- Prior crash iteration logs for `log-shipper` — the `--previous` log retrieval failed (container logs unavailable from containerd) [10], so only the most recent crash's log line [12] could be confirmed.
- Cluster-wide metrics (e.g., precise memory usage over time) — no metrics-server is installed on this cluster, limiting analysis to `kubectl describe` OOM status rather than live memory graphs [3].
- Direct remediation — both validated fixes (raising the `log-shipper` memory limit, or rolling back to revision 1) were blocked by read-only policy enforcement and were not applied in this session; an engineer with write access is required to execute either fix.