## Incident Report

**What Happened**
On 2026-10-02 at 16:26:45 UTC, a high-severity `KubeDeploymentRolloutStuck` alert fired for the `shop` service on cluster `kind-aurora-lab` [1, 3]. The `frontend` Deployment in namespace `shop`, created at 16:25:42 UTC and currently on revision 2, showed READY 2/2, UP-TO-DATE 1, AVAILABLE 2 — indicating the rolling update could not complete [5, 10]. The new pod `frontend-7b6c998456-phg6r`, scheduled onto node `aurora-lab-3-worker`, remained in a Pending/ImagePullBackOff state while the two pods from the prior ReplicaSet `frontend-76d98597b9` continued running and serving traffic [6, 7, 8].

**Root Cause**
The root cause is confirmed: the frontend Deployment's revision 2 spec references container image `nginx:1.27-alpne`, a typo missing the "i" in "alpine" [5, 8]. Kubelet repeatedly failed to resolve this reference, logging "docker.io/library/nginx:1.27-alpne: not found" against pod `frontend-7b6c998456-phg6r` [7]. Direct comparison of the two ReplicaSets confirms the prior, healthy ReplicaSet `frontend-76d98597b9` uses the valid tag `nginx:1.27-alpine` with 2/2 pods ready, while the new ReplicaSet `frontend-7b6c998456` uses the broken tag and has 0 ready replicas [8]. The corrected tag was independently validated as pullable, returning HTTP 200 from the Docker Hub registry API [12], and is already running successfully in production on the old ReplicaSet [8].

**Impact & Timeline**
There was no user-facing outage: Kubernetes' RollingUpdate strategy (maxUnavailable 25%) correctly preserved the two healthy old pods, keeping the Deployment Available [10]. The impact was limited to a frozen rollout — stuck at 1 of 2 desired replicas updated — and reduced redundancy, with 3 total pods in the namespace (one permanently failing) [5, 10]. The Deployment was created at 16:25:42 UTC, with the broken ReplicaSet scaled up shortly after and failing image pulls continuously since [7, 10].

## Ruled Out
- Node health issues — all 3 cluster nodes reported `Ready` status [11].
- Resource exhaustion / quota issues — pod resource requests were trivial (50m CPU/16Mi mem, 64Mi mem limit); no eviction or quota evidence found [10].
- Scheduling failure — the failing pod was successfully scheduled to a node (`PodScheduled: True`); only the image pull step failed [7].

## Not Checked
- `kubectl rollout history deployment/frontend -n shop` could not be run — blocked by organization policy on mutating kubectl operations, so the full revision diff/history was not reviewed directly [9].
- No application-layer or downstream service impact assessment was performed, as the alert and evidence were scoped to the Deployment/ReplicaSet/pod level only.