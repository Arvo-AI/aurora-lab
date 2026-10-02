# Lab run v0-run2

Aurora commit `87d22bafa7`, RCA model `bedrock/us.anthropic.claude-sonnet-5`, orchestrator false. Judge `us.anthropic.claude-opus-5-5`.
Images: `aurora_lab_server:87d22baf` (bd2669168458), `aurora_lab_celery-worker:87d22baf` (67ea14b53c9a), `aurora_lab_chatbot:87d22baf` (2d7e0dc6483c).
Repeats: 2. Clusters: aurora-lab, aurora-lab-2, aurora-lab-3. Isolation: fresh user and org per (scenario, repeat).

Totals: correct 20. Total cost $6.44 (Aurora only, judge not included).

| Scenario | Correct | Verdicts | Median time | Median cost |
|---|---|---|---|---|
| 01-worker-oom | 2/2 | correct, correct | 160s | $0.30 |
| 02-sidecar-oom | 2/2 | correct, correct | 90s | $0.25 |
| 03-bad-image-tag | 2/2 | correct, correct | 89s | $0.22 |
| 04-missing-secret | 2/2 | correct, correct | 164s | $0.42 |
| 05-nginx-config-error | 2/2 | correct, correct | 136s | $0.32 |
| 06-liveness-wrong-port | 2/2 | correct, correct | 105s | $0.32 |
| 07-service-selector-mismatch | 2/2 | correct, correct | 156s | $0.46 |
| 08-unschedulable-cpu | 2/2 | correct, correct | 226s | $0.28 |
| 09-redis-pvc-pending | 2/2 | correct, correct | 280s | $0.39 |
| 10-wrong-redis-host | 2/2 | correct, correct | 244s | $0.28 |
| **total** | **20/20** | | 136s | $0.32 |

| Run | Verdict (report only) | Verdict (full output) | Fix (suggestions) | Time | Tool calls | Cost | Prior incidents seen |
|---|---|---|---|---|---|---|---|
| 01-worker-oom/r1 | correct | correct | acceptable | 91s | 12 | $0.25 | clean |
| 01-worker-oom/r2 | correct | correct | acceptable | 228s | 14 | $0.35 | clean |
| 02-sidecar-oom/r1 | correct | correct | acceptable | 82s | 10 | $0.19 | clean |
| 02-sidecar-oom/r2 | correct | correct | acceptable | 98s | 12 | $0.30 | clean |
| 03-bad-image-tag/r1 | correct | correct | acceptable | 101s | 13 | $0.24 | clean |
| 03-bad-image-tag/r2 | correct | correct | acceptable | 77s | 11 | $0.19 | clean |
| 04-missing-secret/r1 | correct | correct | none | 194s | 18 | $0.48 | clean |
| 04-missing-secret/r2 | correct | correct | acceptable | 133s | 17 | $0.35 | clean |
| 05-nginx-config-error/r1 | correct | correct | acceptable | 120s | 13 | $0.27 | clean |
| 05-nginx-config-error/r2 | correct | correct | acceptable | 152s | 16 | $0.36 | clean |
| 06-liveness-wrong-port/r1 | correct | correct | acceptable | 123s | 14 | $0.35 | clean |
| 06-liveness-wrong-port/r2 | correct | correct | acceptable | 87s | 12 | $0.28 | clean |
| 07-service-selector-mismatch/r1 | correct / AI review: partial | correct | acceptable | 175s | 22 | $0.52 | clean |
| 07-service-selector-mismatch/r2 | correct | correct | acceptable | 138s | 15 | $0.40 | clean |
| 08-unschedulable-cpu/r1 | correct | correct | acceptable | 362s | 14 | $0.35 | clean |
| 08-unschedulable-cpu/r2 | correct | correct | acceptable | 89s | 10 | $0.21 | clean |
| 09-redis-pvc-pending/r1 | correct | correct | acceptable | 406s | 14 | $0.30 | clean |
| 09-redis-pvc-pending/r2 | correct | correct | none | 155s | 19 | $0.47 | clean |
| 10-wrong-redis-host/r1 | correct | correct | acceptable | 292s | 12 | $0.23 | clean |
| 10-wrong-redis-host/r2 | correct | correct | acceptable | 197s | 16 | $0.34 | clean |

Verdicts marked (judge) have not been reviewed by a person; the others are `human_verdict`. "AI review" is a second model's reading where it disagrees with the judge; it read only the report. "Full output" is the judge on the report, notes, suggestions and last chat message (runner/grade_full.py). "Fix" grades the suggested next steps (runner/grade_fixes.py).
