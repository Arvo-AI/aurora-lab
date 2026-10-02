## Incident Report

**What Happened**

At 2026-10-02T16:38:22Z, a high-severity KubePodCrashLooping alert fired for the `shop` service. In the `shop` namespace, the api pod `api-5cf6469845-4khjs` (part of ReplicaSet `api-5cf6469845`) was in CrashLoopBackOff with 5 restarts in under 6 minutes, while two older api pods on ReplicaSet `api-f64486c4c` remained Running [4]. The `redis-5fff65475c-t2qf5` pod was stuck in Pending state with no node assigned [4, 8]. The still-Running api pods were actively returning HTTP 503 responses on `GET /items` due to Redis connection failures at the time of investigation [10].

**Root Cause**

This finding is CONFIRMED. The root cause was a PersistentVolumeClaim (`redis-data`) created with `storageClassName: fast-ssd` [14], a storage class that does not exist in this cluster — only `standard` (rancher.io/local-path, default) is present [12]. The PVC remained permanently Pending with a `ProvisioningFailed`/`storageclass ... not found` condition, and the redis pod could not be scheduled as a result (`0/3 nodes are available: pod has unbound immediate PersistentVolumeClaims`) [8, 11]. This left no running Redis backend. The newly rolled api pod, which depends on `REDIS_HOST: redis`, exhausted 5 startup connection retries with `[Errno 111] Connection refused` and exited with code 1, producing the CrashLoopBackOff [5, 6]. The older, still-running api pods — created before the Redis pod was torn down — are also unable to reach Redis and are returning live 503 errors to `/items` requests, confirming the frontend-facing symptom [10].

**Impact & Timeline**

Around 16:37:19Z, the redis Deployment advanced to revision 2 and the api Deployment received a `restartedAt` annotation at the same timestamp, consistent with a coordinated rollout [6, 13]. From that point, the previously-working Redis pod was gone and no replacement could schedule due to the missing storage class [8, 9, 11, 12]. One api pod has been crash-looping continuously since (5 restarts in ~6 minutes as of alert time) [4], and the two surviving api pods are serving active 503 responses on `/items` [10], matching the reported frontend 5xx symptom at the time the alert fired at 16:38:22Z.

## Ruled Out
- Resource exhaustion / OOM as the crash cause — pod terminated with exit code 1 (app-level error), not OOMKilled; no resource-limit events present [6].
- Application code defect in the api service — crash logs show only a clean, explicit "redis unavailable" give-up after 5 retries, with no stack trace or other error [5].

## Not Checked
- Why or by whom the `redis-data` PVC manifest was changed to reference `fast-ssd` — no deployment/CI history beyond the Deployment's revision annotation was available [13].
- Whether other services besides `api` and `frontend` depend on Redis and were impacted — not covered by available evidence.
- Underlying node/storage provisioner health beyond the storage class listing — only `kubectl get storageclass` output was reviewed [12].