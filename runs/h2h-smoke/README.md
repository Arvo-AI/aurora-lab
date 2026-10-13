# Head-to-head smoke run: Aurora vs HolmesGPT vs K8sGPT (2026-10-13)

One scenario, one run per tool, to prove the harness before the full matrix.
Scenario `03-bad-image-tag`: the frontend Deployment was set to `nginx:1.27-alpne`
(typo), the new ReplicaSet's pod sits in ImagePullBackOff, the old ReplicaSet
keeps serving. A correct answer names both facts (`scenarios/03-bad-image-tag/scenario.yaml`).

| Tool | Version | Model | Input | Time | Verdict against `must_identify` |
|---|---|---|---|---|---|
| Aurora | commit 87d22baf (run v0-run2, 2026-10-02) | bedrock/us.anthropic.claude-sonnet-5 | alert text + read-only kubectl | 101 s / 77 s (r1 / r2) | correct, correct (human reviewed) |
| HolmesGPT | 0.43.0 | bedrock/us.anthropic.claude-sonnet-5 | alert text, `holmes ask`, default toolsets | 26 s | correct: typo tag, rollout stuck, old ReplicaSet still serving, fix given |
| K8sGPT | 0.4.40 | bedrock us.anthropic.claude-sonnet-4-5-20250929-v1:0 (see note) | `k8sgpt analyze --explain --namespace shop` | 19 s | partial: typo tag found; did not say the old pods still serve; second finding wrong ("isn't passing health checks") |

Files: `03-bad-image-tag/holmes.md`, `k8sgpt.txt`, `k8sgpt.json`, `*.meta.json`.
Aurora's trace for the same scenario: `runs/v0-run2/03-bad-image-tag/`.

## What is not comparable yet

- **Model.** K8sGPT always sends `temperature`; Bedrock Converse rejects that for
  Sonnet 5 ("temperature is deprecated for this model"), so K8sGPT ran on Sonnet
  4.5. HolmesGPT and Aurora ran on Sonnet 5.
- **Input.** K8sGPT has no notion of an alert: it scans the namespace with its
  analyzers and explains each finding. HolmesGPT and Aurora start from the alert
  text.
- **Steps.** HolmesGPT's run hit one tool call it would not execute without
  approval (a compound `kubectl` pipeline); it recovered with its tabular query
  tool. Aurora runs under the `observability_only` policy.
- **n = 1.** One run per tool, one scenario, no judge model yet. The full matrix
  is 19 scenarios times 2 repeats per tool, graded with `runner/grade.py` on each
  tool's final text.

## How to rerun

```
./lab.sh up && ./lab.sh break 03-bad-image-tag
./runner/h2h.sh 03-bad-image-tag runs/h2h-smoke
./lab.sh reset
```

Needs `k8sgpt` (brew), `holmes` (`uv tool install holmesgpt`), and AWS
credentials with Bedrock access (`AWS_PROFILE`, `AWS_REGION=us-east-1`).
K8sGPT backend: `k8sgpt auth add -b amazonbedrockconverse -m <model> -r us-east-1`.
