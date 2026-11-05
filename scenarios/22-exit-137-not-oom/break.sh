# A release adds a liveness probe on a heartbeat file the worker never writes and
# shortens the grace period to 10 s. The worker is Python as PID 1 with no SIGTERM
# handler, so the kubelet's SIGTERM does nothing and the runtime SIGKILLs it when
# the grace period ends: exit code 137, reason Error, no memory pressure at all.
kubectl -n shop patch deploy worker --type strategic -p '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":10,"containers":[{"name":"worker","livenessProbe":{"exec":{"command":["test","-f","/tmp/worker-heartbeat"]},"initialDelaySeconds":5,"periodSeconds":5,"failureThreshold":2}}]}}}}'
kubectl -n shop rollout status deploy/worker --timeout=120s
