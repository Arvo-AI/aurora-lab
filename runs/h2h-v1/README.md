# Head-to-head run v1 (2026-10-15)

HolmesGPT 0.43.0 and K8sGPT 0.4.40 on all 19 scenarios, one repeat each, on the
same kind cluster and faults as Aurora's v0-run2 and v1-run1. Runner:
`runner/h2h-matrix.sh runs/h2h-v1 r1`, grading `runner/grade_h2h.py` with the
judge prompt from `runner/grade.py` (us.anthropic.claude-opus-5-5). Verdicts
are judge-only until a person fills `human_verdict`.

Models: HolmesGPT on bedrock/us.anthropic.claude-sonnet-5 (same as Aurora).
K8sGPT on us.anthropic.claude-sonnet-4-5 because it always sends `temperature`,
which Bedrock Converse rejects for Sonnet 5.

Reruns, both recorded in `logs/`: scenario 19 `break.sh` hit a TLS handshake
timeout against the kind API server on the first pass and was rerun; scenario
18 HolmesGPT hit a Bedrock timeout (litellm) on the first pass and was rerun.
Original outputs were replaced.

Totals (judge): HolmesGPT 14 correct, 4 partial, 1 wrong. K8sGPT 0 correct,
11 partial, 8 wrong or "No problems detected". Aurora (human reviewed, 2 repeats):
34 correct, 4 partial of 38. The table is `benchmark/results.json` and
aurorasre.ai/benchmark.
