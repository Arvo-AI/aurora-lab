# Aurora Lab

We break Kubernetes on purpose, in known ways, and let an AI SRE agent
([Aurora](https://github.com/Arvo-AI/aurora)) investigate with nothing but the
alert. Because we injected the fault, we know the true root cause, so every
investigation can be scored. We publish every run, including the ones Aurora
gets wrong.

## The benchmark

The current table, Aurora vs HolmesGPT vs K8sGPT on every scenario with every graded run,
is at [aurorasre.ai/benchmark](https://www.aurorasre.ai/benchmark) and as
[`benchmark/results.json`](benchmark/results.json). To add an agent, open an issue with
the "Benchmark: add an agent" template.

## How a run works

1. `lab.sh up` creates a 3-node [kind](https://kind.sigs.k8s.io) cluster.
2. `lab.sh reset` deploys a small healthy app, `shop` (frontend nginx, api,
   worker, redis, a load generator), and waits until it serves 200s.
3. `lab.sh break <scenario>` injects exactly one fault and waits until
   `check.sh` proves the fault is visible in the cluster, then lets it settle.
4. `runner/run.py` captures the cluster state (`evidence-before/`), sends
   Aurora only the alert text from `scenario.yaml`, waits for the
   investigation to finish, and saves the incident, the timeline, every tool
   call with full output (`steps-full.json`) and the final report
   (`aurora-rca.md`).
5. `runner/grade.py` has a judge model (a different model from the one Aurora
   ran on) mark each required finding as met, partial or missed, quoting
   Aurora's words. `runner/grade_full.py` regrades on everything Aurora shows
   the user (report, notes, suggested next steps, last message), and
   `runner/grade_fixes.py` grades the suggested fixes. A person then checks
   each verdict and records it as `human_verdict`. `runner/grade_blind.py`
   grades every answer again with the agent's name, its tool names and the
   cluster name removed from the prompt, as a check on the judge
   (`runs/blind-regrade.md`).

Nothing in the cluster hints at the fault: names and labels are neutral, the
ground truth lives only in `scenarios/*/scenario.yaml`, which Aurora never
sees. Aurora gets read-only cluster access under its default
`observability_only` command policy.

## Scenarios (v0)

| # | Fault | Alert Aurora receives |
|---|---|---|
| 01 | [Worker OOMKilled after a batch size change](scenarios/01-worker-oom/) | KubePodCrashLooping |
| 02 | [Sidecar OOMKilled, app container healthy](scenarios/02-sidecar-oom/) | KubePodCrashLooping |
| 03 | [Mistyped image tag, rollout stuck](scenarios/03-bad-image-tag/) | KubeDeploymentRolloutStuck |
| 04 | [Env var references a Secret that does not exist](scenarios/04-missing-secret/) | KubeDeploymentRolloutStuck |
| 05 | [Invalid nginx directive in a ConfigMap](scenarios/05-nginx-config-error/) | KubePodCrashLooping |
| 06 | [Liveness probe on the wrong port](scenarios/06-liveness-wrong-port/) | KubePodCrashLooping |
| 07 | [Service selector matches no pods](scenarios/07-service-selector-mismatch/) | HighErrorRate |
| 08 | [CPU request larger than any node](scenarios/08-unschedulable-cpu/) | KubePodNotReady |
| 09 | [redis Pending on a PVC with a missing StorageClass (symptom shows in api)](scenarios/09-redis-pvc-pending/) | KubePodCrashLooping |
| 10 | [Wrong REDIS_HOST, name does not resolve](scenarios/10-wrong-redis-host/) | KubePodCrashLooping |

## Scenarios (v1)

Harder on purpose: noise next to the fault, two faults at once, slow faults,
partial restarts.

| # | Fault | Alert Aurora receives |
|---|---|---|
| 11 | [api Service targetPort wrong, worker logs noisy but harmless](scenarios/11-noisy-worker-svc-targetport/) | HighErrorRate |
| 12 | [Worker OOM plus a frontend Service selecting no pods; alert covers only the worker](scenarios/12-two-faults-oom-and-selector/) | KubePodCrashLooping |
| 13 | [NetworkPolicy blocks api to redis](scenarios/13-networkpolicy-blocks-redis/) | HighErrorRate |
| 14 | [ResourceQuota forbids the rollout's surge pod](scenarios/14-resourcequota-rollout/) | KubeDeploymentRolloutStuck |
| 15 | [Stray Deployment's pods carry app=api, 1 in 3 requests fail](scenarios/15-stray-pods-share-label/) | HighErrorRate |
| 16 | [dnsConfig search domains for the wrong cluster domain](scenarios/16-dns-search-domain/) | KubePodCrashLooping |
| 17 | [Slow memory leak in worker code, logs clean](scenarios/17-slow-memory-leak/) | KubePodCrashLooping |
| 18 | [Init container waits for a Service that does not exist](scenarios/18-init-waits-missing-service/) | KubeDeploymentRolloutStuck |
| 19 | [ConfigMap edited, only one of two frontend pods restarted](scenarios/19-config-drift-partial-restart/) | HighErrorRate |

Each scenario folder has `scenario.yaml` (alert, change, root cause, what a
correct answer must identify, acceptable fixes, known wrong answers),
`break.sh`, `check.sh`, and a `README.md` runbook: how to recognise the fault,
diagnose it with real output from the lab runs, and fix it. The runbooks are
mirrored from [aurorasre.ai/runbooks](https://www.aurorasre.ai/runbooks), which
stays the canonical copy.

## Running it

Requirements: Docker with about 16 GB for the VM, kind, kubectl, Python 3,
and a running Aurora (see Aurora's docs; the lab used an isolated Docker
Compose stack on port 15080).

```
./lab.sh up
./lab.sh selftest                 # proves every fault appears as designed
python3 runner/run.py setup       # lab user + cluster access in Aurora
python3 runner/run.py run         # all scenarios, results in runs/<id>/

# v1: parallel lanes, one kind cluster each, fresh Aurora user and org per run
LAB_CLUSTER=aurora-lab-2 ./lab.sh up   # kubeconfig in .kubeconfig-aurora-lab-2
python3 runner/no_prediscovery.py runs/prediscovery-revoked.log &   # see REPORT.md
python3 runner/run.py run 11 12 --run-id my-run --repeats 2 --clusters aurora-lab,aurora-lab-2
python3 runner/grade.py runs/<id>
python3 runner/grade_full.py runs/<id>   # diagnosis on Aurora's full output
python3 runner/grade_fixes.py runs/<id>  # suggested fixes
python3 runner/grade.py runs/<id> --report
```

The lab uses its own kubeconfig (`.kubeconfig`) that contains only the kind
cluster, so it cannot touch any other cluster on the machine.

Results so far: [REPORT.md](REPORT.md).

## Honesty rules

- Every run is kept and reported. No reruns to replace a bad result.
- Scenarios are not changed after seeing Aurora's answer, except to fix a
  ground truth that the evidence shows was wrong, recorded in REPORT.md.
- Findings about Aurora itself go in [FINDINGS.md](FINDINGS.md).
