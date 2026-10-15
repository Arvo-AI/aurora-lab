---
name: "Benchmark: add an agent"
about: Put another AI SRE agent on the aurorasre.ai/benchmark board
title: "Benchmark: <agent name>"
labels: benchmark
---

**Agent:** name, repo, version.

**How to run it on one scenario.** A command or script that receives the alert text (see `scenarios/*/scenario.yaml`, field `alert`) and a kubeconfig with read-only access, and prints the root cause analysis to stdout. See `runner/h2h.sh` for how HolmesGPT and K8sGPT are run.

**Model.** Which LLM and provider. We run every agent on Bedrock Claude Sonnet 5 when the agent supports it, and record the model used otherwise.

We run it on all 19 scenarios, grade it with the same judge prompt (`runner/grade.py`), have a person check the verdicts, and publish the result, whatever it is.
