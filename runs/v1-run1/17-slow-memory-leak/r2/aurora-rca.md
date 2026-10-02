## Incident Report

**What Happened:**
At 2026-10-02T21:08:04, a high-severity KubePodCrashLooping alert fired for the `worker` deployment in the `shop` namespace. Pod `worker-64bddfdcf-8x9rs` started at 21:04:56 and was terminated at 21:07:16 (Exit Code 137, OOMKilled), with Restart Count 1 recorded on describe [9]. The container's previous-run logs show it processed 28 batches of 500 items before dying [7]. At time of investigation the pod had already restarted and was 76 seconds into a second run, with `kubectl top` showing memory at 79Mi and climbing [12]. The `shop` namespace, including the `worker` deployment and its replicaset `worker-64bddfdcf`, was observed to be freshly scaled up (~3.5 minutes prior to the alert) [5, 6].

**Root Cause:**
The root cause was a memory leak in the worker application code. The ConfigMap `api-code` containing `worker.py` shows a `recent` list intended as a bounded "tail of recent batches," but the code only ever calls `recent.extend(buf[-50:])` inside the main loop and never trims the list [10]. Each 5-second batch cycle appends roughly 5MB to `recent` with no cap, causing unbounded memory growth. This matches the deterministic 28-batch crash point observed in the previous run's logs [7] and the live, climbing memory usage (79Mi and rising) seen in the current run shortly after restart [12]. The configured memory limit of 192Mi (request 64Mi, confirmed via pod describe) [9] is being exceeded by this unbounded growth rather than by a one-time spike or undersized baseline.

**Impact & Timeline:**
The `worker` deployment has been crash-looping since the namespace was scaled up roughly 3.5 minutes before the alert, with the deployment rolling from replicaset `worker-6cf88d4b58` to `worker-64bddfdcf` within 9 seconds of initial creation [6]. The affected pod completed one full OOM cycle (21:04:56–21:07:16, ~2m20s) [9] and was in the early stage of a second identical cycle at the time of investigation [12]. Other workloads in the namespace — `api`, `frontend`, `redis`, and `loadgen` pods — were running normally with low, stable memory usage [12], indicating the impact is isolated to the `worker` deployment.

## Ruled Out
- Node-level resource pressure / noisy neighbor — other pods on the same node (`api`, `redis`) show no memory pressure and remain healthy [12].
- External traffic spike causing resource exhaustion — `loadgen` is a flat-rate generator and other dependent services (`redis`, `api`, `frontend`) remain low-memory and healthy [12].
- Insufficient baseline memory sizing — the pod runs successfully for the first ~15–28 batches before failing, and the current run shows live, ongoing growth from a low starting point rather than an immediate failure [12, 7].

## Not Checked
- Deployment rollout history (`kubectl rollout history deployment/worker`) — blocked by organizational read-only/mutating-operation policy [11].
- Prior incident or memory-based pattern matching — no matching historical incidents or memory entries were found for this signature [2, 3].
- Application of either validated fix (ConfigMap patch or memory limit increase) — both require mutating operations currently blocked under read-only policy, so remediation has not been applied or verified in-cluster.