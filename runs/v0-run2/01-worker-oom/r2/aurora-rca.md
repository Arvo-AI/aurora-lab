## Incident Report: KubePodCrashLooping — shop/worker

**Paragraph 1 — What Happened:**
At 16:52:27 UTC on 2026-10-02, a high-severity KubePodCrashLooping alert fired for the shop service. The worker pod worker-86f68b9bf6-thj65 was found in CrashLoopBackOff with repeated restarts [4], while all other shop pods (api, frontend, redis, loadgen) remained healthy and in Running state [4]. Cluster events show the worker Deployment rolled from ReplicaSet worker-6cf88d4b58 to worker-86f68b9bf6 at 16:51:35 UTC [5, 7, 12], immediately followed by crash cycling on the new pod.

**Paragraph 2 — Root Cause:**
The root cause was an out-of-band change to the worker deployment's BATCH_SIZE environment variable from 500 to 2500 [10], confirmed by pod logs showing the container started with batch size 2500 [6]. Per the api-code ConfigMap's worker.py logic, memory usage scales as batch × 100KiB, meaning BATCH_SIZE=2500 requires ~244MiB while the container's memory limit is 192Mi [8, 10]. This caused the kubelet to OOMKill the container (Exit Code 137) on each cycle, producing the observed CrashLoopBackOff [7]. The deployment's last-applied-configuration annotation still reflects BATCH_SIZE=500, while the live spec shows 2500 [10], indicating the value was modified directly against the cluster (e.g., via `kubectl set env`/`edit`) without a corresponding apply, triggering the revision-2 rollout and subsequent OOM failures.

**Paragraph 3 — Impact & Timeline:**
Impact was isolated to the single-replica worker deployment in the shop namespace; api, frontend, redis, and loadgen pods were unaffected [4]. The rollout to the new ReplicaSet occurred at 16:51:35 UTC [7], with the pod reaching 4 restarts within approximately 3 minutes of the alert firing [4], consistent with an OOMKill-driven crash loop recurring roughly every 90 seconds.

## Ruled Out
- Node-level memory exhaustion / cluster capacity issue — kubectl top nodes showed both worker nodes at <5% memory utilization (159Mi and 198Mi) [11], ruling out cluster-wide resource pressure.
- Non-worker service involvement — all other shop pods (api, frontend, redis, loadgen) confirmed Running with 0 restarts [4].
- Prior/recurring incident pattern — no matching historical incidents or memory entries found for this signature [1, 2].

## Not Checked
- Full rollout history of the worker deployment — `kubectl rollout history` was blocked by organizational policy on mutating/read-restricted operations [9], so the exact actor/method of the BATCH_SIZE change could not be directly confirmed beyond the annotation mismatch.
- Live container logs beyond the previous terminated instance — only `--previous` logs were reviewed [6]; current-cycle logs were not separately inspected since the crash signature was already confirmed via describe pod [7].
- Downstream effects on dependent systems (e.g., queue backlog consumed by worker) — no symptoms indicated impact beyond the worker pod itself, so this was not investigated.