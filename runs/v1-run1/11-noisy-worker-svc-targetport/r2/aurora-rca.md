## Incident Report

**What Happened**

At 2026-10-02T20:46:28 UTC, a critical "HighErrorRate" alert fired for namespace=shop, service=frontend, indicating an elevated error rate on the frontend service. Live nginx logs from pod frontend-76d98597b9-rf92b confirmed every `/api/items` request was failing with HTTP 502 (Bad Gateway) due to `connect() failed (111: Connection refused)` when proxying to upstream `http://10.96.62.168:8080/items` [7]. This failure pattern was continuous and ongoing at the time of investigation, with the most recent log entry at 20:54:32 UTC still showing the same 502/connection-refused signature [14]. All affected deployments (api, frontend) showed pods in Running state with 0 restarts, ruling out a pod-level outage as the visible symptom [4, 6].

**Root Cause**

The root cause was a configuration drift on the `api` Service in namespace shop: the live Service spec had `targetPort: 9090` [13, 15], while the Deployment's container only exposes `containerPort: 8080` [11] and the application code binds to the `PORT` environment variable with a default of 8080, with no override set in the Deployment [9]. The Service's own `kubectl.kubernetes.io/last-applied-configuration` annotation shows it was originally applied with `targetPort: 8080`, confirming 9090 was introduced via out-of-band drift rather than intended configuration [13]. The Endpoints object confirmed kube-proxy was actively routing Service traffic to port 9090 on both backend pod IPs [10], which has nothing listening on it, producing connection-refused errors for every Service-routed request — manifesting as nginx's 502 responses on `/api/` [7, 14].

**Impact & Timeline**

The shop namespace resources (Service, Deployment, pods) were created at 20:45:32 UTC [10, 13], and the targetPort mismatch has caused 100% failure of Service-routed `/api/` traffic from frontend to api continuously since pods became ready, through at least 20:54:32 UTC [14]. Kubelet-direct health checks (bypassing the Service) to both frontend and api pods succeeded throughout this window [7, 8, 12], meaning the user-facing path was fully broken while pod-level health signals remained green — masking the issue from standard pod-health monitoring.

## Ruled Out
- Pod crash / OOMKill / crash loop — all pods Running with 0 RESTARTS across api and frontend deployments [4, 6].
- Transient startup race / readiness probe failure during rollout — api pods served `/healthz` 200 continuously via direct pod-IP kube-probes from startup through the latest log window, with no gaps [8, 12].
- Redis connectivity issue as root cause of API failure — initial Redis connection error at startup self-resolved via retry and did not recur [12].

## Not Checked
- Whether the Service targetPort drift (9090) was caused by a manual `kubectl edit/patch` versus an automated process — no audit log or admission controller history was available in the evidence gathered.
- Health and configuration of the redis, worker, and loadgen deployments — no symptoms or alerts pointed to these components, so they were not examined.
- Network policies or CNI-level restrictions — not relevant given the root cause was isolated to Service port configuration, not network connectivity.
- Actual remediation outcome — the fix was validated but not applied due to read-only session mode; post-fix verification was not performed.