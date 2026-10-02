## Incident Report

**What Happened:**
At 16:55:13 UTC on 2026-10-02, a high-severity `KubePodCrashLooping` alert fired for the `shop` service's `api` deployment [1]. Both running `api` pods (`api-7d4b6f6f7d-d68bn` and `api-7d4b6f6f7d-sbf8m`) were observed in a `1/2 Ready, OOMKilled` state with 3 restarts within roughly 70 seconds [4]. The `api` deployment's ReplicaSet `api-7d4b6f6f7d` showed 2 desired/2 current pods but 0 ready [9], and the deployment could not reach minimum availability as a result.

**Root Cause:**
The root cause was a newly introduced `log-shipper` sidecar container added in deployment revision 2 of `api` [7], which allocates a buffer during startup far exceeding its configured memory limit of 16Mi [6, 7]. This mismatch causes an immediate out-of-memory condition on every container start, resulting in repeated `OOMKilled` terminations (exit code 137) [4, 6]. The primary `api` container in the same pods remained healthy and ready throughout [6], confirming the crash loop originates solely from the sidecar; however, because both containers share a pod, the pod as a whole never becomes Ready, preventing the deployment from satisfying its minimum replica availability [4]. The previous ReplicaSet, `api-f64486c4c`, which runs only the single `api` container without `log-shipper`, remains present and healthy (1/1 Ready) [9], confirming this is a regression introduced by revision 2 rather than an environmental or node-level change.

**Impact & Timeline:**
The crash loop began immediately following the revision 2 rollout and has affected both replicas of the `api` deployment in the `shop` namespace, leaving the deployment without sufficient available replicas since the rollout [4, 9]. The prior revision's ReplicaSet remains intact and ready, indicating no loss of the previously stable pod [9].

## Ruled Out
- Node resource pressure or node-wide issue — all nodes reported `Ready`, and sibling workloads (redis, frontend, worker, loadgen) on the same worker nodes were running normally [10].
- `api` container itself crashing — the `api` container showed `Restart Count: 0` and `Ready: True` in both affected pods [6].
- Readiness-probe-triggered restarts — restart events were explicitly tied to `OOMKilled` on the `log-shipper` container, not probe failures [4, 6].

## Not Checked
- Full rollout history (`kubectl rollout history deployment/api`) could not be retrieved — command blocked by organization mutating-operation policy [8].
- `log-shipper` container's previous logs could not be retrieved from the container runtime, limiting visibility into its exact failure output beyond the OOM/exit-137 signal [11].
- No prior incident pattern for this service/sidecar was found in memory prior to this investigation, so historical recurrence could not be assessed [2].