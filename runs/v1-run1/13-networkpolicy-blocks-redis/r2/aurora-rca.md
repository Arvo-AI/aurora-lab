## Incident Report

**HighErrorRate [critical] namespace=shop service=frontend**

### What Happened

At 2026-10-02T20:50:47Z, a critical alert fired for an elevated error rate on the frontend service in the shop namespace. Load generator traffic showed a continuous, unbroken stream of `GET /api/items` requests returning 503 Service Unavailable from 20:53:19 through at least 20:56:35 [8], and the frontend pod's access logs confirmed every proxied request to `/api/items` failed with 503 while kube-probe health checks on `/healthz` continued to return 200 OK throughout the same window [6]. All 7 pods in the shop namespace, including frontend, api, redis, and worker, were in a Running 1/1 state with 0 restarts at the time, with the namespace having been deployed roughly 6-7 minutes earlier [4, 5].

### Root Cause

The root cause was a NetworkPolicy misconfiguration that blocked the api pods from reaching Redis. The api pod logs show `request failed: redis error: timed out` immediately preceding every 503 response on `/items` [7]. Redis itself was healthy, with a clean startup log, Ready status, 0 restarts, and correctly populated Service/Endpoints (10.244.2.55:6379) [9, 10, 13]. The api deployment's `REDIS_HOST` environment variable correctly pointed to the `redis` service name [12], ruling out a configuration typo. The NetworkPolicy named `redis` in the shop namespace, however, restricts ingress on port 6379 to pods matching `app=worker` only [14], while api pods are labeled `app=api` [16] — a label not covered by the policy's selector — causing the CNI to silently drop connections from api to redis. This is corroborated by the worker pod, which carries the allowed `app=worker` label and successfully processed Redis-backed batches during the same period [17], confirming Redis was reachable and functioning for permitted callers, isolating the fault to the overly narrow ingress rule.

### Impact & Timeline

The namespace and its workloads, including the NetworkPolicy, were created within the same ~1 minute window around 20:49-20:50 UTC [4, 5, 14]. From that point forward, 100% of `/api/items` requests failed with 503 errors, as reflected in the alert and the continuous 503 stream observed from 20:53:19 to 20:56:35 [8]. Frontend and backend pods remained otherwise healthy and stable (0 restarts) for the duration, indicating the issue was a connectivity block rather than a pod-level failure [4, 6, 7].

## Ruled Out
- Frontend pod crash/misconfiguration — all 7 pods Running 1/1, 0 restarts, only transient startup-race readiness probe failures in events, no sustained failures [4, 5].
- Redis down, unhealthy, or overloaded — pod Running, Ready=True, 0 restarts, clean startup log, Service/Endpoints correctly populated [9, 10, 13].
- Redis misconfiguration on the api side (wrong host/service name) — `REDIS_HOST=redis` matches the actual service name `redis` [11, 12].
- General Redis unreachability — worker pod, which is permitted by the NetworkPolicy, successfully processed Redis-backed batches during the same window [17].

## Not Checked
- Underlying CNI plugin logs/configuration — NetworkPolicy enforcement was inferred from label/selector mismatch rather than direct CNI drop-counter evidence.
- Historical NetworkPolicy change history/audit log — not available, so it cannot be confirmed whether `app=api` was ever covered previously or was excluded since initial deploy.
- Frontend-to-api service path and any additional policies on the `api` or `frontend` Services — no symptoms pointed to issues beyond the confirmed redis NetworkPolicy block.