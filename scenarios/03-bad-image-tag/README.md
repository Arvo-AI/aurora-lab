# ImagePullBackOff: the image could not be pulled and Kubernetes is backing off (Kubernetes)

*ImagePullBackOff means the kubelet could not pull the image and is retrying, up to 5 minutes apart. Read the event, fix the reference, verify. Lab-tested.*

Runbook for lab scenario `03-bad-image-tag`. Canonical version, with its byline, kept current: https://www.aurorasre.ai/runbooks/fix-imagepullbackoff-kubernetes. Written from the lab runs in this repository; updated 2026-10-08.

## Reproduce it

```
./lab.sh up
./lab.sh break 03-bad-image-tag
```
Then investigate with any tool you like; `scenario.yaml` holds the ground truth and the grading criteria.

| Applies to | Kubernetes Deployments and Pods on any cluster; the registry error text is from containerd |
|---|---|
| Verified on | Kubernetes v1.37.0 (kind v0.33.0, containerd 2.3.4), 2 October 2026 |
| Lab folder | [scenarios/03-bad-image-tag](https://github.com/Arvo-AI/aurora-lab/tree/main/scenarios/03-bad-image-tag), runs in [runs/v0-run2/03-bad-image-tag](https://github.com/Arvo-AI/aurora-lab/tree/main/runs/v0-run2/03-bad-image-tag) |

**ImagePullBackOff means the kubelet could not pull the container image and is now waiting longer between attempts, up to five minutes.** The most common cause is an image reference that does not exist: a mistyped tag, a tag that was never pushed, or the wrong registry. `kubectl describe pod <pod>` shows the exact pull error in the events. Fix the reference (or roll the Deployment back) and the pod leaves Waiting on the next pull.

## At a glance

| Signal in the events | Likely cause | Confirm with | Fix |
|---|---|---|---|
| `failed to resolve reference "...": not found` | The tag or repository does not exist (typo, never pushed) | Pull it yourself, or query the registry for that tag | Correct the image field, or `kubectl rollout undo` |
| `pull access denied`, `unauthorized`, `authentication required` | Private registry with no or wrong `imagePullSecrets` | `kubectl get secret -n <ns>` for the referenced secret, same namespace and type | Create the secret in the pod's namespace, reference it in the pod spec |
| `dial tcp`, `i/o timeout`, `no such host` | The node cannot reach the registry | Pull from a node, check egress and DNS | Fix network egress or the registry hostname |
| `ErrImageNeverPull` | `imagePullPolicy: Never` and the image is not on the node | `kubectl get pod <pod> -o jsonpath='{.spec.containers[*].imagePullPolicy}'` | Pre-load the image or change the policy |

The [container images](https://kubernetes.io/docs/concepts/containers/images/#imagepullbackoff) documentation defines the status: "The status `ImagePullBackOff` means that a container could not start because Kubernetes could not pull a container image (for reasons such as invalid image name, or pulling from a private registry without `imagePullSecret`)." It also fixes the retry cap: "Kubernetes raises the delay between each attempt until it reaches a compiled-in limit, which is 300 seconds (5 minutes)." Waiting does not fix a pull.

## Confirm: is it ImagePullBackOff, and which pods?

Start with the Deployment, then the pods. A Deployment that is `READY 2/2` but `UP-TO-DATE 1` is mid-rollout and stuck, which is the shape this runbook reproduces. Output from the lab, run r1:

```shell
kubectl get deployment frontend -n shop -o wide
```

```
NAME       READY   UP-TO-DATE   AVAILABLE   AGE   CONTAINERS   IMAGES             SELECTOR
frontend   2/2     1            2           78s   nginx        nginx:1.27-alpne   app=frontend
```

The image column already shows the problem if you know the right tag. Most people do not spot `alpne` on the first read. List the pods:

```shell
kubectl get pods -n shop -o wide
```

```
NAME                        READY   STATUS             RESTARTS   AGE   IP           NODE
frontend-76d98597b9-jkkw9   1/1     Running            0          82s   10.244.2.9   aurora-lab-3-worker2
frontend-76d98597b9-rb9z6   1/1     Running            0          82s   10.244.1.7   aurora-lab-3-worker
frontend-7b6c998456-phg6r   0/1     ImagePullBackOff   0          75s   10.244.1.9   aurora-lab-3-worker
```

Two pods from the old ReplicaSet (`76d98597b9`) are serving. One pod from the new ReplicaSet (`7b6c998456`) never started. `RESTARTS 0` is a useful tell: the container has not run once, so this is not a crash and `kubectl logs` has nothing to show.

Look-alikes: `CrashLoopBackOff` has a restart count climbing and logs to read, see [how to fix OOMKilled](https://www.aurorasre.ai/runbooks/fix-oomkilled-kubernetes) for the memory variant. `Pending` with `FailedScheduling` means the pod has no node yet; here the pod was scheduled (`PodScheduled True`) and only the pull failed.

## Scope: is anything down?

Describe the Deployment and read the replica line and the two ReplicaSets:

```shell
kubectl describe deployment frontend -n shop
```

```
Annotations:            deployment.kubernetes.io/revision: 2
Replicas:               2 desired | 1 updated | 3 total | 2 available | 1 unavailable
StrategyType:           RollingUpdate
RollingUpdateStrategy:  25% max unavailable, 25% max surge
Conditions:
  Type           Status  Reason
  ----           ------  ------
  Available      True    MinimumReplicasAvailable
  Progressing    True    ReplicaSetUpdated
OldReplicaSets:  frontend-76d98597b9 (2/2 replicas created)
NewReplicaSet:   frontend-7b6c998456 (1/1 replicas created)
```

`2 available` of `2 desired` means users are not affected: the RollingUpdate strategy created one surge pod (25% of 2, rounded up) and will not remove an old pod until a new one is Ready. The old ReplicaSet keeps serving. This is a stuck rollout, not an outage, and that changes the urgency. If `available` were below `desired`, it would be an outage and the rollback in the Fix section comes first.

The Deployment carries `progressDeadlineSeconds: 600` (the lab manifest, and the Kubernetes default). The [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#failed-deployment) documentation says that once that deadline passes the controller sets the `Progressing` condition to `False` with reason `ProgressDeadlineExceeded`. Until then the condition reads `ReplicaSetUpdated`, as above, so do not wait for it to tell you the rollout is stuck.

## Isolate: why can the kubelet not pull?

Describe the waiting pod. The events hold the full error from the container runtime. Run r1, trimmed to the container state and events:

```shell
kubectl describe pod frontend-7b6c998456-phg6r -n shop
```

```
Status:           Pending
Controlled By:    ReplicaSet/frontend-7b6c998456
Containers:
  nginx:
    Image:          nginx:1.27-alpne
    State:          Waiting
      Reason:       ImagePullBackOff
    Ready:          False
    Restart Count:  0
Conditions:
  PodScheduled                True
Events:
  Type     Reason     Age                From               Message
  Normal   Scheduled  85s                default-scheduler  Successfully assigned shop/frontend-7b6c998456-phg6r to aurora-lab-3-worker
  Normal   BackOff    15s (x4 over 83s)  kubelet            spec.containers{nginx}: Back-off pulling image "nginx:1.27-alpne"
  Warning  Failed     15s (x4 over 83s)  kubelet            spec.containers{nginx}: Error: ImagePullBackOff
  Normal   Pulling    1s (x4 over 84s)   kubelet            spec.containers{nginx}: Pulling image "nginx:1.27-alpne"
  Warning  Failed     0s (x4 over 84s)   kubelet            spec.containers{nginx}: Failed to pull image "nginx:1.27-alpne": rpc error: code = NotFound desc = failed to pull and unpack image "docker.io/library/nginx:1.27-alpne": failed to resolve reference "docker.io/library/nginx:1.27-alpne": docker.io/library/nginx:1.27-alpne: not found
  Warning  Failed     0s (x4 over 84s)   kubelet            spec.containers{nginx}: Error: ErrImagePull
```

Read the last `Failed` line word by word. Three things are in it:

1. `docker.io/library/nginx:1.27-alpne` is the fully resolved reference. The pod spec said `nginx:1.27-alpne`; the runtime filled in the registry and the `library/` namespace, as the images documentation describes: "If you don't specify a registry hostname, Kubernetes assumes that you mean the Docker public registry."
2. `code = NotFound` and `not found` mean the registry answered and said the reference does not exist. This rules out credentials (that would be `unauthorized` or `denied`) and network (that would be a timeout or a DNS error). The decision is made here.
3. `x4 over 84s` is the backoff doing its job. The count will keep growing until the reference changes.

Then find what the working pods run. Compare the ReplicaSets, cheapest check first. Run r1:

```shell
kubectl get replicaset -n shop -l app=frontend -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[0].image}{" replicas="}{.spec.replicas}{" ready="}{.status.readyReplicas}{"
"}{end}'
```

```
frontend-76d98597b9 nginx:1.27-alpine replicas=2 ready=2
frontend-7b6c998456 nginx:1.27-alpne replicas=1 ready=
```

The diff is one letter. If the two tags look identical, check the ReplicaSet revisions directly; run r2 read both ReplicaSets as YAML and the relevant fields were:

```shell
kubectl get rs -n shop -l app=frontend -o yaml
```

```
      deployment.kubernetes.io/revision: "1"
    name: frontend-76d98597b9
        - image: nginx:1.27-alpine
    readyReplicas: 2
      deployment.kubernetes.io/revision: "2"
    name: frontend-7b6c998456
        - image: nginx:1.27-alpne
    replicas: 1
```

If you can, confirm the correct tag exists before you change anything. Aurora did this in run r1 against the Docker Hub API and got a 200 for `1.27-alpine`:

```shell
curl -s -o /dev/null -w "%{http_code}
" https://registry.hub.docker.com/v2/repositories/library/nginx/tags/1.27-alpine/
```

```
200
```

For a private registry, `docker pull <image>` or `crane manifest <image>` from a machine with the same credentials answers the same question. If a pull from your laptop succeeds and the node's events still say `not found`, the node is pulling from a different registry (a mirror, or a different `imagePullSecrets` host) and that is the next thing to check.

The other branches of the table are quick to rule out: `kubectl get pod <pod> -o jsonpath='{.spec.imagePullSecrets}'` shows whether a secret is referenced at all, and `kubectl get secret <name> -n <ns>` shows whether it exists in the pod's namespace, which the documentation requires: "All `imagePullSecrets` must be Secrets that exist in the same Namespace as the Pod."

## Fix: correct the reference or roll back

Two acceptable fixes. Pick by how sure you are of the right tag.

**Set the correct image.** Starts a new rollout (revision 3) with the right reference:

```shell
kubectl -n shop set image deploy/frontend nginx=nginx:1.27-alpine
```

Risk: if the new tag is also wrong, you get the same stuck rollout one revision later and nothing else changes, because the old pods keep serving. Rollback: `kubectl -n shop rollout undo deploy/frontend`.

**Roll back to the last working revision.** Use this when you do not know the intended tag, or when the Deployment is an outage rather than a stuck rollout:

```shell
kubectl -n shop rollout undo deploy/frontend
```

Risk: you lose whatever else was in the new revision (env, resources, config changes bundled with the image bump). Rollback of the rollback is `kubectl rollout undo --to-revision=<n>`.

Mitigation is not needed here because the old pods are serving. If `available` had dropped below `desired`, `rollout undo` is both the mitigation and the fix.

Deleting the waiting pod does nothing: the ReplicaSet recreates it with the same bad spec. Do not disable the readiness probe or raise `maxUnavailable` to make the rollout "progress"; that trades a stuck rollout for serving pods that were never pulled.

## Verify: the rollout completes

```shell
kubectl -n shop rollout status deploy/frontend --timeout=120s
kubectl -n shop get rs -l app=frontend
```

Pass condition: `rollout status` returns `deployment "frontend" successfully rolled out`, the Deployment shows `READY 2/2`, `UP-TO-DATE 2`, `AVAILABLE 2`, the ReplicaSet with the bad tag is scaled to 0, and no pod in the namespace has `ImagePullBackOff` or `ErrImagePull` in its waiting reason. Watch for two minutes: a `Pulling` event followed by `Pulled` and `Started` on the new pods is the proof, and the backoff counter stops growing.

## Prevent: catch a bad reference before it reaches the cluster

**Alert.** With kube-state-metrics, these two expressions cover the pod and the Deployment (not tested in the lab, where the alert was a text string sent to Aurora):

```
kube_pod_container_status_waiting_reason{reason=~"ImagePullBackOff|ErrImagePull"} > 0
kube_deployment_status_replicas_updated < kube_deployment_spec_replicas
```

The second one watches the Deployment rather than the pod, so a stuck rollout with zero updated replicas still fires.

**Guardrail.** Pin images by digest (`nginx@sha256:...`) so a tag typo cannot resolve at all, or have CI verify every image reference in the manifest exists before `kubectl apply`:

```shell
crane manifest nginx:1.27-alpine > /dev/null
```

A non-zero exit fails the pipeline. `docker manifest inspect <image>` does the same without extra tooling.

**Test.** A pre-merge policy check (Kyverno or OPA Gatekeeper) that rejects `:latest` and untagged images removes the other half of this class of failure. The images documentation recommends it: avoid `:latest` "as it is harder to track which version of the image is running and more difficult to roll back properly."

## Common mistakes

- **Treating it as a registry auth problem.** `not found` is the registry saying the reference does not exist. Adding an `imagePullSecret` changes nothing. Read the error code before you touch secrets.
- **Waiting it out.** The backoff caps at five minutes and never recovers on its own. Nothing changes until the spec changes.
- **Deleting the pod.** The ReplicaSet recreates it with the same image. The restart count stays at 0 and the events start over.
- **Calling it an outage.** Check `available` against `desired` first. In the lab the old pods served the whole time; the right urgency is "blocked deploy", not "site down".
- **Restarting the rollout.** `kubectl rollout restart` creates yet another ReplicaSet with the same bad image.
- **Fixing the tag without checking it exists.** Run r1 confirmed `1.27-alpine` against the registry before suggesting it. One more typo costs another rollout.

## What we saw in the lab

We injected this fault with one command, `kubectl -n shop set image deploy/frontend nginx=nginx:1.27-alpne`, into a 3-node kind v0.33.0 cluster running a small app (`shop`: nginx frontend, a Python api, a worker, redis, a load generator). Aurora got only the alert text, "KubeDeploymentRolloutStuck: deployment frontend in namespace shop has not progressed.", read-only kubectl under its default `observability_only` policy, model `bedrock/us.anthropic.claude-sonnet-5`, single agent, Aurora commit `87d22baf`. Two runs, each with a fresh user and org.

| Run | Verdict (person-checked) | Time | Tool calls | Cost | Fix suggested |
|---|---|---|---|---|---|
| r1 | correct | 101 s | 13 (1 blocked) | $0.24 | `kubectl set image deployment/frontend nginx=nginx:1.27-alpine -n shop` |
| r2 | correct | 77 s | 11 (1 blocked) | $0.19 | set the tag to `nginx:1.27-alpine`, `rollout undo` as the alternative |

Both runs took the same path this runbook takes: `get deployment` (the image column), `get pods` (one pod in `ImagePullBackOff`, two serving), `describe pod` (the `not found` event), then a ReplicaSet comparison to find the good tag. r1 used the jsonpath above; r2 read both ReplicaSets as YAML. Both named the typo, both said the old pods were still serving so there was no user-facing outage, and both ruled out registry credentials and network problems, the two wrong answers the scenario was built to tempt. r1 also checked that `1.27-alpine` exists on Docker Hub before suggesting it.

Both runs tried `kubectl rollout history deployment/frontend -n shop` to see what changed and got:

```
Command blocked by organization policy: Mutating kubectl operations
```

`rollout history` is read-only; Aurora's default policy denies the whole `rollout` verb. Both runs worked around it with the ReplicaSet comparison. The policy fix (deny only `rollout restart|undo|pause|resume`) is in the lab's [fix branch](https://github.com/Arvo-AI/aurora-lab/blob/main/REPORT.md) and the blocked call counts as the one tool error in each run.

What the reports got wrong, from the grades: r1 described "3 total pods" and "reduced redundancy" although 2 of 2 desired pods were available, and said the cluster could not schedule a replacement pod when the pod was scheduled and only the pull failed. r2 said the Deployment was created at 16:57:25 (that was the revision 1 ReplicaSet) and called `rollout history` a mutating operation because the policy message said so. None of it touched the root cause or the fix, and the person reviewing the grades kept both verdicts at correct. Full traces: [r1](https://github.com/Arvo-AI/aurora-lab/tree/main/runs/v0-run2/03-bad-image-tag/r1), [r2](https://github.com/Arvo-AI/aurora-lab/tree/main/runs/v0-run2/03-bad-image-tag/r2).

## How Aurora handles this

Aurora receives the alert, lists the Deployment and its pods, reads the waiting pod's events and compares the ReplicaSets, then writes the root cause with each claim cited to a tool output, as in the two runs above. It runs read-only by default: kubectl goes through an allowlist, and the fix is written as a suggested next step for a person to apply, not executed. It records the investigation as memory, so the next `KubeDeploymentRolloutStuck` in the same org starts from what it learned. The [root cause analysis](https://www.aurorasre.ai/rca) page shows what a finished investigation looks like; the method behind it is in the [root cause analysis guide](https://www.aurorasre.ai/blog/root-cause-analysis-complete-guide-sres).

- **Start free:** [aurora-ai.net](https://aurora-ai.net/) (hosted, no infrastructure to run)
- **GitHub:** [github.com/Arvo-AI/aurora](https://github.com/Arvo-AI/aurora)
- **Book a demo:** [cal.com/arvo-ai/demo](https://cal.com/arvo-ai/demo)

## Sources and verification

- Every output block above is from the lab runs of 2 October 2026, [runs/v0-run2/03-bad-image-tag](https://github.com/Arvo-AI/aurora-lab/tree/main/runs/v0-run2/03-bad-image-tag) (r1 and r2: every tool call and output in `steps-full.json`, cluster state in `evidence-before/`), trimmed to the relevant lines and otherwise unchanged. Fault injection: [scenarios/03-bad-image-tag](https://github.com/Arvo-AI/aurora-lab/tree/main/scenarios/03-bad-image-tag).
- Versions: Kubernetes server v1.37.0, kind v0.33.0, containerd 2.3.4, kubectl client v1.35.3 (`evidence-before/versions.yaml`). Aurora commit `87d22baf`, model `bedrock/us.anthropic.claude-sonnet-5`.
- The ImagePullBackOff definition, the 300-second cap, the registry defaults, the `imagePullSecrets` namespace rule and the `:latest` advice are quoted from the Kubernetes [container images](https://kubernetes.io/docs/concepts/containers/images/) documentation. The `ProgressDeadlineExceeded` behavior is from the [Deployments](https://kubernetes.io/docs/concepts/workloads/controllers/deployment/#failed-deployment) documentation. Both read 8 October 2026.
- The grades, including the misstatements listed above, are in each run's `grade.json` with `human_verdict` recorded on 2 October 2026.

## Questions people ask

**What does ImagePullBackOff mean in Kubernetes?**

The kubelet could not pull the container image and is now waiting longer between attempts. The container never started, so there are no logs; the pull error is in the pod events.

**How do I find the exact reason for ImagePullBackOff?**

Run kubectl describe pod <pod> and read the Failed events. The message includes the fully resolved image reference and the registry's answer: not found for a missing tag, unauthorized for credentials, a timeout or DNS error for network.

**How do I tell a mistyped tag from a credentials problem?**

A missing tag returns NotFound and 'not found' in the event. A credentials problem returns unauthorized, denied or 'authentication required'. The registry answered in both cases, so the network is fine.

**Is ImagePullBackOff during a rollout an outage?**

Usually not. With the RollingUpdate strategy the old pods keep serving until a new pod is Ready. Check the Deployment's available count against desired; if they match, the rollout is stuck but users are unaffected.

**How long does ImagePullBackOff wait between pulls?**

Kubernetes raises the delay after each failed attempt up to a compiled-in limit of 300 seconds. It never gives up and never recovers on its own; the spec has to change.

**Does deleting the pod fix ImagePullBackOff?**

No. The ReplicaSet recreates the pod with the same image reference and the same error. Correct the image in the Deployment or roll the Deployment back.

**Should I use kubectl set image or kubectl rollout undo?**

Use set image when you know the correct tag and the rest of the revision should stay. Use rollout undo when you do not know the intended tag, or when the Deployment is an outage rather than a stuck rollout.

**How do I prevent ImagePullBackOff?**

Pin images by digest or have CI verify that every image reference exists before applying, and alert on kube_pod_container_status_waiting_reason for ImagePullBackOff and on updated replicas below desired.

**How did Aurora do on this failure in the lab?**

Two runs, both correct as checked by a person: 101 and 77 seconds, 13 and 11 tool calls, $0.24 and $0.19. Both named the typo, both said the old pods were still serving, and both ruled out credentials and network.


---
This file mirrors https://www.aurorasre.ai/runbooks/fix-imagepullbackoff-kubernetes; edits land there first. Benchmark of three agents on this and 18 other faults: https://www.aurorasre.ai/benchmark
