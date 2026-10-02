## Incident Report

**What Happened**
A critical "HighErrorRate" alert fired for namespace=shop, service=frontend at 2026-10-02T20:24:46 UTC. At the time of investigation, the shop namespace had just bootstrapped — all pods were Running but only ~73 seconds old, indicating a full cluster/deployment restart [4, 5]. Frontend nginx logs showed continuous `GET /api/items` requests returning 502/503 [7], and the backend `api` pods showed the request pattern `connected to redis at redis:6379` followed by `request failed: redis error: timed out` and `GET /items HTTP/1.0 503` repeating continuously rather than as a one-time startup blip [8].

**Root Cause**
The root cause was a NetworkPolicy named `redis` in the shop namespace, created at 2026-10-02T20:23:54Z, which restricts ingress to redis:6379 to pods labeled `app=worker` only [20, 22]. The `api` pods are labeled `app=api`, not `app=worker` [23], so their connections to redis were silently dropped by the policy, causing the client-side 2-second socket timeout defined in the api code [14] to be hit on every request, producing the `redis error: timed out` → 503 response from the api, which cascaded into 502/503 responses from the frontend's `/api/items` proxy [7, 8]. Redis itself was healthy throughout — clean startup logs, Ready=True, and negligible CPU/memory usage (3m/4Mi) with no error output [10, 11, 12] — ruling it out as the failing component. The first observed 503 occurred within ~2 seconds of the NetworkPolicy's creation timestamp, consistent with (though not independently proof of) the client timeout window configured in the api code [22, 14].

**Impact & Timeline**
The policy was created at 20:23:54Z, shortly after cluster bootstrap, and the alert triggered at 20:24:46Z [20, 22]. Both `api` replicas (api-f64486c4c-2nqsk, api-f64486c4c-mvpnl) [4, 23] were affected, resulting in 100% failure of `/api/items` calls proxied through the frontend service [7, 8]. The issue was ongoing and had not self-resolved as of the time of investigation.

## Ruled Out
- Redis overload or crash — redis-59458f55d8-n6glm showed clean startup logs, Ready=True, and minimal resource usage (3m CPU / 4Mi memory) with no errors [10, 11, 12].
- Node-level resource contention (including worker pod's buffer-allocation churn) — `kubectl top nodes` showed both worker nodes at ~0% CPU and ~1% memory [16].
- Transient startup/readiness probe noise — frontend/api 5xx logs showed continuous, non-improving failures rather than a one-time startup blip [7, 8].

## Not Checked
- Whether the worker pod genuinely requires redis access (its code only allocates and frees buffers, per the api-code configmap) — flagged as a service-owner design question rather than part of the required fix, not independently verified against worker source code beyond what's in the configmap.
- CNI-level or lower-level network diagnostics beyond the NetworkPolicy object itself — not needed once the policy rule was identified as sufficient explanation, and not accessible in read-only mode.
- loadgen pod's traffic pattern/configuration — retrieved as YAML [19] but not analyzed in depth, since the mechanism was already isolated to the NetworkPolicy rule.