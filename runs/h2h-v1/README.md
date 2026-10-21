# Head-to-head run v1 (2026-10-15)

HolmesGPT 0.43.0 and K8sGPT 0.4.40 on all 19 scenarios, two repeats each (r1 on 2026-10-15, r2 on 2026-10-16), on the
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

Totals (judge, 38 runs per tool): HolmesGPT 31 correct, 6 partial, 1 wrong.
K8sGPT 0 correct, 21 partial, 5 wrong, 12 "No problems detected". A second model
(us.anthropic.claude-sonnet-5, `runner/review_h2h.py`) read every grade next to
the judge's and agreed with all 76; see `review-summary.md`. A third pass
(`review2-summary.md`, 2026-10-19) graded all 76 from scratch without seeing the
judge's grade: it agreed on all 38 HolmesGPT verdicts and disputed 6 K8sGPT
labels (symptom-only answers the judge called partial or wrong, the reviewer
no_answer). The judge's labels stand. `human_verdict` is still empty.

What each tool was asked. HolmesGPT got the scenario's alert text followed by
"Namespace shop, cluster kind-aurora-lab. Find the root cause and say what
changed." (`runner/h2h.sh`). Aurora got the same alert text followed by
"Cluster: aurora-lab (kubeconfig). Investigate and find the root cause."
(`runner/run.py`). K8sGPT got no alert; `k8sgpt analyze --explain --namespace
shop` scans the namespace.

Timing. HolmesGPT's `seconds` is the wall time of one `holmes ask`. K8sGPT's
`seconds` covers two `k8sgpt analyze --explain` passes (JSON, then text), so it
is about twice a single run. Aurora's `duration_seconds` comes from its own
timeline and includes the lab contention described in REPORT.md.

Correction (2026-10-21). The judge's grade for r1/18 K8sGPT quoted a pod name
(`api-77b4b6956f-gr92w`) that is not in the run's `k8sgpt.txt`. Cause: scenario
18 was first run at 09:24 on 2026-10-15, HolmesGPT timed out, K8sGPT did not;
the whole scenario was rerun at 17:40 and both outputs replaced, but the K8sGPT
grade written for the first output was kept because `grade_h2h.py` skips
existing grade files. The first-pass grade is kept in
`logs/18-r1-k8sgpt.grade.first-pass.json`; the output it graded was not saved.
The run's actual output was graded on 2026-10-21 with the same judge and
prompt: partial again, evidence now quotes the file. Totals unchanged.
Aurora (human reviewed, 2 repeats, 2026-10-02): 34 correct, 4 partial of 38.
The table is `benchmark/results.json` and aurorasre.ai/benchmark.

Blind check (2026-10-21). `runner/grade_blind.py` graded all 114 answers
(Aurora's 38 too) again with the same judge and prompt but with the agent's
name, its tool names, the cluster name and the K8sGPT stand-in sentence
removed. Blind verdict equals the published one in 38 of 38 for Aurora, 37 of
38 for HolmesGPT (r2/19 correct to partial, for the mechanism error the judge
had already noted), 36 of 38 for K8sGPT (r1/05 partial to no_answer, r1/18
partial to wrong). All three moved down. The blind judge still called r1/18
"generic k8sgpt-style output", so the format identifies K8sGPT even with the
name gone. Published verdicts are unchanged; the blind grades sit next to each
run as `*.blind.grade.json` and the list is `runs/blind-regrade.md`.
