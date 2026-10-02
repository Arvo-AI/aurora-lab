## Incident Report: HighErrorRate — shop service

**Paragraph 1 — What Happened:**
On 2026-10-02 at 16:36:00 UTC, a high-severity "HighErrorRate" alert fired for the `shop` service. Frontend nginx pods were intermittently returning 502 Bad Gateway errors when proxying `/api/items` requests to the backend upstream at `10.96.89.40:8080` (the ClusterIP for the `api` Service), with nginx logging `connect() failed (111: Connection refused)` [7]. A load-generating client (`10.244.1.14`) polling `/api/items` received repeated 502 responses from 16:35:06Z onward, with only a single successful 200 response at 16:35:12Z before failures resumed and persisted continuously through at least 16:36:35Z [9]. The frontend's own health endpoint remained healthy throughout (`/healthz` returning 200 to kube-probe) [7], and both backend API pods were confirmed `Running`/`Ready` with 0 restarts [4, 13].

**Paragraph 2 — Root Cause:**
The root cause was a label/selector mismatch on the `api` Service in the `shop` namespace: the Deployment and its pods are labeled `app=api` [13, 18], but the Service had no matching backend endpoints, as confirmed by `kubectl get endpoints api -n shop` returning `<none>` and the associated EndpointSlice showing `endpoints: null` [10, 15, 17]. With zero registered endpoints, kube-proxy had no backend to route ClusterIP traffic to, causing connections to `10.96.89.40:8080` to be refused — surfaced by nginx as 502 errors to clients [7, 9]. No competing `app=api-v2` workload was found to justify an intentional selector pointing elsewhere [19], indicating the selector configuration itself does not currently align with the running pods [13, 16, 18].

**Paragraph 3 — Impact & Timeline:**
The Service, Deployment, and pods were all created at approximately 16:35:04Z [18, 20], and loadgen traffic began failing at 16:35:06Z, just two seconds later, continuing almost uninterrupted (one transient 200 at 16:35:12Z) through 16:36:35Z, the most recent log entry at investigation time [9]. The alert triggered at 16:36:00Z, consistent with this ongoing failure window [9]. Impact was isolated to `/api/items` traffic routed through the frontend-to-api path; the frontend, Redis, and loadgen components themselves remained healthy and were not the source of the errors [7, 8, 11, 12, 22].

## Ruled Out
- Resource exhaustion / OOM on API or frontend pods — `kubectl top pods` showed negligible CPU and memory usage across all pods [22]
- Pod crash or restart loop on backend API — both API pods showed 0 restarts and `Ready: True` [4, 13]
- Redis dependency failure causing request errors — the `redis connection failed (attempt 1/5)` message was a transient startup race, immediately followed by `connected to redis at redis:6379`; unrelated to the 502s, which occur before requests reach application logic [8, 11, 12]
- Node or cluster capacity/scheduling issues — all nodes reported `Ready` status [21]
- Frontend/nginx misconfiguration — nginx started normally and its `/healthz` endpoint consistently returned 200; failures were isolated to proxying toward the backend upstream [7]
- Intentional targeting of a separate `api-v2` workload by the Service selector — no pods exist with label `app=api-v2` [19]

## Not Checked
- Whether the `api` Service selector was ever correctly configured for `app=api` prior to this incident, or when/how it diverged — no deployment history or manifest diff was reviewed
- The proposed selector patch fix was not applied or validated live, as mutating `kubectl patch` operations were blocked under read-only session policy
- Ingress-layer routing was not examined in depth beyond confirming no Ingress resources exist in the namespace [6]
- Audit logs or change history identifying who/what modified the Service selector were not available for review