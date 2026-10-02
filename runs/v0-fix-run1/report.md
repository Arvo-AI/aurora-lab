# Lab run v0-fix-run1

Aurora commit `b509eaee4f`, RCA model `bedrock/us.anthropic.claude-sonnet-5`, orchestrator false. Judge `us.anthropic.claude-opus-5-5`.
Images: `aurora_lab_server:fix` (b3f656ac73a8), `aurora_lab_celery-worker:fix` (b3f656ac73a8), `aurora_lab_chatbot:fix` (b3f656ac73a8).
Repeats: 2. Clusters: aurora-lab, aurora-lab-2, aurora-lab-3. Isolation: fresh user and org per (scenario, repeat).

Totals: correct 6. Total cost $2.24 (Aurora only, judge not included).

| Scenario | Correct | Verdicts | Median time | Median cost |
|---|---|---|---|---|
| 05-nginx-config-error | 2/2 | correct, correct | 145s | $0.36 |
| 09-redis-pvc-pending | 2/2 | correct, correct | 182s | $0.44 |
| 10-wrong-redis-host | 2/2 | correct, correct | 100s | $0.32 |
| **total** | **6/6** | | 145s | $0.38 |

| Run | Verdict (report only) | Verdict (full output) | Fix (suggestions) | Time | Tool calls | Cost | Prior incidents seen |
|---|---|---|---|---|---|---|---|
| 05-nginx-config-error/r1 | correct | correct | acceptable | 162s | 16 | $0.37 | clean |
| 05-nginx-config-error/r2 | correct | correct | acceptable | 128s | 14 | $0.35 | clean |
| 09-redis-pvc-pending/r1 | correct | correct | acceptable | 195s | 20 | $0.47 | clean |
| 09-redis-pvc-pending/r2 | correct | correct | acceptable | 170s | 20 | $0.42 | clean |
| 10-wrong-redis-host/r1 | correct | correct | acceptable | 119s | 17 | $0.39 | clean |
| 10-wrong-redis-host/r2 | correct | correct | acceptable | 80s | 13 | $0.24 | clean |

Verdicts marked (judge) have not been reviewed by a person; the others are `human_verdict`. "AI review" is a second model's reading where it disagrees with the judge; it read only the report. "Full output" is the judge on the report, notes, suggestions and last chat message (runner/grade_full.py). "Fix" grades the suggested next steps (runner/grade_fixes.py).
