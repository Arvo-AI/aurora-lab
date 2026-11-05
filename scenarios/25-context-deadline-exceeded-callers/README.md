# context deadline exceeded Kubernetes: meaning and how to fix it

Lab scenario for the runbook at https://www.aurorasre.ai/runbooks/fix-context-deadline-exceeded-kubernetes (canonical version, with its byline).

## Reproduce it

```
./lab.sh up
./lab.sh break 25-context-deadline-exceeded-callers
```

The fault: an api release makes `/healthz` call an address that drops packets, with no timeout. The kubelet's 1 s probe deadline fires, new pods never get Ready, and the rollout stalls while the old pods keep serving. `scenario.yaml` holds the ground truth and grading criteria.

`repro.sh` runs after the fault is injected and captures each caller that raises this error, writing one file per section to `$OUT`: probes, admission webhooks (`hook.py`), kubectl, etcdctl, Prometheus, Docker (`silent.py`), Helm, Go (`repro-go/`) and image pulls (`silent.py`, `stall_registry.py`). Set `ONLY="probes webhook"` to run some sections.

Run it through `.github/workflows/repro.yml`. Captured output is in `runs/search-2026-11-05/25-context-deadline-exceeded-callers/`: `run2` is the run the page quotes. `run1` is the first run, whose `break.sh` had an indentation bug, so its selftest failed and its `scenario.txt` shows a healthy app; its other sections are valid.

The Aurora, HolmesGPT and K8sGPT investigations have not been run on this scenario.
