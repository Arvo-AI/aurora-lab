## Incident Report: KubeDeploymentRolloutStuck — shop/api

**What Happened**

At 2026-10-02T21:07:18 UTC, a high-severity alert fired indicating that the rollout of the `api` Deployment in the `shop` namespace was stuck. The deployment showed 1 of 2 desired replicas updated, with 1 unavailable replica, and revision 2 remaining in a non-progressing "ReplicaSetUpdated" state [4, 17]. The new ReplicaSet `api-77b4b6956f` produced a single pod (`api-77b4b6956f-7n2df`) that remained stuck in `Init:0/1` status from the moment of creation, never reaching Ready [5, 6, 7]. The previous ReplicaSet, `api-f64486c4c`, continued running 2/2 pods in a healthy `Running` state throughout [5, 6].

**Root Cause**

The root cause was a change to the `api` Deployment (revision 2) that added an init container named `wait-for-db`, which loops indefinitely running `nc -z -w2 postgres 5432` until a Postgres endpoint responds [7]. No Postgres Service or Pod exists anywhere in the cluster — only `kubernetes`, `kube-dns`, `metrics-server`, and the `shop` namespace's `api`, `frontend`, and `redis` services are present [9, 14] — so this init container can never succeed. Confirming this is unnecessary, the application source code in the `api-code` ConfigMap only connects to `REDIS_HOST` and has no reference to Postgres [15]. The prior, currently-healthy ReplicaSet `api-f64486c4c` has no init container at all [16], and the live Deployment's revision jumped to 2 with this init container present in the running spec but absent from the `kubectl.kubernetes.io/last-applied-configuration` annotation, indicating an out-of-band edit rather than a normal declarative update [10, 17]. Because the init container never exits, the main `api` container in every new pod remains in `PodInitializing`, preventing the rollout from ever completing and triggering the `KubeDeploymentRolloutStuck` alert once the progress deadline was exceeded [4, 5, 7].

**Impact & Timeline**

User-facing impact was limited: the old ReplicaSet `api-f64486c4c` kept 2/2 pods Running and serving traffic throughout the incident [5, 6]. However, the rollout itself has been blocked since pod creation (observed age ~70s at investigation time, with the Deployment only 71s old) [4, 5], and will remain stuck indefinitely until the bad init container is removed, since no Postgres endpoint will ever become available [6, 7, 9, 14].

## Ruled Out
- Resource/scheduling failure — pod was successfully Scheduled and the init container image pulled, created, and started without error; no CrashLoopBackOff or OOM observed [7, 8].
- Node-level failure — other pods scheduled on the same node (`aurora-lab-worker2`) were running normally [5].
- Application dependency on Postgres — the `api-code` ConfigMap source shows the app only requires `REDIS_HOST` (Redis), with no Postgres reference [15].
- Missing/misconfigured Postgres Service as an oversight needing restoration — no Postgres Service or Pod exists anywhere in the cluster, consistent with Postgres never being a real dependency [9, 14].

## Not Checked
- Who or what process performed the out-of-band edit that introduced the `wait-for-db` init container — `kubectl rollout history` was blocked by organization policy (mutating operation) [11], so the change author/method could not be directly identified.
- Whether a Postgres Service/Pod was ever intended to be deployed elsewhere (e.g., future namespace) — out of scope since no symptoms indicated an upcoming Postgres dependency.