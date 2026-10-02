## Incident Report

**HighErrorRate [warning] — namespace=shop, service=frontend**

### What Happened
At 20:29:54 on 2026-10-02, a high-severity HighErrorRate alert was triggered for the frontend service in the shop namespace [1]. Frontend nginx access logs showed repeated 500 responses on `/api/items`, interleaved with successful 200 responses, at a rate consistent with the alert's reported 31% 5xx error rate [8]. The core shop stack (frontend, api, redis) had come up at 20:28:54 [17], and the frontend pods were running normally at the infrastructure level, with no node or resource issues observed [22, 23].

### Root Cause
The root cause has been confirmed. The `api` Service in namespace shop selects pods using only the label `app: api` [17]. A separate Deployment, `shop-api`, was created at 20:29:03 — 9 seconds after the core stack came up [16] — with pod template labels `app: api, app.kubernetes.io/name: shop-api` [16], causing its single pod (`shop-api-69f6fc5964-jhzz8`, IP 10.244.1.40) to be inadvertently pulled into the `api` Service's endpoint pool alongside the two legitimate `api` Deployment pods [13, 14, 18]. The `shop-api` application code calls `os.environ["DATABASE_URL"]` on every `/items` request [20], but no `DATABASE_URL` environment variable or Secret exists anywhere in the namespace [19], so every request routed to this pod throws `KeyError: 'DATABASE_URL'` and returns HTTP 500, confirmed directly in the pod's logs [15]. With 1 of the 3 load-balanced endpoints behind `api` failing 100% of the time, roughly one-third of frontend `/api/` requests fail, matching the alert's reported error rate [8, 13, 15].

### Impact & Timeline
The core stack (frontend, api, redis) was created at 20:28:54 [17]; the colliding `shop-api` Deployment was created 9 seconds later at 20:29:03 [16], and the alert fired at 20:29:54 [1]. Impact was confined to the shop namespace's `/api/items` endpoint as consumed through the frontend, with approximately 31–33% of requests to that path returning HTTP 500 for the duration of the incident [8, 13, 15]. The two legitimate `api` pods served `/items` with 200 responses throughout [10, 11].

## Ruled Out
- Redis connectivity issues — both legitimate `api` pods logged successful connections to `redis:6379` and served `/items` with 200 responses consistently [10, 11].
- Node/resource exhaustion — all nodes were in Ready state and pod CPU/memory usage was negligible (1–3m CPU, <15Mi memory) across the namespace [22, 23].
- Frontend/nginx misconfiguration — nginx logs show correct proxying behavior to the upstream `api` service, consistent with a backend-side failure rather than a routing defect [8].

## Not Checked
- The deployment/CI process that introduced the `shop-api` Deployment was not examined; only its resulting manifest and labels were inspected [16], so how or why the colliding label was introduced is not established.
- Whether other Services in the cluster have similar selector/label collision exposure was not checked; this incident is isolated to the `api` Service [17, 18].
- Historical/prior incidents involving this pattern were not found in memory, as no existing entries matched prior to this investigation [2].