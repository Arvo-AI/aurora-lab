## Incident Report

**What Happened**

At 2026-10-02T15:08:06 UTC, a high-severity "KubePodCrashLooping" alert fired for the shop/api service. At the time of investigation, both api replicas (api-c7b987b4d-d8vj8 and api-c7b987b4d-wtmf8) were in a Running/Ready (1/1, 2/2) state but actively restarting on a roughly 60–70 second cadence, with Restart Count climbing (1–2 restarts within 2–3.5 minutes of pod age) [4, 7, 13]. "Killing" events for the api container were logged within 30–40 seconds of the investigation [6, 7, 13]. No other workloads in the namespace (frontend, worker, redis, loadgen) showed restarts, and all three cluster nodes were Ready [5, 12].

**Root Cause**

The root cause is confirmed. The live `api` Deployment specification has `livenessProbe.httpGet.port` set to 8081, while the `readinessProbe` correctly targets port 8080 [7, 8, 13]. The application code in the `api-code` ConfigMap binds `ThreadingHTTPServer(("", PORT), H)` with `PORT` defaulting to 8080, and no `PORT` environment override is set in the pod spec [9]. As a result, every liveness check to port 8081 receives a connection refused, and kubelet repeatedly kills and restarts the container (exit code 137) once the probe's failure threshold is reached — exactly matching the observed ~60-70s restart pattern [7, 13]. The Deployment's `kubectl.kubernetes.io/last-applied-configuration` annotation shows the originally applied/reviewed liveness port was 8080, matching the readiness probe and the app's actual listening port [8], indicating the live object's port value was changed to 8081 outside of a tracked `kubectl apply`.

**Impact & Timeline**

Pods for api started around 15:06 UTC, with the alert triggering at 15:08:06 UTC after restarts began accumulating [4, 7, 13]. Impact was isolated to the two api replicas; readiness checks on port 8080 continued to succeed throughout, so the service was not fully down but was cycling under repeated container kills [7, 13]. No other services in the shop namespace were affected [5, 6].

## Ruled Out
- OOMKill as the restart cause — container `Last State` shows `Terminated, Reason: Error`, not OOMKilled, and memory usage remained under the 128Mi limit with no OOM events in pod describe or namespace events [7, 13, 6].
- Recurrence of the prior log-shipper sidecar OOM incident (e68e36c8) — that sidecar container does not exist in the current single-container api pod spec [7, 13, 2].
- Node or cluster resource pressure — all three nodes report Ready status [12].
- Application or Redis-level failure — readiness probe on port 8080 succeeds (`Ready: True`); only the misdirected port-8081 liveness probe fails [7, 13, 9].
- Broader namespace impact — frontend, worker, redis, and loadgen deployments show 0 restarts and remain healthy [5, 6].

## Not Checked
- Resource usage metrics via `kubectl top pods` — Metrics API was not available in this cluster, so memory/CPU consumption could not be directly measured [11].
- Identity/timing of who or what process changed the live liveness probe port from 8080 to 8081 — no audit log or change-tracking data was available beyond the last-applied-configuration diff [8].
- Revision 1 ReplicaSet (`api-f64486c4c`) probe configuration — referenced as a comparison point but its full spec was not retrieved in this evidence set [10].