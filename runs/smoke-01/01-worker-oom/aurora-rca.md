## Incident Report: KubePodCrashLooping — shop/worker

**What Happened**

On 2026-10-02 at 14:31:32, a high-severity KubePodCrashLooping alert fired for the shop service on cluster kind-aurora-lab. The pod worker-86f68b9bf6-4pp6d entered a crash loop, terminating with status OOMKilled and accumulating 3 restarts within roughly 85 seconds before landing in BackOff [6]. Two ReplicaSets for the worker Deployment existed in-cluster during this window — worker-6cf88d4b58 (revision 1) and worker-86f68b9bf6 (revision 2) — with the revision-2 pod created at 14:30:41 [7, 6]. Other workloads in the namespace (api, frontend) were running normally at 1/1 Ready [4].

**Root Cause**

The root cause is confirmed: the worker Deployment's env var BATCH_SIZE was increased from 500 to 2500 [13] without a corresponding increase to the container's 192Mi memory limit [7]. The worker.py code (sourced from ConfigMap api-code) allocates one ~100KiB in-memory buffer per batch item [11], so BATCH_SIZE=500 required ~49MiB (safely under the 192Mi limit), while BATCH_SIZE=2500 requires ~244MiB — exceeding the limit before any interpreter overhead is accounted for. This matches the pod's observed Terminated/OOMKilled state with exit code 137 and the start time of 14:30:41, immediately preceding the restart-driven BackOff state [6].

**Impact & Timeline**

Revision 2 of the worker Deployment was created at 14:30:41; the affected pod accumulated 3 restarts within ~85 seconds and was in BackOff at investigation time, with only 54 seconds elapsed since the most recent OOMKilled restart [6]. The alert fired at 14:31:32, consistent with this restart activity. Impact was isolated to the worker component; api and frontend pods in the shop namespace remained 1/1 Running throughout [4].

## Ruled Out
- Readiness-probe failures on api/frontend pods as the cause of the crash loop — both pods show 1/1 Running with 0 restarts, consistent with normal startup-race behavior rather than an active failure [4].

## Not Checked
- Live memory usage graphs for the worker pod — metrics-server is not available on this kind cluster, so kubectl top could not return data [10].
- Full deployment rollout history — `kubectl rollout history` was blocked by organization policy restricting mutating/history kubectl operations [12].
- Crash-time application logs from the previous container instance — `kubectl logs --previous` could not retrieve logs for the terminated container [8].