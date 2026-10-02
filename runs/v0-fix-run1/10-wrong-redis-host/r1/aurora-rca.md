## Incident Report

**What Happened**

At 2026-10-02T21:19:23 UTC, a KubePodCrashLooping alert fired for the `api` deployment in the `shop` namespace, running on the `kind-aurora-lab` cluster. The newly deployed ReplicaSet pod `api-869d87b484-nl62z` entered a crash loop, accumulating 3 restarts within 79 seconds and sitting in `Error`/`CrashLoopBackOff` state [4, 7]. The prior ReplicaSet's pods (`api-f64486c4c-cjnrg`, `api-f64486c4c-ztvkl`) remained healthy and `Running` (1/1) throughout [4]. Pod logs from the crashing container show the process exhausting 5 retry attempts to connect to Redis before exiting with a DNS resolution failure [6].

**Root Cause**

The root cause is confirmed. Deployment `api` revision 2 — the latest rollout referenced in the alert — set the pod environment variable `REDIS_HOST=redis-master` [10], but the only Redis Service present in the `shop` namespace (and cluster-wide) is named `redis` [8, 11]. The revision-1 pods, still running and serving traffic, use the correct value `REDIS_HOST=redis` [9]. The application's startup logic (`api.py`) requires a successful Redis connection, retrying 5 times before calling `sys.exit(1)` on failure [16]; this matches the observed `[Errno -2] Name does not resolve` errors and exit code 1 seen in the crashing pod's logs [6, 7].

**Impact & Timeline**

The faulty revision 2 rollout began shortly before the alert fired, with the new pod reaching 3 restarts within 79 seconds of creation [4]. Because the deployment uses a rolling strategy, revision-1 pods remained in service and continued handling traffic via the `api` ClusterIP service [4, 8], so the `shop` service was degraded rather than fully down. The rollout itself was stuck, unable to reach full availability due to the new pod's repeated failures [4, 7].

## Ruled Out
- Node-level failure — all 3 cluster nodes reported `Ready` status [14].
- Resource exhaustion / OOM — `api` pods were using 13-14Mi against a 128Mi memory limit, far below capacity [15].
- `redis-master` being an alternate/renamed service elsewhere in the cluster — a full `get svc -A` scan across all namespaces found no such service [11].

## Not Checked
- Health and configuration of other `shop` services (`frontend`, `worker`, `loadgen`, `redis` pod itself) — no symptoms indicated impact beyond the `api` deployment [5, 15].
- Underlying reason the `REDIS_HOST` value was changed in revision 2 (e.g., source of the manifest change, CI/CD pipeline, or manual edit) — rollout history only records revision metadata, not change authorship [12, 13].