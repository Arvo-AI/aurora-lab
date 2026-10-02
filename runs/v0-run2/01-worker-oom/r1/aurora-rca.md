## Incident Report

**Paragraph 1 — What Happened**
At 2026-10-02T16:26:04Z, a high-severity KubePodCrashLooping alert fired for the shop service. The worker pod worker-86f68b9bf6-hgxwz in namespace shop entered CrashLoopBackOff after being OOMKilled, accumulating a restart count of 4, with Kubernetes events showing repeated "Back-off restarting failed container worker" [6]. The crash immediately followed a deployment rollout in which ReplicaSet worker-6cf88d4b58 was replaced by worker-86f68b9bf6, bumping the deployment to generation/revision 2 [7]. Other workloads in the namespace (api, frontend, loadgen, redis) remained healthy and running with low memory usage throughout [4, 11].

**Paragraph 2 — Root Cause**
The root cause was a drifted environment variable on the worker deployment: the live spec sets BATCH_SIZE=2500, while the kubectl.kubernetes.io/last-applied-configuration annotation — reflecting the last tracked apply — shows BATCH_SIZE=500, indicating an out-of-band change (e.g., kubectl set env/patch) was made outside normal deployment tracking [7]. The worker code allocates `BATCH_SIZE × 100KiB` of memory per cycle [10], so at BATCH_SIZE=2500 this amounts to roughly 244MiB, exceeding the container's 192Mi memory limit confirmed via pod describe [6]; at the originally intended BATCH_SIZE=500 this would be ~49MiB, safely under the limit. This mismatch between live config and tracked config, combined with the OOMKilled/Exit Code 137 termination reason observed on the pod [6], confirms the kernel OOM killer terminated the container due to the oversized in-memory batch allocation — not an application-level crash or cluster-wide resource shortage, as other pods on the same node remained healthy [4, 11].

**Paragraph 3 — Impact & Timeline**
Impact was isolated to the shop/worker pod, which was repeatedly OOMKilled and cycling through CrashLoopBackOff beginning around the time of the ReplicaSet swap (generation 1→2) roughly 70 seconds before the alert triggered, with restarts climbing to 4 by the time of investigation [6, 7]. No other shop namespace workloads (api, frontend, redis, loadgen) showed degraded resource usage or restarts [4, 11].

## Ruled Out
- Application-level code crash/exception — pod termination reason was Exit Code 137 (SIGKILL from OOM), not an application error [6].
- Cluster-wide or node-level resource pressure — kubectl top pods shows api, frontend, redis, and loadgen all healthy with low memory usage; only the worker container's own limit was breached [11, 4].
- Readiness probe warnings on frontend/api during startup — transient and unrelated, as those pods became Ready shortly after and remained Running [4].

## Not Checked
- kubectl rollout history for deployment/worker — blocked by organization policy restricting mutating kubectl operations, so the exact author/timestamp of the out-of-band env var change could not be retrieved [8].
- Previous container logs for worker-86f68b9bf6-hgxwz — unavailable ("unable to retrieve container logs"), so direct log-level confirmation of the OOM event sequence inside the container was not obtained [9].
- Prior incident history or memory entries for this failure signature — none existed prior to this investigation, so no related past occurrences could be cross-referenced [2].