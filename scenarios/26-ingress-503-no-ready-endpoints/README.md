# 503 Service Temporarily Unavailable nginx

Runbook for lab scenario `26-ingress-503-no-ready-endpoints`. Canonical version, with its byline, kept current: https://www.aurorasre.ai/runbooks/fix-503-service-temporarily-unavailable-nginx-kubernetes.

## Reproduce it

```
./lab.sh up
./lab.sh break 26-ingress-503-no-ready-endpoints
```
Then investigate with any tool you like; `scenario.yaml` holds the ground truth and the grading criteria. `repro.sh` is what produced the page's transcripts: it runs in the `Repro` workflow after the fault is injected, and writes to `$OUT`. `causes/causes.yaml` holds the other 503 cases (namespace `r503`), and `causes/others.sh` repeats them on Envoy Gateway, NGINX Gateway Fabric and Traefik.
