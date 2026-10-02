## Incident Report

**PARAGRAPH 1 — What Happened**

At 2026-10-02T17:03:47Z, a KubePodCrashLooping alert fired for the `shop` namespace, high severity [chat alert]. At the time of investigation, two `api` pods — `api-c7b987b4d-f98rz` and `api-c7b987b4d-mbfs7` — were actively restarting, each showing 1 restart within roughly 2 minutes of age [4]. The `frontend`, `worker`, `redis`, and `loadgen` workloads in the same namespace showed 0 restarts, indicating the issue was isolated to the `api` deployment [4, 11].

**PARAGRAPH 2 — Root Cause**

The root cause was a misconfigured liveness probe on the `api` Deployment: the probe targets port 8081, while the application only listens on port 8080 [6, 7, 10]. The kubelet repeatedly killed the container after failed liveness checks against port 8081 (`connection refused`), while the readiness probe on the correct port 8080 succeeded [5]. The deployment spec confirms the mismatch — `livenessProbe.httpGet.port: 8081` versus `readinessProbe.httpGet.port: 8080` and `containerPort: 8080` [6] — and the application ConfigMap confirms the code binds a single `ThreadingHTTPServer` on port 8080 with no secondary listener on 8081 [10]. Pod termination details show `Reason: Error`, `Exit Code: 137` consistent with a kubelet-initiated SIGKILL rather than an application crash [9]. Resource exhaustion was ruled out, as CPU/memory usage (4m CPU, 12–18Mi memory) was far below the 128Mi limit and all nodes were Ready [11, 12].

**PARAGRAPH 3 — Impact & Timeline**

Impact was confined to the `api` service in the `shop` namespace; two of two `api` pods were in a restart cycle at the time of the alert, with restarts occurring roughly every 60–70 seconds [4, 5]. Other services in the namespace (`frontend`, `worker`, `redis`, `loadgen`) were unaffected, with zero restarts recorded [4, 11].

## Ruled Out
- OOMKill / resource exhaustion — memory usage was 12–18Mi against a 128Mi limit, and pod termination reason was `Error`, not `OOMKilled` [9, 11].
- Node-level failure — all nodes reported `Ready` status [12].
- Application-level crash or bug — app logs show the server starting cleanly, connecting to redis, and successfully serving `/healthz` with HTTP 200 [7]; code review shows no secondary listener or logic error [10].
- Readiness/traffic-routing issue — readiness probe on port 8080 succeeded consistently, so the pods were not failing to serve traffic [5, 7].

## Not Checked
- Deployment rollout history — `kubectl rollout history` was blocked by organization policy on mutating operations, so it could not be confirmed when or by whom the liveness probe port was changed to 8081 [8].
- Prior incidents or recurring pattern history — no matching incidents were found in the incident store, and no memory records existed for `shop` [1, 2].
- Cluster-wide event history beyond the current window — only recent events were reviewed [5]; no broader audit log was examined to identify the specific change event that introduced the probe mismatch.