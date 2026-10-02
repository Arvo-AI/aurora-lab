## Incident Report

**What Happened**

At 2026-10-02T14:54:35, a high-severity KubeDeploymentRolloutStuck alert fired for the `shop` service, specifically the `api` deployment. The deployment showed READY 2/2 but UP-TO-DATE at only 1 of 2 desired replicas [7]. The new ReplicaSet `api-5f7c48ddc6` (revision 2) had a single pod stuck in `Pending`/`CreateContainerConfigError` and never reached Ready [8, 9, 10]. The prior ReplicaSet `api-f64486c4c` (revision 1) continued running both pods at 1/1 Ready with 0 restarts, continuing to serve traffic throughout [8, 13].

**Root Cause**

The root cause is confirmed: revision 2 of the `api` Deployment introduced a new environment variable, `DB_PASSWORD`, sourced via a non-optional `secretKeyRef` pointing to Secret `api-secrets` [10]. That Secret does not exist anywhere in the cluster — a cluster-wide secret listing returned only an unrelated `kube-system/bootstrap-token-abcdef` entry [18], and a namespace-scoped check confirmed no secrets exist in `shop` [12]. Because the reference is non-optional, kubelet refuses to start the container, producing the persistent `CreateContainerConfigError` and preventing the rollout from ever converging. The Deployment's `last-applied-configuration` annotation contains only `REDIS_HOST`, with no trace of `DB_PASSWORD` or the secret reference, indicating this field was added through an unreviewed imperative edit rather than a tracked apply [14]. Further, the application code in the `api-code` ConfigMap only reads `REDIS_HOST`/`PORT` and never references `DB_PASSWORD` [20], confirming the variable was added prematurely, ahead of an incomplete DB-integration feature whose secret provisioning step was never completed.

**Impact & Timeline**

The rollout stalled roughly 90 seconds after revision 2 was introduced [7, 10], and remained stuck through the time of investigation. Because revision-1 pods remained healthy and continued serving all traffic [8, 13], there was no user-facing outage; the incident is limited to a stuck rollout preventing the deployment from reaching its desired new-revision state.

## Ruled Out
- Cluster/node infrastructure failure — all 3 nodes reported `Ready` [16].
- Image pull failure (e.g., ImagePullBackOff) — `python:3.12-alpine` was already cached on the node and pulls succeeded [8].
- Secret existing in the wrong namespace — cluster-wide secret listing confirmed `api-secrets` does not exist in any namespace, not just `shop` [18, 12].
- Same failure mechanism as prior `shop` incidents — this is a distinct missing-Secret-reference failure, differing from the earlier log-shipper sidecar OOM on `api` [2] and the image-tag typo on `frontend` [6].

## Not Checked
- The correct value for the `db-password` key was not determined — this must come from an engineer or secret manager and was out of scope for this investigation.
- The identity/timing of the imperative edit that introduced the `DB_PASSWORD` env var was not established beyond the annotation evidence [14]; no audit log was available to confirm who made the change.
- Status of the broader DB-integration feature (whether code consuming `DB_PASSWORD` is forthcoming) was not examined, as it falls outside the current rollout failure's scope.