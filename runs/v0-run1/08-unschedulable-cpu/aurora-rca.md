## Incident Report

**KubePodNotReady — shop/worker**

**What Happened:**
At 2026-10-02T15:18:36, a high-severity KubePodNotReady alert fired for the shop service. Investigation of the namespace showed one pod, worker-7fdf4ffb67-cvrt2 (part of the worker Deployment's revision-2 ReplicaSet), stuck in `Pending` state with `Node: <none>` [4, 6]. All other shop pods — api, frontend, redis, loadgen, and the prior worker revision pod worker-6cf88d4b58-rfbzp — remained in `Running` state [4, 11].

**Root Cause:**
The root cause is confirmed. The live worker Deployment's container `resources.requests.cpu` was set to `"64"` in the cluster, while the Deployment's `last-applied-configuration` annotation and the still-running revision-1 pod both show the intended/working value of `"50m"` [8, 9]. Because the field was not suffixed with `m`, the value was interpreted as 64 whole CPU cores rather than 64 millicores — a roughly 1,280x increase. All three cluster nodes report only 10 allocatable CPUs each, and the control-plane node additionally carries a standard `NoSchedule` taint [12]. As a result, the scheduler could not place the revision-2 pod, producing the `FailedScheduling: 0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient cpu` condition observed on the pod [6], matching the alert exactly.

**Impact & Timeline:**
The outage is limited to the new revision-2 replica of the worker Deployment; the existing revision-1 pod (worker-6cf88d4b58-rfbzp) continued running and processing without interruption throughout [8, 11]. No impact to api, frontend, redis, or loadgen was observed, as those pods remained healthy and Running [4]. The fault is a stuck rollout rather than a service outage.

## Ruled Out
- Node unavailability — all three nodes (aurora-lab-control-plane, aurora-lab-worker, aurora-lab-worker2) reported `Ready` [5, 12].
- Image pull or container configuration error — the pod never progressed past scheduling (`Node: <none>`), so container-level failures could not have occurred [6].
- Control-plane taint as the primary cause — the taint on aurora-lab-control-plane is standard/expected and unrelated to the two schedulable nodes, which failed purely on `Insufficient cpu` [12].
- Secret/ConfigMap misconfiguration (prior incident pattern [2]) — pod did not reach container-start stage, so Secret/ConfigMap resolution was never a factor [6].

## Not Checked
- Memory resource requests/limits were not implicated and not deeply examined beyond confirming they matched between revisions [8] — no symptoms pointed to a memory-related issue.
- Underlying reason the live-edit drift occurred (who/what modified the Deployment outside of `kubectl apply`) was not determined — no audit log or change-tracking tool was available in this investigation.
- The patch to revert `requests.cpu` to `50m` was validated but not applied — mutating kubectl operations are disabled under the current read-only policy, pending an engineer with write access.