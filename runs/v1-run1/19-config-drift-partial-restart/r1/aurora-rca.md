## Incident Report

**What Happened:**
On 2026-10-02, a HighErrorRate alert was triggered at 20:36:20 UTC for the `frontend` service in the `shop` namespace [Alert]. Logs from frontend pod `frontend-76d98597b9-g5zrg` show a sustained pattern between 20:35:45 and 20:38:53 UTC of `/api/items` requests failing with 504 Gateway Timeout due to upstream connection timeouts to `10.96.10.144:8000` [7], while health checks on the same pod continued to succeed every 5 seconds [7]. A second frontend pod, `frontend-76d98597b9-kt2jr`, logged a single transient 502 (connection refused) against upstream `10.96.10.144:8080` at startup (20:35:28), after which all subsequent `/api/items` requests succeeded through 20:39:03 [8]. The load generator client confirms a mixed pattern of timeout/502/200/504 responses to `/api/items` across the affected window [9]. Both frontend pods were otherwise reported as Running with 0 restarts [4, 14, 15].

**Root Cause:**
The most likely cause is a port mismatch between the frontend's configured upstream and the actual backend service endpoint. The `frontend-nginx` ConfigMap defines the upstream as `server api:8000` [13], but the `api` ClusterIP service is actually exposed on port `8080` [6]. This is consistent with the kt2jr pod's single observed failure against port 8080 (the correct service port) resolving quickly [8], while the g5zrg pod's persistent failures were logged against port 8000 (an address with no listener), producing repeated connection timeouts [7] rather than fast refusals. This discrepancy was not fully reconciled — the live nginx configuration inside the running pod could not be inspected to confirm which port it was actually using at the time of each failure, since direct exec access was blocked by policy [10]. The backend `api` pods themselves were reported as Running with no restarts [4], but their logs and resource state were not examined, so intermittent backend unavailability as a contributing factor cannot be ruled out.

**Impact & Timeline:**
The error pattern spanned from pod startup (~20:35:25) through at least 20:39:03 [7, 8, 9], with the alert firing at 20:36:20 [Alert]. One of two frontend replicas (`g5zrg`) continuously returned 504s to `/api/items` callers for the duration of the observed window [7], while the other replica (`kt2jr`) recovered within ~6 seconds of a single startup failure [8]. Both pods and their health endpoints remained available throughout, indicating the user-facing impact was isolated to the `/api/items` route rather than full service outage [7, 8, 14, 15].

## Ruled Out
- Frontend pod crash or instability — both pods show `Running`, `1/1 Ready`, 0 restarts throughout the incident window [4, 14, 15]
- Frontend process/health failure — `/healthz` checks succeeded every ~5 seconds on both pods with no failures [7, 8]
- Complete network partition between frontend and backend — the kt2jr pod successfully reached the backend on port 8080 after an initial failure and sustained 200 responses for ~4 minutes [8, 9]

## Not Checked
- Logs and resource utilization of the `api` backend pods (`api-f64486c4c-5b6s7`, `api-f64486c4c-kllps`) — not retrieved, so backend-side readiness/overload could not be confirmed or excluded
- Live nginx configuration inside the running frontend container — `cat /etc/nginx/conf.d/default.conf` exec was blocked by organizational policy [10], so the actual upstream port in effect at failure time is unverified
- Network policies or service mesh rules between `frontend` and `api` in the `shop` namespace — not examined, no indication from available evidence that this layer was involved