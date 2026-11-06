# Connection reset by peer: meaning and how to fix it

Runbook for lab scenario `24-connection-reset-by-peer`. Canonical version: https://www.aurorasre.ai/runbooks/fix-connection-reset-by-peer-kubernetes.

## Reproduce it

```
./lab.sh up
./lab.sh break 24-connection-reset-by-peer
```

Then investigate with any tool you like; `scenario.yaml` holds the ground truth and the grading criteria.

`repro.sh` runs after the fault, builds the test image in `causes/` and captures every case on the page to `$OUT/rst/`, with tcpdump on the client and, for case 09, on the server. Dispatched with `kind=false` it runs only the plain Docker ssh cases in `causes/ssh-docker.sh`. It runs in GitHub Actions (`.github/workflows/repro.yml`); transcripts are in `runs/search-2026-11-05/24-connection-reset-by-peer/`.

The Aurora, HolmesGPT and K8sGPT investigations have not been run on this scenario.
