## Incident Report

**What Happened:**
At 2026-10-02T20:35:48 a high-severity `KubeDeploymentRolloutStuck` alert fired for the `api` deployment in the `shop` namespace. At the time of investigation, the deployment showed revision 2 in a stalled rolling update: 2 desired, 1 updated, 3 total, 2 available, 1 unavailable [9]. The new ReplicaSet `api-77b4b6956f` had 0/1 pods ready [6], with pod `api-77b4b6956f-pkcqj` stuck in `Init:0/1` status [5, 7]. The previous ReplicaSet, `api-f64486c4c`, remained healthy and continued serving traffic at 2/2 ready [5, 6].

**Root Cause:**
The root cause was a manifest change in deployment revision 2 that added a `wait-for-db` init container running `nc -z -w 2 postgres 5432` in a retry loop [14]. This init container has been running continuously since pod creation, repeatedly failing with `nc: bad address 'postgres'` because no `postgres` Service exists anywhere in the cluster [12, 13]. Since the init container never completes, the main `api` container is permanently blocked from starting, which prevents the new ReplicaSet from reaching Ready and stalls the RollingUpdate. This is confirmed as a regression specific to revision 2: the prior, healthy ReplicaSet `api-f64486c4c` has no init containers at all [16], and the application source code (pulled from `configmap/api-code`) only ever connects to `REDIS_HOST` on port 6379, with no Postgres client logic whatsoever [19]. Both ReplicaSet revisions share identical `REDIS_HOST` environment configuration [17, 18], further confirming the Postgres dependency was not part of any intended application change but an erroneous addition to the pod spec.

**Impact & Timeline:**
The rollout stalled shortly after the revision 2 deployment began (pod age ~69-72s at time of inspection) [5, 6]. User-facing impact was limited: the previous ReplicaSet `api-f64486c4c` remained fully healthy and serving all traffic at 2/2 ready throughout [5, 10], with the only effect being loss of surge capacity during the stuck rollout.

## Ruled Out
- Image pull failure — image `python:3.12-alpine` was already present on the node and pulled successfully; pod reached `Pending`→`Init` stage, not `ImagePullBackOff` [7].
- Resource exhaustion / OOM / scheduling failure — pod was successfully scheduled to `aurora-lab-2-worker2` with no node pressure or resource-related events observed [7, 8].
- Readiness probe failure on the application itself — the main `api` container never started (status `PodInitializing`), so the app-level `/healthz` readiness probe was never reached; the blocker is isolated to the init container [7, 12].

## Not Checked
- `kubectl rollout history deployment/api -n shop` was blocked by organization mutating-operation policy, so the full revision change history (e.g., who/what introduced the `wait-for-db` init container) could not be retrieved [15].
- No prior memory entries existed for this deployment/alert pattern, so no historical recurrence data was available to cross-reference [2].
- Direct endpoint/service grep for `postgres` across all namespaces failed due to a command syntax error and was not re-run with corrected flags, though the full `get svc -A` listing [13] was sufficient to confirm no such Service exists.