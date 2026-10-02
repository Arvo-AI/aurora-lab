## Incident Report

**What Happened:**
On 2026-10-02 at 16:31:05 UTC, a KubePodCrashLooping alert fired for the shop service's frontend component [1]. At the time of investigation, pod frontend-7547556c6b-svhfr was observed in a 0/1 CrashLoopBackOff state with escalating restarts, while two pods from the prior ReplicaSet (frontend-76d98597b9-*) remained healthy at 1/1 Running [4]. The affected pod belongs to Deployment frontend, revision 2, which was mid-rollout with status showing unavailableReplicas: 1 and the ReplicaSet frontend-7547556c6b marked as "progressing" [9]. All three cluster nodes were Ready, and other services (api) were running normally [4, 12].

**Root Cause:**
The root cause was a typo in the frontend-nginx ConfigMap's default.conf, where `proxy_conect_timeout` was used instead of `proxy_connect_timeout` [8]. Container logs confirm nginx fails to parse this as an unknown directive at startup and exits with error (emerg level, exit code 1) [6]. This caused the readiness probe to fail with connection refused, since the nginx process never starts [7]. The new ReplicaSet frontend-7547556c6b, scaled up as part of the current rollout, loads this broken config on every pod start, while the older ReplicaSet's pods remain healthy only because they had already loaded a working config before the change and do not hot-reload on ConfigMap updates [11].

**Impact & Timeline:**
Old ReplicaSet pods were created roughly 2m18s prior to investigation and have remained healthy throughout [11]. The new ReplicaSet was scaled up approximately 2m11s prior, and its sole pod has been crash-looping since, with 3-4 restarts observed within roughly 65-80 seconds [4]. The Deployment remains in a degraded, partially-rolled-out state (2 old pods serving traffic, 1 new pod failing) pending a ConfigMap fix [9].

## Ruled Out
- OOM/resource exhaustion — exit code was 1 (config parse failure), not 137; the 64Mi memory limit was not exceeded [6].
- Node or cluster-level instability — all three nodes reported Ready [12].
- Image/code regression — the image (nginx:1.27-alpine) is unchanged between the old and new ReplicaSets; only the mounted ConfigMap content differs [9].
- Broader service outage — other pods (api) were observed Running and healthy during the same window [4].

## Not Checked
- Deployment rollout history (`kubectl rollout history`) was blocked by organization policy restricting mutating/history kubectl operations, so prior revisions and change authorship could not be directly confirmed [10].
- The remediation patch and any rollout restart were not executed, as mutating kubectl operations are blocked in this read-only session; fixes remain validated but unapplied pending engineer action with write access.