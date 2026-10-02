## Incident Report

**What Happened**

On 2026-10-02 at 21:24:19 UTC, a KubePodCrashLooping alert fired for the `shop` service in the `aurora-lab` cluster [1]. The pod `frontend-667786b9fd-j5dnw`, part of a new ReplicaSet created at 21:23:27 UTC, was observed in `0/1 Error` status with 3 restarts within 65 seconds [4, 7]. Two other frontend pods belonging to an older ReplicaSet (`frontend-76d98597b9`) remained healthy at `1/1 Running` with zero restarts throughout [4, 13]. The `frontend` Service continued to route traffic only to the two healthy old pods [11, 12], while the new pod's single replica remained unavailable.

**Root Cause**

The root cause is confirmed: the `frontend-nginx` ConfigMap contains a typo on line 9 of `default.conf` — `proxy_conect_timeout 2s;` instead of the valid nginx directive `proxy_connect_timeout 2s;` [9]. This invalid directive causes nginx to fail parsing its configuration at startup and exit with code 1, producing the observed `Error`/CrashLoopBackOff state [4, 6, 7]. The failure only affected the new ReplicaSet because its pods were spawned by a `kubectl rollout restart` at 21:23:27 UTC [7, 13], forcing them to mount the ConfigMap fresh; the two older pods had been running continuously since before the bad config was introduced, and nginx does not hot-reload `conf.d` files, so their already-loaded configuration was unaffected [4, 13]. The Deployment manifest confirms the ConfigMap is referenced by plain name rather than a content hash [8], meaning the broken config is shared across all ReplicaSet revisions, including the healthy one still running in memory.

**Impact & Timeline**

Impact is currently partial: the Service endpoint list shows only the 2 healthy old pods actively serving traffic (10.244.1.168:80, 10.244.2.152:80), with the crash-looping pod correctly excluded from endpoints [11]. This represents 1 of 3 desired frontend replicas unavailable, not a full outage. However, because the only replacement pod template available (the new ReplicaSet) carries the broken config, any disruption to the two remaining old pods would leave no healthy frontend capacity. The crash loop began precisely at the 21:23:27 UTC rollout restart and has continued through alert time (21:24:19 UTC) [4, 7].

## Ruled Out
- Image pull failure — pod reached `Running`/`Error` lifecycle with container start attempts, not an image pull error state [4, 7].
- Resource exhaustion (OOMKilled) — exit reason is `Error` from nginx config parse failure, not an OOM termination [6, 7].
- Deployment rollback as a viable fix — revision history shows the ConfigMap is shared by name across revisions, so a Deployment rollback alone would not resolve the issue [8, 10].

## Not Checked
- Root cause/authorship of the ConfigMap edit (who/when the typo was introduced) — no change history or audit log was available for the ConfigMap object itself.
- Downstream impact on the `api` or `redis` services — no symptoms or alerts indicated involvement, and investigation scope was limited to the `frontend` crash loop.
- Node-level health (`aurora-lab-worker2`) — not examined, as pod scheduling and startup clearly pointed to a config-parsing failure rather than node issues.