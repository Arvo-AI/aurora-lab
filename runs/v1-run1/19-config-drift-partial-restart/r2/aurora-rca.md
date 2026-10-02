## Incident Report

**What Happened**

At 21:08:48 on 2026-10-02, a high-severity "HighErrorRate" alert fired for the `frontend` service in the `shop` namespace. Live traffic from the in-cluster load generator against `/api/items` showed a continuous mix of 200 and 504 responses from at least 21:08:10 through 21:11:22, with no sign of recovery during that window [9, 24]. The `shop` namespace runs two frontend replicas (`frontend-76d98597b9-rr7xl` and `frontend-76d98597b9-r4thz`) behind a single ClusterIP service, two `api` pods, a `redis` instance, and a `worker` pod [4, 27]. Both API backend pods were healthy throughout, logging only successful 200 responses to the requests they received [8, 10], and cluster resource usage (CPU/memory on all nodes and pods) remained negligible with no restarts [11, 25].

**Root Cause**

The root cause was a misconfigured `frontend-nginx` ConfigMap that pointed nginx's `/api/` upstream at port 8000, while the live `api` Service actually listens on port 8080 [16, 21, 19]. Because nginx only reads this config at container startup and does not hot-reload, the two frontend replicas diverged: `rr7xl`, which started before the bad edit, continued running a working configuration and successfully proxied to the backend, while `r4thz`, which came up after the ConfigMap was changed, mounted the broken config and returned repeated `504 Gateway Timeout` errors on every `/api/items` request due to upstream connection timeouts to `10.96.137.47:8000` [24]. Since the `frontend` Service load-balances across both replicas, roughly half of all client requests failed, consistent with the alternating 200/504 pattern observed by the load generator [9].

**Impact & Timeline**

The error condition began shortly after the second frontend replica (`r4thz`) started with the already-edited ConfigMap and persisted continuously through at least 21:11:22, with 504s recurring every 4–14 seconds against the broken replica [24]. Approximately half of all `/api/items` requests to the `frontend` service were affected, consistent with a 1-of-2 replica split; the other replica (`rr7xl`) and both API backend pods remained fully functional throughout [9, 4, 8, 10].

## Ruled Out
- Resource exhaustion (CPU/memory limits, OOM) — node and pod resource usage negligible across the namespace, no restarts observed [11, 25]
- Redis/worker dependency failure — worker logs show steady processing of 500-item batches with no errors [15]
- Application-level bug in the API service — both `api` pods logged only 200 responses for every request they received, with no errors or 503s [8, 10]

## Not Checked
- `kubectl rollout history deployment/frontend` was blocked by organization policy (mutating-command filter), so prior ConfigMap/revision history could not be independently reviewed [26]
- Direct inspection of the live mounted config file inside the `rr7xl` pod via `exec` was blocked by organization policy, so the "good" replica's config could only be inferred from its logs, not confirmed by file content [20]
- A dedicated `loadgen` ConfigMap does not exist, so load generator configuration could not be reviewed beyond its deployment spec [22]