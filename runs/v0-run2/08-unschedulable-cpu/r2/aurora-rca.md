## Incident Report

**What Happened**

At 2026-10-02T17:05:07 UTC, a high-severity KubePodNotReady alert fired for the `shop` service on cluster `kind-aurora-lab`, indicating one or more pods were not ready. The affected pod, `worker-7fdf4ffb67-n2mn9`, belonging to the `worker` Deployment's new ReplicaSet, remained in `Pending` state and failed to schedule onto any node [4, 6]. All three cluster nodes were otherwise healthy and reporting `Ready=True` with no memory, disk, or PID pressure [5, 8]. The previous ReplicaSet's pod, `worker-6cf88d4b58-2l75l`, continued running normally, and all other workloads in the namespace (api, frontend, redis) were unaffected [4, 10].

**Root Cause**

The root cause was a resource request misconfiguration on the `worker` Deployment: the live spec requested `cpu: 64` (64 whole CPU cores) for the pod container, whereas every worker node in the cluster has only 10 allocatable CPU cores [8], making the request impossible to satisfy on any node. The pod's scheduling failure event explicitly confirms `0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient cpu` [6]. Comparison of the Deployment's live spec against its own `kubectl.kubernetes.io/last-applied-configuration` annotation shows the intended/recorded value was `50m` (0.05 CPU), consistent with every other pod in the namespace [9]. This indicates the live spec was modified directly against the cluster (e.g., via `kubectl edit`/`patch`/`set resources`), bypassing the normal apply flow and introducing the erroneous `64` core value in place of `50m`/`64m` [9].

**Impact & Timeline**

Only the new ReplicaSet (`worker-7fdf4ffb67`) pod was impacted; it remained unschedulable and growing in age from the moment of creation through the time of alerting [4, 6]. The old ReplicaSet (`worker-6cf88d4b58`) continued serving traffic normally with its correctly-sized `50m` CPU request [4], so no full service outage occurred — the rollout of the new revision was blocked rather than the `worker` service being fully down.

## Ruled Out
- **Node health/capacity exhaustion from legitimate load** — all nodes reported `Ready=True` with no MemoryPressure/DiskPressure/PIDPressure; allocatable CPU per node is a fixed 10 cores, making this a structural request-size issue, not transient contention [5, 8].
- **Control-plane taint causing scheduling failure** — the control-plane node's `NoSchedule` taint is standard/expected and not newly introduced; it accounts for only one of three nodes being excluded, not the "Insufficient cpu" failures on the other two [8].
- **Preemption resolving the scheduling conflict** — the scheduler explicitly reported preemption was "not helpful for scheduling" on all nodes [6].
- **Historical/recurring pattern for this service or cluster** — no prior incidents found for `shop` or `kind-aurora-lab` in incident history or memory [1, 2].

## Not Checked
- **Identity/source of the direct cluster edit** — no audit log or `kubectl` command history was available to confirm who or what process set `cpu: 64` on the live Deployment spec.
- **Other namespaces/clusters** — only `kind-aurora-lab` is connected and only the `shop` namespace showed symptoms, so no broader scan was performed [3, 4].
- **Full rollout/event history prior to revision 2** — only the current Deployment spec and recent events were reviewed; earlier revision history was not examined [7, 9].