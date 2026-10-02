## Incident Report

**PARAGRAPH 1 — What Happened**

At 2026-10-02T16:26:22Z, a KubePodCrashLooping alert fired for the `api` deployment in the `shop` namespace on cluster `kind-aurora-lab`. Both `api` pods (api-7d4b6f6f7d-5n8h7 and api-7d4b6f6f7d-g95qf) were observed in a 1/2 READY, OOMKilled state with 3 restarts within roughly 70 seconds of pod age [4]. The `api` deployment reported 0/2 AVAILABLE despite 2 pods being up-to-date [5], meaning the service had no available replicas at the time of investigation.

**PARAGRAPH 2 — Root Cause**

The root cause was a deployment rollout that added a `log-shipper` sidecar container to the `api` pods with an undersized memory limit. The sidecar's startup command explicitly allocates a 40MB `bytearray` buffer [6], but its container memory limit was set to 16Mi (request 8Mi) [6] — less than half of what the process needs to even start, guaranteeing an OOMKill (exit code 137) on every startup attempt. Comparing ReplicaSets confirms this was newly introduced: the prior ReplicaSet `api-f64486c4c` (109s old) contained only the `api` container, while the current ReplicaSet `api-7d4b6f6f7d` (102s old) contains both `api` and `log-shipper` [10, 5]. The `api` container itself remained healthy with 0 restarts, isolating the crash loop to the sidecar [6]. Node-level memory pressure was ruled out, as all three cluster nodes showed 0–3% memory utilization [9].

**PARAGRAPH 3 — Impact & Timeline**

The deployment age at the time of investigation was 75 seconds, with the new ReplicaSet (including the sidecar) at 102 seconds old and the prior ReplicaSet at 109 seconds old [5, 10], indicating the sidecar was introduced immediately before the alert fired. Both `api` pods have been continuously crash-looping since the rollout, with the deployment showing 0/2 available replicas for the duration of the incident [5].

## Ruled Out

- Node-level memory pressure / cluster resource exhaustion — all nodes showed 0–3% memory utilization [9].
- Failure in the main `api` container — confirmed healthy with Ready: True and 0 restarts [6].
- Pre-existing/historical issue — no matching past incidents or org memory found for "shop" [1, 2].

## Not Checked

- `kubectl rollout history deployment/api` — blocked by organization policy on mutating kubectl operations in this read-only session [8]; ReplicaSet comparison was used as a substitute to confirm the change.
- Application-level logs/behavior of the `log-shipper` sidecar beyond its startup command — no indication additional log review was needed given the deterministic OOMKill mechanism was already confirmed [6].
- Frontend and worker deployments — no symptoms reported for these components; investigation scope was limited to the `api` deployment per the alert [4].