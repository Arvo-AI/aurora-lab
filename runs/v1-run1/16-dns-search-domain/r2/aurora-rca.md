## Incident Report

**What Happened:**
At 2026-10-02T21:02:23, a KubePodCrashLooping alert fired for the `shop/api` deployment. The pod `api-779966d57-v8d2r` was observed in `STATUS=Error` with restart count climbing (3 restarts, 34s since last) and `Reason: CrashLoopBackOff` / `Last State: Terminated, Exit Code: 1` [4, 8]. The `shop/api` Deployment had two ReplicaSets active: `api-f64486c4c` (revision 1), fully healthy at 2/2 Running and serving 200 responses on `/healthz` and `/items` [9, 11, 20], and `api-779966d57` (revision 2, the current rollout target), stuck at 0/1 ready and crash-looping [9]. The `api` Service's endpoint list contained only the two healthy revision-1 pods, confirming the crashing pod was excluded from traffic by readiness gating [21].

**Root Cause:**
The root cause was a direct patch to the `shop/api` Deployment that added `dnsPolicy: None` with a custom `dnsConfig` specifying search domains under `cluster.internal` [13, 19], which is not the cluster's actual DNS domain — CoreDNS's authoritative zone is `cluster.local` [17]. This override was present in the live deployment spec but absent from the `kubectl.kubernetes.io/last-applied-configuration` annotation [19], and the prior healthy revision's pod had no such override [14]. Because `dnsPolicy: None` disables fallback to default DNS behavior, pods under revision 2 could not resolve the `redis` hostname, producing `[Errno -2] Name does not resolve` across all 5 connection attempts in the container logs [7]. The application's startup code (`api.py`) calls `socket.create_connection` to Redis, retries 5 times, and calls `sys.exit(1)` on failure [22], which matches the observed Exit Code 1 and resulting CrashLoopBackOff exactly.

**Impact & Timeline:**
The affected pod was created at 2026-10-02T21:01:22 [8] and began crash-looping almost immediately, roughly 90 seconds before alert evaluation. Impact was limited to a stuck/degraded rollout: 1 of 3 desired replicas unavailable under revision 2, while the two revision-1 pods continued serving traffic normally [5, 11, 21]. No full service outage occurred, as the `api` Service's endpoint list remained populated by the healthy old-revision pods throughout [21].

## Ruled Out
- Cluster-wide CoreDNS outage — CoreDNS pods were Running with 0 restarts and 4h45m uptime, and a sibling pod on the same node resolved names and served traffic normally at the same time [15, 11].
- Redis unavailability — the `redis` Service had a healthy endpoint (`10.244.2.59:6379`), and revision-1 pods were actively getting successful responses that depend on Redis connectivity [12, 11].
- Resource/OOM issue — the pod terminated with Exit Code 1 (clean application exit), not 137/OOMKilled, indicating it never reached a resource-throttling condition [8].
- Full user-facing outage — the `api` Service's endpoint list still contained the two healthy revision-1 pods, meaning traffic was still being served despite the degraded rollout [21].
- Application code or image defect — both ReplicaSets ran the identical image (`python:3.12-alpine`) and identical code via the shared `api-code` ConfigMap, so code/image was not the differentiator [5, 22].

## Not Checked
- Full rollout history (`kubectl rollout history deployment/api`) could not be retrieved — blocked by organization read-only policy [6], so the exact sequence/author of prior revisions beyond revision 1 and 2 is not confirmed.
- The specific actor or process that applied the direct patch introducing `dnsPolicy: None`/`dnsConfig` was not identified; only that it is absent from the last-applied-configuration annotation [19].
- Whether the custom DNS config was intended for an unrelated purpose (and merely misconfigured) versus added in error was not determined — this affects whether the rollback or the forward-fix is the more appropriate long-term remediation.