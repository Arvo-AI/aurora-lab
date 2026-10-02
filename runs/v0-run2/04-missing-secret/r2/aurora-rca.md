## Incident Report: KubeDeploymentRolloutStuck — shop

**Paragraph 1 — What Happened**

At 2026-10-02T16:59:18Z, a high-severity alert fired for the `api` Deployment in the `shop` namespace on cluster `kind-aurora-lab`, indicating a stuck rollout [1, 3]. The deployment showed `READY 2/2`, `UP-TO-DATE 1`, `AVAILABLE 2` [4], with the new ReplicaSet `api-5f7c48ddc6` holding one pod in `CreateContainerConfigError` state while the prior ReplicaSet `api-f64486c4c` continued running 2/2 pods [5, 12]. All other workloads in the namespace (frontend, worker, redis, loadgen) were unaffected [6, 16].

**Paragraph 2 — Root Cause**

The root cause was a Deployment spec change (revision 2) that added an environment variable `DB_PASSWORD` sourced from `secretKeyRef: api-secrets/db-password` [9], while the `api-secrets` Secret was never created in the `shop` namespace or anywhere else in the cluster [8, 11]. The new ReplicaSet's pod, `api-5f7c48ddc6-4sb92`, entered `CreateContainerConfigError` with repeated events reporting `Error: secret "api-secrets" not found` [7], preventing it from ever reaching Ready and blocking the RollingUpdate from progressing past the surged replica [4, 5]. Node resource exhaustion was ruled out (all nodes Ready, negligible CPU/memory usage) [15, 16], image pull failure was ruled out (image already present on the node) [5], and readiness-probe flakiness was ruled out as it was observed only on unrelated, now-healthy pods [6].

**Paragraph 3 — Impact & Timeline**

The deployment generation bumped to 2 approximately 97 seconds before the alert fired, coinciding with creation of the stuck ReplicaSet [9, 12]. There was no full service outage: the old ReplicaSet `api-f64486c4c` remained 2/2 Running and continued serving all traffic throughout [5, 12]. Impact was limited to a stalled rollout with reduced redundancy — one extra surged pod stuck in a non-Ready state and the new revision unable to complete deployment [4, 5].

## Ruled Out
- Resource exhaustion / node pressure — all 3 nodes reported Ready, and `kubectl top pods` showed single-digit millicore CPU and low-MB memory usage across all shop pods [15, 16].
- Image pull failure — events confirmed `python:3.12-alpine` was already present on the node for all pods, including the stuck one [5].
- Readiness probe flakiness — prior Unhealthy events belonged to unrelated pods during normal startup, all of which are now 1/1 Running [6].

## Not Checked
- `kubectl rollout history deployment/api -n shop` was blocked by organization mutating-command policy, so full revision history beyond the current generation-2 spec could not be reviewed [10].
- Whether an external secrets manager/vault was ever supposed to populate `api-secrets` was not verifiable beyond confirming no operator pods (external-secrets, sealed-secrets, vault-agent) exist in the cluster [11, 13].
- The correct value for the `db-password` key was not retrieved, as it must come from the team's secrets manager and was out of scope for read-only investigation.