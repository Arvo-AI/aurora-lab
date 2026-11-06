Actions runs on Arvo-AI/aurora-lab, workflow repro.yml, branch repro/fix-connection-reset-by-peer-kubernetes.

- Top level: run 42133263325 (commit d68b18b), the run the page quotes. 2026-11-05 23:57 to 2026-11-06 00:22 UTC.
- 11-ssh-docker.txt: run 42136493311, dispatched with kind=false, plain Docker.
- earlier-run/: run 42130110881 (commit 4543665), same load and sweep code; kept so results are not cherry-picked. 00-shop-scenario-run0.txt is run 42121660001, which timed out in a repro.sh wait bug after its scenario step.
