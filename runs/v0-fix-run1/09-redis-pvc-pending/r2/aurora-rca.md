## Incident Report

**What Happened**

At 2026-10-02T21:24:34Z, a KubePodCrashLooping alert fired for the `shop` service in the `kind-aurora-lab` cluster. The `api-555b75dff9-j8jlp` pod was observed in CrashLoopBackOff with 3 restarts in 73 seconds, while two older api pods (`api-f64486c4c-h4xsh`, `-zzvfh`) remained in a Running/Ready state [4]. The crash-looping pod's logs show five consecutive failed Redis connection attempts followed by a fail-fast exit (`giving up: redis unavailable`), confirmed as an Exit Code 1 termination [6, 7, 13]. At the same time, the `redis` Service had zero backing endpoints [12, 14], and the `redis-5fff65475c-5drtc` pod was stuck in Pending due to an unbound PersistentVolumeClaim [11]. Live frontend nginx logs between 21:24:54–21:26:03Z show every `/api/items` request returning 503 across both frontend replicas [15], and the two "Running" api pods were also failing all real `/items` requests with Redis connection errors despite passing their `/healthz` readiness probe [13, 15].

**Root Cause**

The root cause is confirmed. The `redis` Deployment was rolled to revision 2, which added a `redis-data` PersistentVolumeClaim bound to a `storageClassName: fast-ssd` [10, 11]. The cluster only has the `standard` (rancher.io/local-path) StorageClass; `fast-ssd` does not exist, so the PVC could never bind and provisioning failed [9, 11]. Because the redis Deployment uses the `Recreate` strategy, the previously-working revision-1 redis pod (no volumes, confirmed via rollout history) was deleted before the replacement could become ready, leaving zero running redis pods and an empty `redis` Service endpoint list [14, 16, 17]. All api replicas depend on Redis per-request and on startup; this caused 503s on every `/items` call from the "healthy" api pods [13, 15] and caused any api pod that restarted (via a `restartedAt` annotation applied at 21:23:31Z [7]) to crash-loop on its eager Redis startup check [6, 7, 13]. The api Deployment itself is unchanged between revisions 1 and 2 aside from the restart annotation [8, 19, 20], ruling out an application code or image change as a contributing factor.

**Impact & Timeline**

Redis events show the PVC provisioning failure and pod deletion at 21:23:58Z [5], closely aligned with the api pod restart annotation timestamp of 21:23:31Z [7] and the alert trigger at 21:24:34Z. At the time of investigation (21:24:54–21:26:03Z), the outage was active and ongoing: all `/api/items` requests from both frontend replicas returned 503 [15], and the api tier had no functioning path to Redis [12, 14].

## Ruled Out
- **API code/image change caused the crash loop** — rollout history for api revisions 1 and 2 show identical pod specs aside from a `restartedAt` annotation [8, 19, 20].
- **Redis is only degraded, not fully down** — `kubectl get endpoints redis` returned `<none>`, confirming zero backing pods for the Service [12, 14].
- **Persistent storage/data loss risk from the failed PVC** — the revision-2 redis pod never started due to the PVC remaining Pending, so no data was ever written to it [11].

## Not Checked
- Underlying reason the `fast-ssd` StorageClass was referenced in the revision-2 manifest (e.g., who/what applied the change) — no deployment/CI history or change-cause metadata was available (`CHANGE-CAUSE: <none>` for both revisions) [16].
- Persistent Volume inventory — `kubectl get pv` returned no output, so no cluster-wide PV state could be reviewed beyond the single pending PVC [11, 18].
- Broader cluster health beyond the `shop` namespace — only `shop`-scoped resources were queried; no evidence was gathered on other namespaces or nodes.