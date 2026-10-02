## Incident Report

**What Happened**

Beginning at 2026-10-02T20:24:01Z, a critical HighErrorRate alert fired for the frontend service in the shop namespace, indicating that 100% of requests to /api/ were returning 5xx errors over a 5-minute window. The loadgen traffic generator confirmed continuous, uninterrupted 502 responses on every `GET /api/items` request from 20:25:27Z onward [18]. Both frontend nginx pods (dgg8q, ktzwl) corroborated this with identical upstream failures, logging `connect() failed (111: Connection refused)` while attempting to reach the api Service upstream at `http://10.96.190.97:8080/items` [14]. The outage affected all frontend-to-api traffic in the shop namespace, with readiness probes on the frontend pods also failing during this window [5].

**Root Cause**

The root cause was a configuration drift on the `api` Service object: its `spec.ports[0].targetPort` was set to 9090, while the api Deployment's containers only expose and listen on port 8080 [17, 13]. This caused kube-proxy to route all Service traffic to pod port 9090, where nothing was listening, resulting in connection refusals that nginx surfaced as 502s [9, 12]. The api pods' own logs confirm the application started cleanly and is listening on `:8080`, and successfully served `/healthz` and `/items` requests directly against pod IP:8080, bypassing the Service [7, 10]. The Service's `kubectl.kubernetes.io/last-applied-configuration` annotation shows it was originally declared with `targetPort: 8080`, matching the container port, indicating the live `targetPort: 9090` was introduced by a direct, out-of-band edit to the Service object after creation rather than being part of its original deployed spec [17].

**Impact & Timeline**

Impact was limited to the shop namespace: all frontend requests proxied through the `api` Service failed with 502 errors from at least 20:24:21Z (first observed nginx error) [14] through the alert evaluation window ending 20:26:05Z, with no indication of recovery in the available logs [18]. All api, frontend, and redis pods remained healthy with 0 restarts throughout, confirming the failure was isolated to Service routing rather than pod-level instability [4, 11, 16].

## Ruled Out

- Node health issues — all three cluster nodes reported `Ready` status [15]
- Resource exhaustion (CPU/memory) — `kubectl top pods` showed trivial usage across api and frontend pods (1-5m CPU, 7-14Mi memory) [16]
- Application/container crash — 0 restarts on all pods; api processes started cleanly and `/healthz` returned 200 continuously when probed directly against pod IP:8080 [7, 10, 4]
- Redis/backend dependency failure — api logs show successful connection to redis at `redis:6379` after one initial retry [7, 10]
- DNS/service discovery failure — Service and Endpoints objects resolved correctly; only the port number in the Endpoints was incorrect [9]

## Not Checked

- The worker pod's `pushgateway:9091` DNS errors were observed but determined to be a separate, pre-existing cosmetic issue unrelated to this alert's causal chain, and were not further investigated [19]
- The actual mechanism or actor responsible for the direct edit to the Service's `targetPort` (e.g., manual kubectl patch, controller, or external automation) was not identified, as no audit log or change history was available in the evidence collected