## Incident Report

**What Happened**

At 2026-10-02T20:48:01Z, a high-severity KubePodCrashLooping alert fired for the `worker` deployment in the `shop` namespace. The pod `worker-86f68b9bf6-bz2xq`, running on node `aurora-lab-worker2`, was found in a `Waiting` state with reason `CrashLoopBackOff`, with its last terminated state showing `OOMKilled` (exit code 137) and a restart count of 6 [6]. Kubelet events confirmed the container was repeatedly being restarted after failure [6]. Other workloads in the namespace (api, frontend pods) were running normally and unaffected [4].

**Root Cause**

The root cause is confirmed: a configuration change increased the `worker` deployment's `BATCH_SIZE` environment variable from 500 (original revision, retained in ReplicaSet `worker-6cf88d4b58`) [14] to 2500 in the live spec (revision 2, ReplicaSet `worker-86f68b9bf6`) [5]. The worker code loads the entire batch into memory simultaneously, allocating `batch × 100KiB` of buffer space [12]. At `BATCH_SIZE=500` this consumes ~49MiB, comfortably within the container's 192Mi memory limit; at `BATCH_SIZE=2500` it consumes ~244MiB, exceeding the limit and triggering an OOM kill almost immediately after startup, as shown in the pre-crash log line "worker started, batch size 2500" [7] followed by termination with reason OOMKilled [6]. This produces the kubelet restart cycle manifesting as CrashLoopBackOff.

**Impact & Timeline**

Deployment revision 2 was rolled out at 20:47:09Z, scaling ReplicaSet `worker-86f68b9bf6` up from 0 to 1 and replacing the previously healthy revision-1 pod (`worker-6cf88d4b58`, now scaled to 0) [8]. From that point until the alert at 20:48:01Z, the new pod accumulated 6 restarts in approximately 8.5 minutes [6], indicating continuous crash-looping with no successful startup since the config change. Impact is scoped to the single-replica `worker` deployment in `shop`; node-level resources remained healthy throughout [9].

## Ruled Out
- Node-level memory pressure causing the OOM kill — `aurora-lab-worker2` showed only 227Mi/1% memory utilization, far below capacity [9].
- Image pull, scheduling, or volume mount failures — pod events showed `Pulled`, `Created`, and `Started` succeeding each cycle, with OOMKilled as the only failure reason [6].
- A code defect in `worker.py` unrelated to batch size — the logic is deterministic and the only variable affecting memory consumption is `BATCH_SIZE`, with memory math matching the observed limit breach exactly [12].

## Not Checked
- `kubectl rollout history deployment/worker` was blocked by organization policy, so revision metadata beyond what the ReplicaSets and annotations already show could not be independently retrieved [13].
- Whether the `BATCH_SIZE=2500` change was an intentional throughput adjustment or an accidental edit was not confirmed — no deployment audit log or change ticket was available.
- No remediation (rollback or limit increase) was executed, as mutating kubectl operations are blocked by policy in read-only mode.