## Incident Report

**What Happened:**
At 2026-10-02T16:37:43, a KubePodNotReady alert fired for the shop service after the worker pod worker-7fdf4ffb67-h89dz remained in a Pending state for over 5 minutes, with no node assigned [6]. This pod was part of a RollingUpdate to the worker Deployment, which created a new ReplicaSet revision at 16:36:47 [9]. All other pods in the shop namespace (api, frontend, loadgen) were Running and Ready during this period [4], and all three cluster nodes were in Ready status [7, 8].

**Root Cause:**
The root cause was a resource misconfiguration introduced in the worker Deployment's revision 2 rollout: the new pod template requested cpu: "64" (64 whole CPU cores) instead of a millicore value [6, 9]. Every node in the cluster has only 10 allocatable CPUs [7, 8], so no node could ever satisfy this request, producing the FailedScheduling event "0/3 nodes are available: 1 node(s) had untolerated taint(s), 2 Insufficient cpu" [6]. The sibling pod worker-6cf88d4b58-wcqmk, running the prior revision, requests only cpu: "50m" and is healthy [13], confirming the oversized value is a misconfiguration rather than a legitimate resource need. The Deployment's live spec shows cpu: "64" while the kubectl.kubernetes.io/last-applied-configuration annotation still records the original cpu: "50m" [9], indicating the change was applied out-of-band (e.g., via kubectl edit or patch) rather than through a tracked configuration update.

**Impact & Timeline:**
The rollout stalled with the Deployment at 1/2 ready replicas: the old ReplicaSet (worker-6cf88d4b58) continued running and serving traffic, while the new pod (worker-7fdf4ffb67-h89dz) remained perpetually Pending and unschedulable [6, 9, 11]. This represents partial degradation (reduced worker capacity) rather than a full outage, and the condition would not self-resolve without manual intervention to correct the resource request or roll back the deployment.

## Ruled Out
- Node health / resource exhaustion — all three nodes reported Ready with low CPU utilization (3–9%), ruling out capacity or node-health issues as the cause [7, 8].
- Cluster-wide capacity shortage — allocatable CPU on worker nodes was only lightly used, confirming ample capacity existed for a correctly-sized request [8].
- Application bug in worker container — the old revision's pod (same image/command, correct resource request) ran healthily, isolating the issue to the resource specification change rather than application code [13].
- Readiness-probe failures as the cause — other transient "Unhealthy" probe warnings on api/frontend pods were normal startup behavior and unrelated to the worker Pending symptom [4].

## Not Checked
- Deployment rollout history (`kubectl rollout history`) — blocked by organization read-only policy, so the exact author/method of the out-of-band edit could not be confirmed [10].
- Execution of remediation commands (`kubectl set resources`, `kubectl rollout undo`) — both are mutating operations blocked under current read-only policy; validated as viable but not performed.
- Audit logs or access records identifying who made the manual edit to the Deployment — not available in the evidence gathered, so the source of the out-of-band change remains unidentified.