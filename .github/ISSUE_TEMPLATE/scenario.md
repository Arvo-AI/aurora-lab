---
name: "Scenario: a new way to break the cluster"
about: Propose a new fault for the lab
title: "Scenario <nn>-<short-name>: <what breaks>"
labels: scenario
---

**Fault:** what changes, in one sentence.

**Symptom:** what `kubectl` shows; which alert fires.

**Root cause a correct answer must name.**

See `scenarios/01-worker-oom` for the contract: `scenario.yaml`, `break.sh`, `check.sh`.
