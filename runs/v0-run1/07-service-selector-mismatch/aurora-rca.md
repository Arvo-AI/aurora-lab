## Incident Report

**What Happened**

At 2026-10-02T15:13:44, a HighErrorRate alert was triggered for the `shop` service. Frontend nginx logs show continuous 502 responses for `/api/items` and other `/api/*` requests, with errors recurring on every load-generator request from 15:13:01 onward, including a live example at 15:14:11 referencing connection refused errors to upstream `10.96.35.67:8080` [7]. At the time of the alert, all pods in the `shop` namespace — including both `api` pods and both `frontend` pods — were reporting `Running` with zero restarts [5, 14].

**Root Cause**

The root cause was a selector mismatch on the `api` Service in the `shop` namespace. The Service's live selector was `app=api-v2` [10, 12], but both running `api` pods carry the label `app=api`, and no pod anywhere in the cluster carries the label `app=api-v2` [13, 14, 17]. As a result, the Service had zero endpoints [11], causing kube-proxy to refuse all connections to the ClusterIP and producing the 502 errors seen in the frontend nginx logs [7]. The Service's `kubectl.kubernetes.io/last-applied-configuration` annotation confirms it was originally applied with selector `app: api`, matching the Deployment's pod template label [15, 16], indicating the live selector was changed via an untracked edit after initial deployment rather than being the intended configuration.

**Impact & Timeline**

All `/api/*` traffic proxied through the frontend was affected from at least 15:13:01 through the time of alert triggering and evidence collection, with 502 errors returned on every request [7]. The `frontend` and `redis` Services retained healthy endpoints throughout [11], confirming the outage was isolated to the `api` Service's routing path rather than a broader namespace failure.

## Ruled Out
- Pod crash or OOM — all `api` and `frontend` pods show `RESTARTS: 0` and `STATUS: Running` [5, 14]
- nginx configuration error on frontend — ConfigMap present and nginx startup/access logs show clean operation aside from the 502 upstream errors tied to the missing endpoints [7, 9]
- api application bug — `/healthz` endpoint returns 200 consistently inside the pod, and app logs are clean apart from a transient initial redis-connect retry that succeeded [8]
- Redis connectivity issue — initial connection failure was transient and resolved on retry, with no recurring errors [8]

## Not Checked
- Deployment rollout history for the `api` Deployment was not retrievable (`kubectl rollout history` blocked by mutating-kubectl policy) [18], so the exact timing/actor of the selector edit could not be confirmed
- Audit logs or RBAC records identifying who performed the live `kubectl patch/edit` on the Service selector were not available in the evidence collected