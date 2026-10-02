# Lab run v0-run1

Aurora commit `87d22bafa7`, RCA model `bedrock/us.anthropic.claude-sonnet-5`, orchestrator false. Judge `us.anthropic.claude-opus-5-5`.
Images: not recorded.
Repeats: 1. Clusters: aurora-lab. Isolation: shared org.

Totals: correct 9, partial 1. Total cost $6.31 (Aurora only, judge not included).

| Scenario | Correct | Verdicts | Median time | Median cost |
|---|---|---|---|---|
| 01-worker-oom | 1/1 | correct | 95s | $0.29 |
| 02-sidecar-oom | 1/1 | correct | 136s | $0.39 |
| 03-bad-image-tag | 1/1 | correct | 136s | $0.36 |
| 04-missing-secret | 1/1 | correct | 206s | $0.58 |
| 05-nginx-config-error | 1/1 | correct | 168s | $0.32 |
| 06-liveness-wrong-port | 1/1 | correct | 157s | $0.49 |
| 07-service-selector-mismatch | 1/1 | correct | 126s | $0.44 |
| 08-unschedulable-cpu | 1/1 | correct | 156s | $0.46 |
| 09-redis-pvc-pending | 0/1 | partial | 886s | $2.61 |
| 10-wrong-redis-host | 1/1 | correct | 147s | $0.39 |
| **total** | **9/10** | | 152s | $0.41 |

| Run | Verdict (report only) | Verdict (full output) | Fix (suggestions) | Time | Tool calls | Cost | Prior incidents seen |
|---|---|---|---|---|---|---|---|
| 01-worker-oom | correct (judge) | correct | - | 95s | 11 | $0.29 | - |
| 02-sidecar-oom | correct (judge) | correct | - | 136s | 15 | $0.39 | - |
| 03-bad-image-tag | correct (judge) | correct | - | 136s | 15 | $0.36 | - |
| 04-missing-secret | correct (judge) | correct | - | 206s | 24 | $0.58 | - |
| 05-nginx-config-error | correct (judge) | correct | - | 168s | 15 | $0.32 | - |
| 06-liveness-wrong-port | correct (judge) | correct | - | 157s | 15 | $0.49 | - |
| 07-service-selector-mismatch | correct (judge) | correct | - | 126s | 19 | $0.44 | - |
| 08-unschedulable-cpu | correct (judge) | correct | - | 156s | 14 | $0.46 | - |
| 09-redis-pvc-pending | partial (judge) | correct | - | 886s | 45 | $2.61 | - |
| 10-wrong-redis-host | correct (judge) | correct | - | 147s | 17 | $0.39 | - |

Verdicts marked (judge) have not been reviewed by a person yet. "AI review" is a second model's reading where it disagrees with the judge; it read only the report. "Full output" is the judge on the report, notes, suggestions and last chat message (runner/grade_full.py). "Fix" grades the suggested next steps (runner/grade_fixes.py).
