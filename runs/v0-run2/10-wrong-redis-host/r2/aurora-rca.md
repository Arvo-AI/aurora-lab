## Incident Report

**What Happened**

At 2026-10-02T17:10:15Z, a high-severity KubePodCrashLooping alert fired for the shop service. In the shop namespace, pod api-869d87b484-chjfx was found in CrashLoopBackOff with 4 restarts and an age of 2m40s [4]. This pod belongs to a new ReplicaSet, api-869d87b484 (deployment revision 2), which was created at 17:09:12 as part of a rolling update [7, 8]. The Deployment's rollout was stalled, with the new ReplicaSet unable to reach ready state (1 desired, 0 ready) while the previous ReplicaSet, api-f64486c4c (revision 1), remained fully healthy at 2/2 Running [10, 4].

**Root Cause**

The root cause was a configuration change in the new pod template: REDIS_HOST was set to `redis-master` in revision 2, whereas the known-good value in the still-running revision 1 pods is `redis` [11, 8]. The shop namespace's Service list shows only `api`, `frontend`, and `redis` — no `redis-master` Service exists [9]. As a result, pods from the new ReplicaSet fail DNS resolution for the Redis host, as confirmed in the crashing pod's previous logs: five consecutive "Name does not resolve" connection failures followed by "giving up: redis unavailable," terminating with exit code 1 [6, 7]. This is an application-level failure, not resource exhaustion — all api pods report 11-12Mi memory usage against a 128Mi limit [15], and crash exit code 1 is inconsistent with an OOMKill (137) [7]. Node health and image availability were also ruled out as contributing factors [13].

**Impact & Timeline**

The new ReplicaSet (revision 2) was created at 17:09:12 [7, 8], and the alert triggered shortly after at 17:10:15 once the crash loop pattern was established (4 restarts within 2m40s) [4]. Service availability for shop/api has not been fully lost: the old ReplicaSet's 2 pods, still configured with the correct REDIS_HOST=redis, remain Running and continue serving traffic [10, 11], while the rollout to revision 2 remains blocked with 1 unavailable replica.

## Ruled Out
- Resource exhaustion / OOMKill — all api pods using 11-12Mi against a 128Mi limit; crash exit code is 1, not 137 [15, 7].
- Node/cluster instability — all nodes report Ready status [13].
- Image pull failure — python:3.12-alpine image already present/pulled successfully for all pods [10].

## Not Checked
- Full rollout history for deployment/api — `kubectl rollout history` was blocked by organizational policy restricting mutating/history kubectl operations [12].
- Contents of the api-code ConfigMap — the jsonpath query returned no output, so application-level configuration beyond the env var could not be reviewed [14].
- Cluster-wide or historical memory of similar incidents — no prior matches found for "shop" in memory at the time of initial lookup [2].