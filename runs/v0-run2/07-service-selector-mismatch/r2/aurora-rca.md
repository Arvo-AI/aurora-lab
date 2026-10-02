## Incident Report

**Paragraph 1 — What Happened:**
On 2026-10-02 at 17:04:43 UTC, a HighErrorRate alert fired for the "shop" service in cluster kind-aurora-lab, indicating 5xx errors on frontend requests despite all pods reporting healthy status. Frontend nginx pods (frontend-76d98597b9-fgsvz and frontend-76d98597b9-prwfr) logged a successful initial request to /api/items followed by continuous 502 Bad Gateway responses starting at 17:03:57–17:03:59, with nginx repeatedly logging connect() failed (111: Connection refused) against upstream http://10.96.250.20:8080/items [10, 11]. This pattern persisted through the end of available logs (17:05:26–17:05:40) with no recovery [10, 11]. The affected endpoint, service/api (ClusterIP 10.96.250.20:8080), showed zero Endpoints despite two api pods reporting 1/1 Running/Ready with 0 restarts [4, 6, 8].

**Paragraph 2 — Root Cause:**
The root cause was a selector mismatch on the api Service: its live spec.selector was set to app: api-v2, while the Service's own last-applied-configuration annotation (the originally intended manifest) specifies app: api [7]. All running api pods carry only the label app=api [8, 9], so the Service matched zero pods, leaving endpoints/api empty [6]. This caused kube-proxy to refuse every connection to the ClusterIP 10.96.250.20:8080, which frontend's nginx proxy surfaced to clients as 502 errors on /api/* [10, 11]. No api-v2 Deployment or pods exist anywhere in the cluster [13, 14], ruling out an in-progress canary/blue-green cutover and confirming this is unexplained configuration drift rather than an intentional change.

**Paragraph 3 — Impact & Timeline:**
The api Deployment scaled up from 0 to 2 replicas at approximately 17:03:41 (67s before the events query) [5], with pods becoming Running at 17:03:48 [4, 12]. Frontend pods started at 17:03:50 [10, 11], and the first /api/items request succeeded before 502 errors began at 17:03:57–17:03:59 [10, 11] — within seconds of pods starting, consistent with the Service selector being broken from the moment traffic began flowing. The outage was ongoing and unresolved at the time of investigation (log entries through 17:05:40) [11], affecting all /api/items traffic routed through the frontend, including automated polling from client IP 10.244.2.121.

## Ruled Out
- Pod crash, OOM, or resource exhaustion — all 7 pods in shop Running/1/1 Ready with 0 restarts [4, 8, 9, 12]
- Backend pod/application failure (e.g., api process not listening) — pods healthy and Ready, issue isolated to Service routing layer [4, 8, 12]
- Intentional canary/blue-green cutover to an api-v2 workload — no api-v2 Deployment or pods exist anywhere in the cluster [13, 14]
- Prior/recurring incident pattern for shop — no matching incidents or memory entries found [1, 2]

## Not Checked
- Underlying reason the Service selector was changed to app: api-v2 (e.g., audit logs, who/what applied the out-of-band edit) — not available in current evidence set
- Redis and loadgen service health — no symptoms pointed to these components, investigation scoped to frontend/api failure path
- Actual remediation effect of patching the Service selector — patch was validated but not executed due to read-only session policy