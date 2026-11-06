# 27: on-call tools, hands-on

Not a fault scenario. No Kubernetes. `repro.sh` installs each self-hostable on-call
tool with docker compose on a GitHub runner and sends every tool the same webhook
body, captured from a real Alertmanager.

Run it:

    gh workflow run repro.yml -R Arvo-AI/aurora-lab -f ref=<branch> -f scenario=27 -f kind=false

`tools.list` picks the tools for a run. The job has a 45 minute limit, so the set
was split over three runs (run ids in the folder names); all are under `runs/search-2026-11-05/27-oncall-tools-handson/`.

Protocol for each tool, in `harness/lib.py`:

- A. POST the firing payload unchanged, and list what the tool created.
- B. POST the same bytes again (what Alertmanager does on repeat_interval), and list again.
- C. POST the resolved payload, and list again.
- D. Build a two-person rotation and a two-step escalation with a 1 minute timeout,
  fire again, and record when each person is notified. Delivery goes to a local sink
  (webhook) or Mailpit (email). No SMS, voice or push was tested.

Each tool's raw HTTP and shell output is in `<tool>/transcript.log`, the extracted
numbers in `<tool>/result.json`. Timings come from one run on a 4 vCPU, 16 GB runner.

The final LinkedIn Oncall and Iris run never got past HTTP 401 Application not found on the seeded applications, so no webhook behaviour was observed for it.
