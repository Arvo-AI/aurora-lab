## Incident Report

**Service:** shop | **Severity:** High | **Alert:** KubePodCrashLooping | **Triggered:** 2026-10-02T21:19:09Z

### What Happened

At 21:19:09 UTC, a KubePodCrashLooping alert fired for the shop service after a pod rollout. In the shop namespace, the api Deployment's new ReplicaSet revision (api-5b9b76c475) produced a pod stuck in CrashLoopBackOff with 3 restarts, while the prior ReplicaSet (api-f64486c4c) continued running two healthy pods [5]. Concurrently, the redis Deployment was rolled to a new revision backed by a PVC (redis-data) created at 21:18:02Z requesting storageClassName "fast-ssd" [17], and its new pod (redis-5fff65475c-hmbbf) has remained in Pending status [9]. The surviving api pods are actively logging Redis connection failures and returning HTTP 503 on `/items` requests [10].

### Root Cause

The root cause is confirmed. The redis Deployment was updated to mount a new PVC requesting storageClassName "fast-ssd" [13, 17], but no such StorageClass exists in the cluster — only the default "standard" (rancher.io/local-path) StorageClass is present [12], and no PersistentVolumes exist [18]. The PVC is permanently stuck in Pending with event "ProvisioningFailed: storageclass \"fast-ssd\" not found" [11]. Because the redis Deployment's rollout history shows revision 1 had no volumes ("Volumes: <none>") [16] versus the new PVC-mounted revision 2 [13], this is a newly introduced dependency that caused the running redis pod to be replaced and the replacement to never schedule [9]. The api service's code performs a hard startup check against Redis, retrying 5 times before calling `sys.exit(1)` [14], which is exactly the failure captured in the crashing pod's logs: five consecutive "Connection refused" attempts followed by "giving up: redis unavailable" [7]. The surviving older-revision api pods remain running but are not crash-looping since they do not restart their Redis check post-startup, yet they still fail live requests against Redis and return 503s on `/items` [10], confirming the frontend-facing symptom is live and ongoing, not just theoretical.

### Impact & Timeline

The redis-data PVC was created at 21:18:02Z requesting the missing StorageClass [17], and the api pod associated with the alert was created/restarted at the same timestamp (`kubectl.kubernetes.io/restartedAt: 2026-10-02T17:18:02-04:00`) [8]. The alert fired at 21:19:09Z, roughly a minute later, consistent with the pod entering its crash-loop backoff cycle [5, 8]. At time of investigation, one api pod (api-5b9b76c475-bkj4m) remains in CrashLoopBackOff [5], the Redis Deployment has zero running replicas with its only pod Pending [9], and the two surviving api pods are returning live 503 responses on `/items` due to Redis connection failures [10].

## Ruled Out

- Node-level failure — all pods other than the two directly affected by the Redis/PVC issue are scheduling and running normally on the same nodes [5, 9].
- api code/deployment change as the trigger — api deployment history shows only routine revisions [15]; the crash is driven by a hard dependency check already present in the ConfigMap code [14], not a new api behavior.
- Pre-existing Redis unavailability — rollout history for redis revision 1 shows no volumes and a presumably functioning pod prior to the change [16]; the failure began only after the PVC/StorageClass change at 21:18:02Z [17].

## Not Checked

- Underlying cause for why "fast-ssd" StorageClass was referenced (e.g., whether it exists in another environment/cluster config) — not available from in-cluster evidence.
- Node resource/capacity status — not independently queried, as all evidence pointed to the StorageClass/PVC issue rather than node constraints.
- Historical/postmortem data — no prior postmortem exists for this incident [19], and no related past incidents were found in memory or incident history [1, 2, 3].