## Incident Report

**What Happened:**
At 2026-10-02T16:32:40, a KubePodCrashLooping alert fired for the `api` service in the `shop` namespace on cluster kind-aurora-lab. The `api` deployment's pods were observed in a repeating restart cycle, with the restart counter increasing from 1 to 2 within roughly 90 seconds of observation [9]. This followed a rollout from ReplicaSet `api-f64486c4c` (rev 1) to `api-c7b987b4d` (rev 2) [5, 6]. Other workloads in the namespace — frontend, redis, worker, and loadgen — remained in a stable Running state with 0 restarts, confirming the impact was isolated to the `api` deployment [4].

**Root Cause:**
The root cause is confirmed: the `api` Deployment's livenessProbe was configured to check port 8081 [6], while the application only ever listens on port 8080, as shown in its startup logs ("api listening on :8080") and continuous 200 responses on `/healthz` and `/items` [7], and confirmed by the application source in the `api-code` ConfigMap, which binds only to the `PORT` env variable (default 8080) with no secondary listener [12]. The deployment's own `last-applied-configuration` annotation shows the liveness probe was originally set to port 8080 as well, indicating the live spec drifted from the originally applied configuration via a direct edit or patch [6]. As a result, kubelet repeatedly failed liveness checks against the dead port and killed the container with exit code 137 approximately every 45–70 seconds [10], producing the "crash loop" pattern reported in the alert.

**Impact & Timeline:**
Impact was limited to the `api` deployment's two pods, both of which cycled through Running → Killed → Restarted states, with restart counts climbing in real time during the observation window [4, 9]. The readinessProbe (port 8080) continued to pass throughout, and the application remained functionally healthy and serving traffic between kills, meaning end-user impact was likely limited to brief connection interruptions during each restart cycle rather than a full outage.

## Ruled Out
- **OOMKilled container** — memory usage measured at 11–14Mi against a 128Mi limit, far below any memory pressure threshold [11].
- **Redis dependency failure** — logs show successful connection to redis:6379 and continued 200 responses on `/items` [7].
- **Node or cluster-wide instability** — all 3 nodes reported Ready, and only the `api` deployment was affected while frontend, redis, worker, and loadgen ran normally [13, 4].
- **Application-level crash** — pod termination reason was "Error" with exit code 137 (kubelet-initiated SIGKILL from failed liveness probe), not an application fault; logs show the app serving traffic right up until termination [10, 7].

## Not Checked
- **Rollout history / prior revisions** — `kubectl rollout history` was blocked by organizational policy restricting mutating-adjacent operations, so it could not be confirmed whether a clean prior revision exists to roll back to [8].
- **Prior incident/memory history for shop/api** — no existing incidents or memory entries were found, so there is no historical pattern to compare against for this service [1, 2].
- **Who/what introduced the probe port drift** — the evidence confirms the live spec differs from the last-applied-configuration, but the specific change event (manual edit vs. patch) that caused the drift was not identifiable from available read-only data.