## Incident Report

**What Happened:**
At 2026-10-02T20:24:25 a high-severity KubePodCrashLooping alert fired for the `shop/worker` deployment. The pod `worker-86f68b9bf6-jr2kk` was observed in a 0/1 Running-but-crashing state driven by repeated OOMKilled terminations (Exit Code 137) under a 192Mi container memory limit [6]. Kubernetes events showed continuous Warning/BackOff activity for the pod, and the restart count was actively climbing across checks, indicating the crash loop was occurring in real time rather than as a past incident [6, 8]. Other workloads in the `shop` namespace (api, frontend) remained healthy and unaffected [5, 14].

**Root Cause:**
The root cause was a configuration change introduced in deployment revision 2 of `worker`, which raised the `BATCH_SIZE` environment variable from 500 to 2500 while leaving the 192Mi memory limit unchanged [9, 10]. The worker code allocates roughly 100KiB per batch item (`buf = [bytearray(100*1024) for _ in range(batch)]`), so at BATCH_SIZE=500 memory usage stayed near ~49MiB, comfortably under the limit, but at BATCH_SIZE=2500 the same logic requires ~244MiB — exceeding the 192Mi cgroup limit before any interpreter overhead is added [11]. Pod logs confirm the container started with `"worker started, batch size 2500"` and was immediately killed, consistent with an allocation-time OOM on the first batch [15]. The crash loop began immediately upon the revision-2 ReplicaSet scaling up as the revision-1 ReplicaSet scaled to 0, with no intervening gap [8, 9].

**Impact & Timeline:**
Impact is confined to the `worker` deployment in the `shop` namespace, which has been unable to run a stable replica since the revision-2 rollout; the pod has restarted repeatedly (observed restart count increasing across checks ~45s apart) [6]. Node-level resources were unaffected throughout: both cluster nodes showed 1-4% memory utilization and no MemoryPressure condition [13, 16, 17].

## Ruled Out
- Node-level memory exhaustion / noisy-neighbor eviction — `kubectl top nodes` showed 1-4% memory utilization cluster-wide, and `describe node aurora-lab-2-worker2` reported `MemoryPressure: False` with only 2% of memory limits committed [13, 16].

## Not Checked
- Full rollout history of the `worker` deployment — `kubectl rollout history` was blocked by organizational policy restricting mutating/history kubectl operations [12].
- Prior container logs for the crashing pod — `--previous` log retrieval failed due to a containerd error, so only the most recent crash cycle's logs were available [7].
- Historical incident/memory records for this namespace or workload — no prior matching incidents or memory entries were found, so recurrence patterns could not be assessed [1, 2, 4].