## Incident Report

**What Happened**

At 2026-10-02T21:00:36Z, a high-severity KubeDeploymentRolloutStuck alert fired for the `api` deployment in the `shop` namespace [1]. The deployment showed 2 desired, 0 updated, 2 total, 2 available, 1 unavailable replicas, with a `ReplicaFailure=True` condition (reason `FailedCreate`) [7]. The existing ReplicaSet `api-f64486c4c` continued running 2/2 pods and serving traffic normally, while the new ReplicaSet `api-6d96cc9f88`, created as part of revision 2 of the deployment, remained stuck at 0/1 pods created [7, 8, 14].

**Root Cause**

The root cause was exhaustion of the `shop` namespace's `compute-resources` ResourceQuota (`requests.memory` hard limit of 200Mi), which was already fully consumed (200Mi used / 200Mi hard) by steady-state workloads — `api` (2×32Mi), `frontend` (2×16Mi), `loadgen` (8Mi), `redis` (32Mi), and `worker` (64Mi) [10, 13, 15]. A rollout restart on `deployment/api` (revision 2) triggered creation of a new ReplicaSet [7, 14]. Because the deployment's RollingUpdate strategy (25% max surge / 25% max unavailable) resolves to maxSurge=1 for 2 replicas, the rollout required creating a 3rd, surge pod (32Mi) before removing an old one [7]. With zero headroom in the quota, every attempt by `replicaset/api-6d96cc9f88` to create that pod was rejected by the API server with "exceeded quota: compute-resources, requested: requests.memory=32Mi, used: requests.memory=200Mi, limited: requests.memory=200Mi," confirmed by repeated `FailedCreate` events on the ReplicaSet [8, 10, 14, 15]. This is a confirmed finding, not a hypothesis.

**Impact & Timeline**

The deployment's old ReplicaSet remained healthy throughout, with both `api` pods reporting 1/1 Running and the deployment reporting `Available: True`, meaning there was no service outage [5, 6, 7]. The impact was limited to the rollout being unable to progress: the new ReplicaSet held at 0/1 for the full observed window (events spanning from 95s to 13s prior to investigation), consistent with the alert's "not progressing for >15 minutes" condition [8, 14].

## Ruled Out
- Node capacity or scheduling failure — all nodes reported `Ready` and no `FailedScheduling` events were present [16, 9].
- Image pull issues — the required image (`python:3.12-alpine`) was already present and in use on existing pods, and no image-pull-related events were observed [5, 8].
- Application code defect — the old ReplicaSet using the same image/template continued running without issue, and all failures were quota-rejection events, not application errors [8, 7].

## Not Checked
- Deployment rollout history (`kubectl rollout history`) — blocked by organization read-only policy on mutating/history kubectl operations [12].
- Broader cluster-wide quota or resource pressure outside the `shop` namespace — not examined, as the alert and evidence were scoped to `shop/api` only.
- Historical pattern of quota saturation prior to this incident — no prior incidents or memory entries for `shop/api` rollout issues were found [1, 2, 4], so recurrence trends could not be assessed.