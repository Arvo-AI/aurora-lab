## Incident Report

**What Happened:**
At 16:59:43 UTC on 2026-10-02, a high-severity KubePodCrashLooping alert fired for the shop service. Investigation of the shop namespace showed the pod frontend-8646dc84f6-f4xpw, belonging to a newly-created ReplicaSet, in CrashLoopBackOff with repeated restarts [6, 9], while the pre-existing ReplicaSet frontend-76d98597b9 remained healthy with 2/2 pods Running [6, 12]. The Service endpoint list for frontend showed only the two healthy old-ReplicaSet pod IPs, with the new pod absent [14].

**Root Cause:**
The root cause was a typo in the ConfigMap frontend-nginx, which supplies the mounted nginx configuration at /etc/nginx/conf.d/default.conf: the directive `proxy_connect_timeout` was misspelled as `proxy_conect_timeout` on line 9 [10]. This caused nginx to fail config validation at startup with `nginx: [emerg] unknown directive "proxy_conect_timeout"`, terminating the container with exit code 1 and triggering CrashLoopBackOff [8, 9]. The new pod was created at 16:58:48 UTC, matching the Deployment's `kubectl.kubernetes.io/restartedAt` annotation and the bump to revision 2 [9, 13], indicating the ConfigMap edit was followed by a rollout restart that exposed the broken config to the new ReplicaSet while the already-running old ReplicaSet pods, which had not reloaded the config, were unaffected.

**Impact & Timeline:**
Impact was partial rather than a full outage: the Deployment was stuck mid-rollout with the new ReplicaSet frontend-8646dc84f6 unable to reach ready state (0/1 ready) [12], while traffic continued to be served by the two healthy old-ReplicaSet pods per the Service endpoints [14]. The crash loop began at 16:58:48 UTC when the new pod was scheduled and continued through subsequent restart attempts [8, 9], with the alert firing at 16:59:43 UTC.

## Ruled Out
- OOM/resource exhaustion — pod termination reason was "Error" with exit code 1 from an explicit nginx config parse failure, not OOMKilled [9]
- Image pull or node-level issue — image nginx:1.27-alpine was already present and used successfully by other pods on the same nodes [12]
- Transient readiness-probe flap — the container itself failed to start due to a config parse error, independent of any probe [8, 9]

## Not Checked
- Deployment rollout history (`kubectl rollout history`) — blocked by organizational read-only/mutating-command policy [11]
- Prior incidents or historical pattern for this service/cluster — no matching records found in memory [2, 3, 4]
- Who/what process made the ConfigMap edit — no audit log or change-tracking evidence was available in the collected data