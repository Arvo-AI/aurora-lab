## Incident Report

**What Happened**

At 2026-10-02T20:36:19 a high-severity KubePodCrashLooping alert fired for the `worker` deployment in the `shop` namespace. The pod `worker-5b67b55dd5-wlxf4` showed 2 restarts within a 5-minute age window [4][6]. `kubectl describe pod` confirmed the container's last state as Terminated with Reason: OOMKilled, Exit Code: 137, with the previous run lasting approximately 2 minutes 21 seconds before termination [6]. All other pods in the `shop` namespace (api, frontend, redis) remained in Running status with 0 restarts, indicating the issue was isolated to the `worker` deployment [4].

**Root Cause**

The root cause is confirmed: the `worker` container is repeatedly OOMKilled due to an unbounded memory leak in the application code mounted from ConfigMap `api-code` (worker.py). The code appends ~5MB of data to the `recent` list on every 5-second loop iteration without ever trimming it, despite the comment implying it should hold only a bounded tail [8]. The container has a 192Mi memory limit [5][6], and a live memory check on a freshly restarted pod (19s old) already showed 34Mi and climbing, consistent with the leak actively progressing [10]. Logs from the previous terminated container showed clean, exception-free output ("processed batch of 500 items") right up to the kill, ruling out an application crash and confirming the termination was a hard resource kill rather than a code-level fault [7].

**Impact & Timeline**

The leak reaches the 192Mi limit roughly every 2–5 minutes, producing a repeating OOMKill → restart cycle that matches the alert's "restarted repeatedly in the last 30 minutes" condition [6][10]. Impact was confined to the single `worker` deployment/pod; the replicaset history shows one actively cycling replicaset for `worker` [11], while other `shop` services were unaffected [4].

## Ruled Out
- Application exception or crash — previous container logs were clean with no errors, only normal batch-processing output up to termination [7]
- Node-level resource pressure — other pods on the same cluster/namespace remained healthy with 0 restarts [4]
- Readiness/liveness probe misconfiguration — no probes were defined on the worker container [6]
- Traffic spike or BATCH_SIZE change as the cause — the leak is driven by code logic independent of batch size; the buggy append path is unconditional [8]

## Not Checked
- Prior incident history for this deployment — memory search returned no existing entries, so no historical pattern comparison was possible [2]
- Fix deployment/validation in-cluster — remediation requires `kubectl edit/patch configmap` and `rollout restart`, both mutating operations blocked in this read-only session
- Readiness-probe warnings observed on api/frontend during startup — noted as normal startup noise unrelated to this OOM chain and not pursued further