# Exit code 137: meaning and how to fix it (Kubernetes, Docker)

*Exit code 137 means SIGKILL, and it is not always out of memory. Six causes reproduced on Kubernetes 1.37 and Docker, told apart from real output.*

Runbook for lab scenario `22-exit-137-not-oom`. Canonical version, with its byline, kept current: https://www.aurorasre.ai/runbooks/fix-exit-code-137-kubernetes. Written from the lab runs in this repository; updated 2026-11-05.

## Reproduce it

```
./lab.sh up
./lab.sh break 22-exit-137-not-oom
OUT=/tmp/out scenarios/22-exit-137-not-oom/repro.sh
```
`break.sh` injects the graded fault: a liveness probe that can never pass on a worker that cannot stop on SIGTERM. `repro.sh` then runs every other case on the page (it needs docker, sudo and kind node names, and turns swap off, so run it on a throwaway machine such as the Repro workflow). `scenario.yaml` holds the ground truth and the grading criteria.

| Applies to | Any process that exits 137: Kubernetes containers (`Exit Code: 137`), Docker and Compose containers, `docker build` steps, and plain Linux shells and services |
|---|---|
| Verified on | Kubernetes server v1.37.0 (kindest/node:v1.37.0), kind v0.33.0, kubectl client v1.37.2, containerd v2.3.4, Docker Engine 28.0.4, cgroup v2, kernel 7.0.0-1017-azure on a GitHub Actions Ubuntu runner, python:3.12-alpine, busybox:1.37, 2026-11-05 |
| Lab folder | [scenarios/22-exit-137-not-oom](https://github.com/Arvo-AI/aurora-lab/tree/main/scenarios/22-exit-137-not-oom), captured output in [runs/search-2026-11-05/22-exit-137-not-oom](https://github.com/Arvo-AI/aurora-lab/tree/main/runs/search-2026-11-05/22-exit-137-not-oom) |

**Exit code 137 means the process was killed by SIGKILL: 128 plus signal number 9. It does not by itself mean the process ran out of memory, because the kernel OOM killer, the kubelet at the end of a grace period, `docker stop`, `docker kill` and a plain `kill -9` all produce it. In Kubernetes, read `lastState.terminated.reason`: `OOMKilled` means the kernel OOM killer, and `Error` with 137 means something else ended the container, such as a process that did not stop on SIGTERM before `terminationGracePeriodSeconds` ran out. In Docker, read `State.OOMKilled` in `docker inspect`.** Raise a memory limit only after that field says memory. For OOM causes and fixes, go to [OOMKilled](/runbooks/fix-oomkilled-kubernetes); this page covers telling the 137s apart.

```shell
kubectl get pod <pod> -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.lastState.terminated.reason}{"\t"}{.lastState.terminated.exitCode}{"\n"}{end}'
```

## At a glance

| Signal | Likely cause | Confirm with | Fix |
|---|---|---|---|
| `Reason: OOMKilled`, a memory limit is set | Container went over its limit | `oom` above 0 in the pod's `memory.events` | [OOMKilled runbook](/runbooks/fix-oomkilled-kubernetes) |
| `Reason: OOMKilled`, no limit set, `SystemOOM` event on the Node | The whole node ran out of memory | Kernel log: `Out of memory: Killed process`, `global_oom` | Set memory requests and limits, fix node capacity |
| `Reason: Error`, `Killing` event says `failed liveness probe` | Probe failed and the process did not stop on SIGTERM | `Unhealthy` and `Killing` events; `Finished` is one grace period after the kill | [Fix the probe](/runbooks/fix-liveness-probe-failed-kubernetes), handle SIGTERM |
| `kubectl delete` or a rollout takes exactly the grace period | Process ignores SIGTERM. Often no handler as PID 1, or a shell that does not forward it | containerd log shows `Kill container` | Handle SIGTERM, or `exec` from the shell |
| Logs show shutdown started, then stop | Drain takes longer than the grace period, or `preStop` used it up | App log; `FailedPreStopHook` event | Raise `terminationGracePeriodSeconds` to cover it |
| Pod `Reason: Evicted` | Node-pressure eviction | Pod `Message`, see [OOMKilled](/runbooks/fix-oomkilled-kubernetes) | Set requests near real usage |
| `Reason: Error`, 137, no `Killing` event, `oom_kill 0` | Something on the node sent SIGKILL, or the program returned 137 itself | Program's wrapper and the node's agents | Find the sender or the wrapper |
| `Reason: Error`, 137, `oom_kill` above 0 | An OOM kill recorded as `Error` | Pod's `memory.events`, kernel log | Treat as OOM |
| Docker `"OOMKilled":false`, 137 | `docker kill`, or `docker stop` past its timeout | `docker events`: `kill signal=9` | Handle SIGTERM, or `docker run --init` |

## What does exit code 137 mean?

A shell reports a process killed by a signal as 128 plus the signal number. The [Bash manual](https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html) says: "When a command terminates on a fatal signal whose number is N, Bash uses the value 128+N as the exit status." SIGKILL is signal 9, so 128 + 9 = 137. Container runtimes report the same number. You can make one in any shell:

```
$ bash -c 'sleep 100 & kill -9 $!; wait $!; echo status $?'
bash: line 1: 49507 Killed                  sleep 100
status 137
```

The number tells you how the process ended. It says nothing about who sent the signal or why. A process cannot catch SIGKILL, so it leaves no shutdown log line, and that is why these incidents look alike: the log stops mid-sentence and the exit code is 137.

## Is exit code 137 always out of memory?

No. On one cluster on 2026-11-05 we produced 137 from a container limit, a full node, a failed liveness probe, a `kubectl delete`, a SIGKILL from the node and a program that returned 137 without any signal. Only the first two involved memory. This matrix comes from one run, and it is the reason to check `reason` first:

| What ended the container | `reason` | Pod events | Pod `memory.events` on the node | containerd log |
|---|---|---|---|---|
| Over its memory limit | `OOMKilled` | Nothing about the kill | `oom 1`, `oom_kill 2`, `oom_group_kill 1` | `TaskOOM event` |
| Node out of memory, no limit | `OOMKilled` | `SystemOOM` on the Node | `oom 0`, `oom_kill 2`, `oom_group_kill 1` | Not captured |
| Liveness failure, SIGTERM not handled | `Error` | `Killing`: `failed liveness probe, will be restarted` | All 0 | `Stop container`, then `Kill container` 10 s later |
| `kubectl delete`, SIGTERM not handled | `Error`, then the pod is gone | `Killing`: `Stopping container app` | Not captured | `Stop container`, then `Kill container` 10 s later |
| `kill -9` from the node | `Error` | Nothing about the kill | All 0 | No stop or kill line |
| Program ran `exit 137` | `Error` | `BackOff` only | All 0 | No stop or kill line |

Our control was a process that handles SIGTERM. It failed the same liveness probe and ended with `Completed`, exit 0, in the same run. A probe kill is a 137 only when the process does not stop in time.

Three other facts decide which checks are worth running:

- **Kubernetes logs no event for a container OOM kill.** The pod's events showed only `Pulled`, `Created` and `Started`. Absence of an OOM event proves nothing, so read `reason`.
- **`reason` can be wrong in one direction.** Across three runs we forced 240 pods over their limit: 238 recorded `OOMKilled` and 2 recorded `Error`. That is the race described in [containerd issue #12260](https://github.com/containerd/containerd/issues/12260). A loaded host did worse (3 of 40, on the [OOMKilled page](/runbooks/fix-oomkilled-kubernetes)). We never saw the reverse, `OOMKilled` without a kill.
- **137 is sometimes just a return value.** Scripts that do `exit $?` pass on a child's status, so the signal may have hit a child, or nothing at all.

## How do you tell what killed the container?

Work from cheap to expensive, and stop when you have an answer.

**1. Read the reason.** Our real OOM kill and our liveness kill, same fields:

```
oom-limit	1	OOMKilled	137	2026-11-05T22:14:54Z	2026-11-05T22:15:14Z
worker-6df4dfbb9f-g5d8k	3	Error	137	2026-11-05T22:13:24Z	2026-11-05T22:13:44Z
```

(Columns: name, restarts, reason, exit code, started, finished. The same command on two pods.)

**2. Read the events, soon.** Events expire, so a kill from yesterday may have none left. The `shop` worker in [scenario 22](https://github.com/Arvo-AI/aurora-lab/tree/main/scenarios/22-exit-137-not-oom), after a release added a liveness probe on a file nothing writes:

```
    Last State:     Terminated
      Reason:       Error
      Exit Code:    137
      Started:      Thu, 05 Nov 2026 22:13:24 +0000
      Finished:     Thu, 05 Nov 2026 22:13:44 +0000
    Ready:          True
    Restart Count:  3
    Limits:
      memory:  192Mi
...
  Normal   Killing    16s (x3 over 56s)  kubelet            spec.containers{worker}: Container worker failed liveness probe, will be restarted
...
  Warning  Unhealthy  1s (x7 over 61s)   kubelet            spec.containers{worker}: Liveness probe failed:
```

(Trimmed where marked.) `kubectl top` showed the same worker at 3Mi against a 192Mi limit:

```
POD                       NAME     CPU(cores)   MEMORY(bytes)   
worker-6df4dfbb9f-g5d8k   worker   11m          3Mi             
```

**3. Read `memory.events` on the node, for the pod.** This is the one check that stays correct when `reason` is wrong. It has to be the pod's cgroup. The counter inside the container resets, because the replacement gets a new cgroup. On the same pod, seconds after a real OOM kill:

```
$ kubectl -n exit137 exec oom-limit -- cat /sys/fs/cgroup/memory.events
low 0
high 0
max 0
oom 0
oom_kill 0
oom_group_kill 0
sock_throttled 0
```

And the pod-level file on the node:

```
low 0
high 0
max 37
oom 1
oom_kill 2
oom_group_kill 1
sock_throttled 0
```

On a systemd-driver node, find it with the pod's UID, dashes replaced by underscores:

```shell
kubectl get pod <pod> -o jsonpath='{.metadata.uid}'
find /sys/fs/cgroup -type d -name '*pod<uid_with_underscores>*'
cat <that path>/memory.events
```

The [kernel documentation](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html) defines `oom_kill` as "The number of processes belonging to this cgroup killed by any kind of OOM killer." and `oom_group_kill` as "The number of times a group OOM has occurred." We got `oom_kill 2` for a single process and the kernel log printed its line twice, so count incidents with `oom_group_kill`. The pair also separates a limit from a full node: `oom 1` here, `oom 0` with `oom_kill 2` when the node ran out. A pod with `oom_kill 0` was not killed by the OOM killer, whatever else happened. The pod cgroup goes away with the pod.

We read this with `docker exec` on a kind node. On a real node use SSH or `kubectl debug node/<node> -it --profile=sysadmin --image=busybox:1.37`, then `chroot /host`; we did not run that form.

**4. Read the kernel log on the node.**

```shell
dmesg -T | grep -E 'oom-kill:|Killed process'
```

A container limit:

```
[  854.409421] oom-kill:constraint=CONSTRAINT_MEMCG,nodemask=(null),cpuset=cri-containerd-80d13a8258f81d944dbb2d39faaee7c4869d239353e1c85a690326ab66e63fd5.scope,mems_allowed=0,oom_memcg=/system.slice/docker-a2c2f06dc068d9b58055f3e8e590bcbebc9e514870d2d73d5af513fc22477423.scope/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepod
[  854.409494] Memory cgroup out of memory: Killed process 21786 (python) total-vm:164844kB, anon-rss:130124kB, file-rss:5440kB, shmem-rss:0kB, UID:0 pgtables:316kB oom_score_adj:992
```

A full node, with a pod that has no limit at all:

```
[ 1043.203744] oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=containerd.service,mems_allowed=0,global_oom,task_memcg=/system.slice/docker-e5ddbd8a44d43a9818d46eea775d414644d8ca647e87e3437aa1f042a7d48a91.scope/kubelet.slice/kubelet-kubepods.slice/kubelet-kubepods-besteffort.slice/kubelet-kubepods-besteffort-pod7bc8e21d_f03a_4212_8d53_b2cf6dc53aa9.slice/cri-containerd-44d7c72bde6c451a0c6c21fdb5afa0501b204f
[ 1043.203801] Out of memory: Killed process 50766 (python) total-vm:14347508kB, anon-rss:14331684kB, file-rss:8kB, shmem-rss:0kB, UID:0 pgtables:28112kB oom_score_adj:1000
```

(Long lines were cut at the right when captured.) `CONSTRAINT_MEMCG` with `Memory cgroup out of memory` is a limit. `CONSTRAINT_NONE`, `global_oom` and `Out of memory` is the node. In that second case the pod recorded `OOMKilled`, 137 and an empty `resources`, the node still said `MemoryPressure False`, and no pod was evicted, and the pod's last log line was `held 13800 MiB`, 7 seconds after it started. As the [eviction docs](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/) put it, "If the node experiences an out of memory (OOM) event prior to the kubelet being able to reclaim memory, the node depends on the oom_killer to respond." The only Kubernetes object that said so was a `SystemOOM` event on the Node:

```
default     3s          Warning   SystemOOM   node/aurora-lab-worker2         System OOM encountered, victim process: python, pid: 50766
```

(One of three lines. It appeared on all three kind nodes because they share one kernel; expect it on one node in a real cluster.)

**5. Read the containerd log on the node.** This is the only record we found that survives pod deletion and names the kill:

```shell
journalctl -u containerd --no-pager | grep <container-id>
```

## Why does kubectl delete or a rollout give exit code 137?

When a pod stops, the kubelet has the runtime send SIGTERM and wait. The [pod lifecycle docs](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/) say the default "`terminationGracePeriodSeconds` setting is 30 seconds" and "When the grace period expires, if there is still any container running in the Pod, the kubelet triggers forcible shutdown." That forced stop is the 137.

We deleted ten pods at once, each with `terminationGracePeriodSeconds: 10` and a 64Mi limit, and held them with a finalizer so their status could be read. `stop_seconds` is `finishedAt`, which has one-second resolution, minus the time of the delete, so small negatives are rounding.

```
case exit reason deletionTimestamp finishedAt stop_seconds
exec-handled 0 Completed 2026-11-05T22:15:52Z 2026-11-05T22:15:51Z -0.8
handled 0 Completed 2026-11-05T22:15:52Z 2026-11-05T22:15:52Z 0.2
no-handler 137 Error 2026-11-05T22:16:02Z 2026-11-05T22:16:02Z 10.2
prestop-long 0 Completed 2026-11-05T22:16:02Z 2026-11-05T22:16:02Z 10.2
prestop-slow 137 Error 2026-11-05T22:16:04Z 2026-11-05T22:16:04Z 12.2
sh-single 0 Completed 2026-11-05T22:15:52Z 2026-11-05T22:15:52Z 0.2
shared-pidns 143 Error 2026-11-05T22:15:53Z 2026-11-05T22:15:52Z 0.2
slow-drain 137 Error 2026-11-05T22:16:03Z 2026-11-05T22:16:02Z 10.2
trap-ignore 137 Error 2026-11-05T22:16:03Z 2026-11-05T22:16:02Z 10.2
wrapper-handled 137 Error 2026-11-05T22:16:03Z 2026-11-05T22:16:02Z 10.2
```

| Case | What it runs | Result | Why |
|---|---|---|---|
| `handled` | Python with a SIGTERM handler | 0, under 1 s | The baseline |
| `no-handler` | Python with no handler, as PID 1 | 137 at 10 s | PID 1 ignores signals it has no handler for |
| `trap-ignore` | Shell that traps SIGTERM and keeps looping | 137 at 10 s | The log shows it got the signal and carried on |
| `wrapper-handled` | `sh -c 'python app.py; echo done'`, app has a handler | 137 at 10 s | The shell is PID 1 and never forwards SIGTERM |
| `sh-single` | `sh -c 'python app.py'`, same app | 0, under 1 s | busybox ash replaced itself with the command, so the app got SIGTERM |
| `exec-handled` | `sh -c 'exec python app.py'` | 0, under 1 s | `exec` makes the app PID 1 |
| `shared-pidns` | `no-handler` with `shareProcessNamespace: true` | 143, under 1 s | The app is no longer PID 1, so the default action applies |
| `slow-drain` | Handler that needs 30 s | 137 at 10 s | Log shows `got SIGTERM, draining for 30 s` and no more |
| `prestop-long` | Handler, plus a 60 s `preStop` | 0 at 10 s | SIGTERM came when the grace period ended, app exited at once |
| `prestop-slow` | Same, handler needs 5 s | 137 at 12 s | Only the 2 s extension was left to drain in |

The case to remember is `no-handler`. Nothing in that program ignores SIGTERM on purpose. The [pid_namespaces man page](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html) states the rule: "Only signals for which the "init" process has established a signal handler can be sent to the "init" process by other members of the PID namespace." The same goes for a process in an ancestor namespace, except that "SIGKILL or SIGSTOP are treated exceptionally: these signals are forcibly delivered when sent from an ancestor PID namespace." So the same Python script that dies instantly on your laptop sits through SIGTERM in a container. Its only log line was `up`.

The rule also explains a test of ours: `kubectl exec` into a pod and SIGKILL PID 1 from inside, and nothing happens. Python printed `sent`, and the restart count stayed 0. The same signal from the node killed it.

The `prestop` rows match the docs, which say that "If the `preStop` hook is still running after the grace period expires, the kubelet requests a small, one-off grace period extension of 2 seconds." The hook did not hold SIGTERM back past the grace period, and the only trace was a `FailedPreStopHook` warning on the pod.

## How do you see the exit code of a deleted pod?

Normally you cannot. After a plain delete the status is gone with the object, and the event looks the same for a clean stop and a forced one:

```
$ time kubectl -n exit137 delete pod plain-delete
pod "plain-delete" deleted from exit137 namespace

real	0m10.525s
...
$ kubectl -n exit137 get pod plain-delete
Error from server (NotFound): pods "plain-delete" not found
...
13s         Normal   Killing     pod/plain-delete   Stopping container app
```

(Trimmed where marked.) The tell is the time: a delete or rollout that takes exactly the grace period for each pod. At kind's default log level, the kubelet log had no line about the stop. Three things did work:

The containerd log on the node, where a forced stop has a `Kill container` line that a clean stop does not:

```
time="2026-11-05T22:16:10.693943859Z" level=info msg="Stop container \"f71b93589fd641bab2654f938f34ebbb834f32bd8c2e376ddd2020c409dc4855\" with signal terminated"
time="2026-11-05T22:16:20.703813235Z" level=info msg="Kill container \"f71b93589fd641bab2654f938f34ebbb834f32bd8c2e376ddd2020c409dc4855\""
```

A watch started before the delete, which catches the last status. Note the `.object` in the path, needed with `--output-watch-events`:

```shell
kubectl get pod <pod> -w --output-watch-events -o jsonpath='{.type} {.object.status.phase} del={.object.metadata.deletionTimestamp} {.object.status.containerStatuses[0].state}{"\n"}'
```

```
MODIFIED Failed del=2026-11-05T22:16:20Z {"terminated":{"containerID":"containerd://f71b93589fd641bab2654f938f34ebbb834f32bd8c2e376ddd2020c409dc4855","exitCode":137,"finishedAt":"2026-11-05T22:16:20Z","reason":"Error","startedAt":"2026-11-05T22:14:54Z"}}
```

And a finalizer on a test pod, as we did for the table above. Use it only on a pod you created to test with: a finalizer you forget to remove leaves the pod `Terminating` forever. To release it:

```shell
kubectl patch pod <pod> --type merge -p '{"metadata":{"finalizers":null}}'
```

## What about 137 with no signal from Kubernetes at all?

Two more cases recorded the same fields, with no `Killing` event and all-zero `memory.events`:

```
host-kill	1	Error	137	2026-11-05T22:14:54Z	2026-11-05T22:16:27Z
plain-exit	3	Error	137	2026-11-05T22:15:17Z	2026-11-05T22:15:22Z
```

`host-kill` is a `kill -9` of the container's process from the node. `plain-exit` is `sh -c 'echo up; sleep 5; exit 137'`, with no signal involved. Kubernetes gave us no way to tell these two apart. If you land here, read the entrypoint for a wrapper that passes on a child's status, then look at what runs on the node with permission to kill: security agents, OOM daemons, cron jobs. A steady run time before each exit points at the program, as with `plain-exit`'s 5 seconds.

## Docker exit code 137

`docker inspect` holds the same split, and `docker events` is better than anything Kubernetes offers, because it records the signals.

```shell
docker inspect <container> --format '{{json .State}}'
docker events --since 1h --filter container=<container> --format '{{.Action}} signal={{index .Actor.Attributes "signal"}} exitCode={{index .Actor.Attributes "exitCode"}}'
```

Kernel OOM kill under `--memory 128m --memory-swap 128m`:

```
{"Status":"exited","Running":false,"Paused":false,"Restarting":false,"OOMKilled":true,"Dead":false,"Pid":0,"ExitCode":137,"Error":"","StartedAt":"2026-11-05T22:17:42.897005963Z","FinishedAt":"2026-11-05T22:17:43.061098118Z"}
```
```
oom signal= exitCode=
die signal= exitCode=137
```

`docker kill`, same exit code, no memory involved:

```
{"Status":"exited","Running":false,"Paused":false,"Restarting":false,"OOMKilled":false,"Dead":false,"Pid":0,"ExitCode":137,"Error":"","StartedAt":"2026-11-05T22:17:45.230840488Z","FinishedAt":"2026-11-05T22:17:46.338846314Z"}
```
```
kill signal=9 exitCode=
die signal= exitCode=137
```

`docker stop` on Python as PID 1 with no handler, taking the full default wait, then the same process under `docker run --init`:

```
real	0m10.098s
OOMKilled=false ExitCode=137 Status=exited
kill signal=15 exitCode=
kill signal=9 exitCode=
stop signal= exitCode=
die signal= exitCode=137
```
```
real	0m0.079s
OOMKilled=false ExitCode=143 Status=exited
kill signal=15 exitCode=
stop signal= exitCode=
die signal= exitCode=143
```

(Each trimmed to the `real` line, the state and the events after `start`.) The [docker stop reference](https://docs.docker.com/reference/cli/docker/container/stop/) gives the rule: "The main process inside the container will receive SIGTERM, and after a grace period, SIGKILL." The default wait on Linux is 10 seconds.

| What happened | `State.OOMKilled` | `ExitCode` | `docker events` |
|---|---|---|---|
| Kernel OOM kill of the main process | `true` | 137 | `oom`, then `die exitCode=137` |
| `docker kill` | `false` | 137 | `kill signal=9` |
| `docker stop` past the timeout | `false` | 137 | `kill signal=15`, `kill signal=9` |
| `docker stop`, with `--init` | `false` | 143 | `kill signal=15` only |
| Program ran `exit 137` | `false` | 137 | `die exitCode=137` only |
| OOM kills a child, shell exits 0 | `true` | 0 | `oom`, then `die exitCode=0` |
| OOM kills a child, shell passes on `$?` | `true` | 137 | Same kill, seen from the exit code |

Row six is worth a look. `OOMKilled` is true on a container that exited 0:

```
$ docker run --name x137-child --memory 128m --memory-swap 128m python:3.12-alpine sh -c 'cat /sys/fs/cgroup/memory.oom.group; python -c "b = b\"\\x01\" * (200 << 20)"; echo child exit $?; exit 0'
0
child exit 137
Killed
[exit 0]
OOMKilled=true ExitCode=0 Status=exited
```

Docker left `memory.oom.group` at 0, so the kernel killed only the child and the shell carried on. Kubernetes sets it to 1 (`cat /sys/fs/cgroup/memory.oom.group` printed `1` in our pod), so the whole container dies. Our Kubernetes version of this test recorded `OOMKilled`, 137, and the kernel log named the shell as well as Python:

```
[  854.409589] Memory cgroup out of memory: Killed process 21673 (sh) total-vm:1652kB, anon-rss:60kB, file-rss:880kB, shmem-rss:0kB, UID:0 pgtables:44kB oom_score_adj:992
```

The [kubelet setting `singleProcessOOMKill`](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/) turns that off; its default is false on cgroup v2.

Compose prints `app-1 exited with code 137` and gives no reason, so run `docker inspect` on the container.

## Exit code 137 outside containers

A kernel OOM kill of a child under a shell, in a 128M cgroup on the plain host:

```
$ sudo systemd-run --scope -q -p MemoryMax=128M -p MemorySwapMax=0 -p OOMPolicy=continue bash -c 'python3 -c "b = b\"\\x01\" * (300 << 20)"; echo python status $?'
/usr/bin/bash: line 1: 49723 Killed                  python3 -c "b = b\"\\x01\" * (300 << 20)"
python status 137
```

`Killed` is the shell's message for SIGKILL, not proof of OOM; our `kill -9` printed it too. The same kill under a systemd service says so directly in `journalctl -u <unit>`:

```
x137-demo.service: A process of this unit has been killed by the OOM killer.
```

(Timestamp and host prefix removed.) `docker build` depends on the builder. With a builder limited to 256 MiB, the same `RUN` step that allocates 600 MiB reported 137 only on the legacy builder (`DOCKER_BUILDKIT=0`). BuildKit, second below, did not show 137 at all:

```
The command '/bin/sh -c python -c "b = b'\x01' * (600 << 20); print('allocated')"' returned a non-zero code: 137
```
```
ERROR: failed to build: failed to solve: ResourceExhausted: process "/bin/sh -c python -c \"b = b'\\x01' * (600 << 20); print('allocated')\"" did not complete successfully: cannot allocate memory
```

## Fix: what to change for each cause

Mutating commands below change a live workload. Roll out through your normal path, and keep the previous manifest for rollback.

| Cause | Change | Risk | Rollback |
|---|---|---|---|
| OOM kill, either kind | Follow the [OOMKilled runbook](/runbooks/fix-oomkilled-kubernetes); a [leak](/runbooks/fix-memory-leak-oomkilled-kubernetes) or a [sidecar](/runbooks/fix-sidecar-container-oomkilled-kubernetes) has its own | A higher limit can mask a leak | Revert the limit |
| Bad liveness probe | Fix or remove the probe ([liveness probe failed](/runbooks/fix-liveness-probe-failed-kubernetes)) | Without a probe, a hung process stays up | `kubectl rollout undo deploy/<name>` |
| No SIGTERM handler | Add one that exits. This is the real fix for every `no-handler` case | Exiting early can drop requests in flight, so finish them first | Redeploy the old image |
| Shell wrapper | `exec` the app as the last line of the script | Commands after `exec` never run | Revert the entrypoint |
| Cannot change the image | Docker: `docker run --init`. Compose: `init: true`. Kubernetes: `shareProcessNamespace: true` gave a fast 143 in our test | Sharing the namespace exposes each container's `/proc` and files to the others in the pod, per the [docs](https://kubernetes.io/docs/tasks/configure-pod-container/share-process-namespace/), and some apps need PID 1 | Remove the field |
| Real drain longer than the grace period | Raise `terminationGracePeriodSeconds` above the measured drain | Slower rollouts and node drains | Revert the value |
| `preStop` eats the grace period | Set the grace period above `preStop` plus drain | Same | Revert the value |
| External SIGKILL | Find the sender on the node | Depends on the sender | n/a |

Raising `terminationGracePeriodSeconds` helps only the two drain rows. For a process that ignores SIGTERM it makes each stop take longer, and it still ends in 137. Raising memory does nothing for any row except the first.

The lab fix for scenario 22 was the rollback:

```
$ kubectl -n shop get pods -l app=worker
NAME                      READY   STATUS    RESTARTS   AGE
worker-6cf88d4b58-cl66w   1/1     Running   0          60s
```

## Verify: what counts as fixed?

- **Restarts:** the restart count does not move for longer than two of the old cycles. In the lab a cycle was 20 s, so 60 s at 0 restarts passed.
- **Stops:** `time kubectl delete pod <pod>` on a test pod, or one replica, finishes well under the grace period. Our forced stop took 10.5 s; pods that handled SIGTERM finished in under a second.
- **Exit code:** the last state after a planned stop reads 0, or 143 if the app dies on the default action. Neither should be 137.
- **Docker:** `time docker stop <container>` no longer takes 10 s.

## Prevent: an alert that separates the two

This query needs kube-state-metrics. We did not run it in the lab, which has no kube-state-metrics; the names are from its [pod metrics docs](https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/pod-metrics.md), which mark the two `last_terminated` metrics experimental.

```
(
  kube_pod_container_status_last_terminated_exitcode == 137
  unless on (namespace, pod, container)
  kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
)
and on (namespace, pod, container)
increase(kube_pod_container_status_restarts_total[15m]) > 0
```

That fires on restarts with 137 that were not recorded as OOM. It will not see stops from a delete, since the pod is gone; for those, test shutdown directly. In CI, start the image, run `docker stop`, and fail the build if it exits 137 or takes the full timeout. That one check catches `no-handler` and `wrapper-handled` before they reach a cluster.

## Common mistakes

- **Raising the memory limit on any 137.** Our worker used 3Mi of 192Mi. More memory would have changed nothing.
- **Reading `memory.events` inside the replacement container.** It printed `oom_kill 0` seconds after a real kill.
- **Trusting `Killing` as a sign of a forced stop.** That event means the stop began. Every pod in our table got one, including the ones that exited 0 and the `probe-handled` control.
- **Assuming `exec` alone fixes it.** It makes your app PID 1. Without a handler, that is exactly the `no-handler` case.
- **Assuming no `OOMKilled` means no OOM.** Check `oom_kill` on the pod before ruling it out.
- **Assuming `Killed` in a shell means memory.** Any SIGKILL prints it.
- **Ignoring 137 during rollouts because it stops by itself.** A SIGKILL mid-request drops what the process was doing, on every deploy.

## What we saw in the lab

We ran the scenario three times on fresh GitHub Actions clusters. The selftest passed each time. Every output block above is from the last run; the first two are kept in the run folder.

- **OOM reason tally:** 80 of 80, 79 of 80 and 79 of 80 recorded `OOMKilled`, so 238 of 240, on a quiet runner. The kernel printed two lines per kill in five of six rounds; one round had 71 lines for 40 pods, so we would not count kills from `dmesg` alone.
- **We were wrong twice.** We expected a long `preStop` to force a 137 by itself. It did not: the app got SIGTERM at 10 s and exited 0, and we added `prestop-slow` to find the real boundary. And our second "node OOM" run was not one: `docker update --memory 0` does not clear a limit, so the node was still capped. The kernel line `CONSTRAINT_MEMCG` gave it away, and only the third run produced `global_oom`.
- **The node OOM ran on a test runner**, with swap off and one pod taking 13,800 MiB. Node-pressure eviction was not reproduced in this batch; the run is on the [OOMKilled page](/runbooks/fix-oomkilled-kubernetes).
- **The only shell we tested** is busybox ash. Do not assume `sh-single` behaves the same under another shell; test your image.

The Aurora, HolmesGPT and K8sGPT investigations have not been run on this scenario, so we have no result to report for any of them. The obvious trap is the exit code: the scripted alert says 137, the worker has a memory limit, and the right answer has nothing to do with memory.

## How Aurora handles this

Aurora receives the alert and investigates with read-only kubectl under its default `observability_only` command policy, choosing the commands itself. For a 137 it would need the same evidence as this page, and `reason`, events and pod specs are all reachable that way. The node-level checks here (`memory.events`, the kernel log, the containerd log) need node access, and we have not tested how Aurora does on them. It records every tool call and its output, cites them in the report and lists suggested fixes separately; mutating commands are blocked by default, so it proposes the change and does not apply it.

- **Start free:** [aurora-ai.net](https://aurora-ai.net/) (hosted, no infrastructure to run)
- **GitHub:** [github.com/Arvo-AI/aurora](https://github.com/Arvo-AI/aurora)
- **Book a demo:** [cal.com/arvo-ai/demo](https://cal.com/arvo-ai/demo)

Related: [OOMKilled](/runbooks/fix-oomkilled-kubernetes), [liveness probe failed](/runbooks/fix-liveness-probe-failed-kubernetes), [CrashLoopBackOff by exit code](/blog/fix-crashloopbackoff-kubernetes), [memory leak](/runbooks/fix-memory-leak-oomkilled-kubernetes), [sidecar OOMKilled](/runbooks/fix-sidecar-container-oomkilled-kubernetes), [paste your kubectl output into the diagnoser](/diagnose), and the [root cause analysis guide for SREs](/blog/root-cause-analysis-complete-guide-sres).

## Sources and verification

- Lab scenario: `scenarios/22-exit-137-not-oom` (`break.sh`, `check.sh`, `repro.sh`, `causes/`). Output is from Actions run 42118907407 on 2026-11-05, in `runs/search-2026-11-05/22-exit-137-not-oom`; `CANONICAL.txt` there lists all three runs. Where a block was cut, it says so; `time` output is shown without `user` and `sys`.
- Our `[exit N]` lines and `x137-` names come from the repro script's transcript format.
- Linux: [cgroup v2](https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html), [pid_namespaces(7)](https://man7.org/linux/man-pages/man7/pid_namespaces.7.html). Bash: [Exit Status](https://www.gnu.org/software/bash/manual/html_node/Exit-Status.html).
- Kubernetes: [Pod Lifecycle](https://kubernetes.io/docs/concepts/workloads/pods/pod-lifecycle/), [Node-pressure Eviction](https://kubernetes.io/docs/concepts/scheduling-eviction/node-pressure-eviction/), [Share Process Namespace](https://kubernetes.io/docs/tasks/configure-pod-container/share-process-namespace/), [Kubelet configuration](https://kubernetes.io/docs/reference/config-api/kubelet-config.v1beta1/).
- Docker: [docker stop](https://docs.docker.com/reference/cli/docker/container/stop/), [docker run](https://docs.docker.com/reference/cli/docker/container/run/) (`--init`, PID 1 signals). [containerd issue #12260](https://github.com/containerd/containerd/issues/12260). [kube-state-metrics pod metrics](https://github.com/kubernetes/kube-state-metrics/blob/main/docs/metrics/workload/pod-metrics.md).
- Checked 2026-11-05.

