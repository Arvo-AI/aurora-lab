## Incident Report

**What Happened**

At 2026-10-02T20:31:12Z, a KubePodCrashLooping alert fired for the `api` deployment in the `shop` namespace. At the time of investigation, pod `api-779966d57-f8nsq` was in `0/1 Error` state with 3 restarts in 80 seconds, cycling through `CrashLoopBackOff` [4, 7]. This pod belonged to a new ReplicaSet (`api-779966d57`, deployment revision 2) created at 20:30:10Z as part of an in-progress rollout, while two pods from the prior ReplicaSet (`api-f64486c4c`, revision 1) remained healthy and running (1/1) [4, 5, 8].

**Root Cause**

The root cause is confirmed. The revision 2 pod template introduced `dnsPolicy: None` with an explicit `dnsConfig.searches` list using the domain suffix `cluster.internal` [8], whereas the cluster's actual CoreDNS zone is `cluster.local`, as declared in the `coredns` ConfigMap's Corefile (`kubernetes cluster.local in-addr.arpa ip6.arpa`) [11]. This mismatch broke short-name DNS resolution inside the new pod. Container logs show five consecutive failed attempts to resolve the `redis` hostname (`[Errno -2] Name does not resolve`), after which the application gave up and exited with code 1, triggering the restart loop [6, 7]. The previous revision's pods use the default `dnsPolicy: ClusterFirst` with no custom `dnsConfig` and continue running without errors against the same `redis` Service [5, 8, 9], isolating the fault to the DNS configuration change shipped in the rollout rather than to Redis availability, the container image, or resource limits.

**Impact & Timeline**

The new ReplicaSet pod began crash-looping immediately after creation at 20:30:10Z, roughly one minute before the alert fired at 20:31:12Z [4, 7]. Impact was partial: the deployment remained available because two revision-1 pods continued serving traffic [4], but the rollout could not progress and the new pod would continue restarting indefinitely until remediated.

## Ruled Out
- Redis service unavailability — Service `redis` exists with correct selector/ClusterIP, and revision-1 pods connect to it successfully with zero restarts [9, 4].
- Container image or pull failure — image was already present and pod reached Running state before failing in application logic [7].
- OOM/resource limit kill — exit code was 1 (application-level failure), not 137, and no OOM events were observed [6, 7, 13].

## Not Checked
- Direct inspection of `/etc/resolv.conf` inside a running pod to visually confirm the applied search domains — blocked by read-only policy on mutating/exec kubectl operations [10].
- Full rollout history (`kubectl rollout history`) to identify who/what triggered the ConfigMap or template change — blocked by read-only policy [12].
- Complete namespace event timeline beyond the initial scale-up events shown — truncated output did not include later CrashLoopBackOff events for correlation [13].