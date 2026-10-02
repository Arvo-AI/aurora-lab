## Incident Report

**KubeDeploymentRolloutStuck — shop/api (cluster aurora-lab)**

### What Happened

At 2026-10-02T16:30:33, a high-severity alert fired indicating the Kubernetes deployment rollout for the `api` Deployment in the `shop` namespace failed to complete. The Deployment was at revision 2, reporting 2 desired replicas, 1 updated, and 1 unavailable, with its Progressing condition stuck in `ReplicaSetUpdated` [4, 15]. The new ReplicaSet pod `api-5f7c48ddc6-nc8f7` remained in `CreateContainerConfigError` while the two pods from the prior ReplicaSet (`api-f64486c4c-*`) continued running normally [5, 7].

### Root Cause

The root cause was confirmed to be a missing Kubernetes Secret referenced in the updated Deployment template. Revision 2 of the `api` Deployment added a mandatory environment variable `DB_PASSWORD`, sourced via `secretKeyRef` from secret `api-secrets` key `db-password` [13], whereas the previous revision's running pods only defined `REDIS_HOST` with no secret reference [10]. The secret `api-secrets` was never created in the `shop` namespace, and no application secrets exist anywhere in the cluster [8, 12]. As a result, the kubelet could not resolve the secret reference when building the new pod's container spec, producing repeated `Warning Failed ... Error: secret "api-secrets" not found` events (x8 over 82s) [6], which prevented the new ReplicaSet from ever becoming ready and stalled the rollout. Notably, the application source mounted via the `api-code` ConfigMap only reads `REDIS_HOST` and does not reference `DB_PASSWORD` at all [16], indicating the environment variable was introduced into the manifest without a corresponding code dependency.

### Impact & Timeline

Impact was contained: the old ReplicaSet `api-f64486c4c` kept 2/2 pods Running and the Deployment reported `Available: True`, so traffic continued to be served throughout [4, 7, 15]. The new ReplicaSet was created approximately 85–99 seconds before investigation and failed consistently with the same secret-not-found error on a recurring ~10-second cycle, aligning with the alert firing window [6, 7, 9]. The rollout remained actively stuck (not timed out) at the time of investigation, with no resolution applied yet since all mutating `kubectl` operations were policy-blocked in this session [11].

## Ruled Out

- **Image pull failure** — image `python:3.12-alpine` was already present on the node; pod reached container-creation stage, not image-pull stage [6].
- **Resource constraints (OOM/eviction)** — no OOMKilled or Evicted status observed; pod remained in `CreateContainerConfigError`, unrelated to resource limits [5, 6].
- **Node-level issues** — pod was successfully scheduled (`PodScheduled=True`) to node `aurora-lab-worker`, ruling out node unavailability [6].
- **Readiness probe failure** — the pod never reached the running/probe-check stage; it failed earlier at container creation while resolving the secret reference [6].

## Not Checked

- **Rollout history (`kubectl rollout history`)** — blocked by organizational policy on mutating/history commands, so full revision-change history beyond the current spec diff could not be inspected [11].
- **Reason for `DB_PASSWORD` addition / upstream intent** — no record of why the environment variable was added in revision 2 or whether a related code change (e.g., DB migration feature) is pending; this would require follow-up with the owning team.
- **Other namespaces/clusters for a mis-scoped secret** — a cluster-wide secret check was performed and found none, so this was effectively checked and ruled out, not left open.
- **Application runtime logs** — not reviewed, as the failure was isolated to pod-creation stage before any application code executed.