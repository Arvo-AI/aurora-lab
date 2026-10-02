## Incident Report

**PARAGRAPH 1 — What Happened:**
At 2026-10-02T14:49:37Z, a high-severity KubeDeploymentRolloutStuck alert fired for the shop/frontend deployment. The deployment showed READY 2/2 but UP-TO-DATE 1/2, with a new revision (ReplicaSet frontend-7b6c998456, revision 2) failing to progress while the prior revision (frontend-76d98597b9, revision 1) remained healthy at 2/2 Ready [5, 6, 11]. The single pod of the new ReplicaSet, frontend-7b6c998456-tgptf, remained in Pending/ImagePullBackOff [7, 8].

**PARAGRAPH 2 — Root Cause:**
The root cause was a typo in the container image tag introduced in revision 2 of the frontend Deployment: `nginx:1.27-alpne` instead of `nginx:1.27-alpine` [6, 11]. This nonexistent tag caused repeated image pull failures (ImagePullBackOff) on the new pod [8], preventing it from ever reaching Ready. Because the Deployment's rolling update strategy cannot retire the healthy revision-1 pods until the new revision-1 pod becomes Ready, the rollout stalled with updatedReplicas: 1 of 2 desired. The Deployment's `kubectl.kubernetes.io/last-applied-configuration` annotation retains the correct `nginx:1.27-alpine` image while the live pod template shows the typo'd tag [10], indicating the bad value was introduced via a direct/imperative spec edit (e.g., `kubectl set image`) rather than a reviewed `kubectl apply`.

**PARAGRAPH 3 — Impact & Timeline:**
User-facing impact was limited: both revision-1 pods (correct image) remained Running/Ready throughout and continued serving traffic [7, 12]. Revision 2 was created at 14:48:46 [8], and pull failures began immediately and continued without resolution through the time of investigation [8, 9], leaving the Deployment permanently stuck at 1 of 2 updated replicas pending remediation.

## Ruled Out
- Transient readiness probe failures on revision-1 pods at startup — both rev-1 pods are confirmed 1/1 Running/Ready, ruling out probe flakiness as the cause of the stuck rollout [7, 12].
- Resource/scheduling issue preventing the new pod from being placed — the new pod was successfully scheduled to a node and reached Pending/ImagePullBackOff state, not an unschedulable state [7, 8].
- ConfigMap/env error — no ConfigMap or environment variable change was implicated; the failure is isolated to the container image reference [6, 10, 11].

## Not Checked
- CI/CD pipeline or deployment tooling logs that may show who/what issued the imperative image update — not accessible from this session, so the exact origin of the typo (manual kubectl command vs. automated pipeline) could not be confirmed beyond the last-applied-configuration mismatch [10].
- Cluster-wide metrics (CPU/memory) for the frontend pods — not checked since no resource-pressure symptoms were observed and `kubectl top` is unavailable on this cluster [4].
- Container registry/Docker Hub status — not independently verified beyond the pull failure message; assumed to be correctly reporting a nonexistent tag [8].