## Incident Report: HighErrorRate — shop/frontend

**What Happened**

At 2026-10-02T21:02:06.704098, a high-severity alert fired for elevated error rates on the frontend service in the shop namespace. Frontend nginx pods were confirmed to be actively returning intermittent 500 and 502 responses for `/api/items`, proxied to the upstream api ClusterIP Service at 10.96.255.102:8080 [7, 15]. An early 502 "Connection refused" was observed at pod startup before the backend was fully ready, followed by sustained intermittent 500s during the alert window [7]. All frontend and api pods were otherwise reported as Running with 0 restarts [5].

**Root Cause**

The root cause was a label collision between two unrelated Deployments sharing the `app=api` label. The api Service selects backends purely on `app=api` [6], and its endpoint list included three pods instead of the expected two: 10.244.1.148 and 10.244.2.137 from the legitimate `api` Deployment (2 replicas, created 21:01:01) [11, 13], plus 10.244.2.140 from a separate, unrelated `shop-api` Deployment (1 replica, created 21:01:09, 8 seconds later) [16]. The `shop-api` pod template carries both `app=api` and `app.kubernetes.io/name=shop-api`, causing it to be inadvertently picked up by the api Service's selector [16]. That pod runs a different codebase (`/code/app.py`) which throws `KeyError: 'DATABASE_URL'` on every `/items` request because the `shop-api` Deployment spec never sets a `DATABASE_URL` environment variable [14]. Since kube-proxy round-robins across all three registered endpoints [15], roughly one in three requests to the api Service is routed to the broken pod, producing the intermittent 500s observed at the frontend [7, 14]. The two legitimate `api-f64486c4c-*` pods served 200 responses for every `/items` request logged in the same window, confirming they are healthy and not contributing to the error rate [9, 10, 12].

**Impact & Timeline**

The legitimate `api` Deployment and `frontend` Deployment became ready at approximately 21:01:01–21:01:07 [11, 12], after which 200s were served normally. The unrelated `shop-api` Deployment was created at 21:01:09 and its single pod joined the api Service's endpoint pool shortly after, polluting the load-balancing rotation [16, 15]. The alert fired at 21:02:06, consistent with the broken endpoint being in rotation for roughly a minute prior; live 500s continued to be logged at 21:02:17, 21:02:21, and 21:02:23 at the time of investigation [7].

## Ruled Out
- Redis connectivity failure — healthy api pods log an initial transient connection refusal followed by successful connection ("connected to redis at redis:6379") with no further redis errors in the request path [9, 10, 12].
- Node or resource pressure — all pods show Running status with 0 restarts and no CPU/memory-related events in the namespace event log [5, 17].
- The legitimate `api-f64486c4c-*` pods as the error source — their logs show exclusively 200 responses for `/items` in the window matching the alert [9, 10].

## Not Checked
- Full contents of frontend nginx configuration/upstream retry logic — not retrieved beyond the access log tail, so it's unconfirmed whether nginx has any retry-on-5xx behavior that would mask or amplify the broken endpoint's impact.
- Origin/ownership of the `shop-api` Deployment (who/what created it, e.g. CI/CD pipeline or manual apply) — no deployment history or audit trail was pulled, only the Deployment spec and pod logs.
- Readiness/liveness probe configuration for the `shop-api` pod — not retrieved, so the exact mechanism by which it passed readiness despite crashing on `/items` requests (vs. a separate `/healthz` endpoint) is inferred from logs [14] but not directly verified via probe spec.