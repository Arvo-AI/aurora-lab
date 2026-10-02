# Lab run v1-run1

Aurora commit `87d22bafa7`, RCA model `bedrock/us.anthropic.claude-sonnet-5`, orchestrator false. Judge `us.anthropic.claude-opus-5-5`.
Images: `aurora_lab_server:87d22baf` (bd2669168458), `aurora_lab_celery-worker:87d22baf` (67ea14b53c9a), `aurora_lab_chatbot:87d22baf` (2d7e0dc6483c).
Repeats: 2. Clusters: aurora-lab, aurora-lab-2, aurora-lab-3. Isolation: fresh user and org per (scenario, repeat).

Totals: correct 14, partial 4. Total cost $8.09 (Aurora only, judge not included).

| Scenario | Correct | Verdicts | Median time | Median cost |
|---|---|---|---|---|
| 11-noisy-worker-svc-targetport | 1/2 | correct, partial | 340s | $0.51 |
| 12-two-faults-oom-and-selector | 0/2 | partial, partial | 344s | $0.34 |
| 13-networkpolicy-blocks-redis | 2/2 | correct, correct | 323s | $0.61 |
| 14-resourcequota-rollout | 2/2 | correct, correct | 126s | $0.32 |
| 15-stray-pods-share-label | 2/2 | correct, correct | 146s | $0.47 |
| 16-dns-search-domain | 2/2 | correct, correct | 172s | $0.48 |
| 17-slow-memory-leak | 2/2 | correct, correct | 144s | $0.25 |
| 18-init-waits-missing-service | 2/2 | correct, correct | 159s | $0.44 |
| 19-config-drift-partial-restart | 1/2 | partial, correct | 266s | $0.61 |
| **total** | **14/18** | | 168s | $0.40 |

| Run | Verdict (report only) | Verdict (full output) | Fix (suggestions) | Time | Tool calls | Cost | Prior incidents seen |
|---|---|---|---|---|---|---|---|
| 11-noisy-worker-svc-targetport/r1 | correct | correct | acceptable | 144s | 19 | $0.44 | clean |
| 11-noisy-worker-svc-targetport/r2 | partial | partial | acceptable | 535s | 16 | $0.57 | clean |
| 12-two-faults-oom-and-selector/r1 | partial | partial | partial | 140s | 18 | $0.36 | clean |
| 12-two-faults-oom-and-selector/r2 | partial | partial | partial | 548s | 14 | $0.32 | clean |
| 13-networkpolicy-blocks-redis/r1 | correct | correct | acceptable | 202s | 25 | $0.69 | clean |
| 13-networkpolicy-blocks-redis/r2 | correct | correct | acceptable | 444s | 19 | $0.54 | clean |
| 14-resourcequota-rollout/r1 | correct | correct | acceptable | 108s | 14 | $0.24 | clean |
| 14-resourcequota-rollout/r2 | correct | correct | acceptable | 144s | 19 | $0.39 | clean |
| 15-stray-pods-share-label/r1 | correct | correct | acceptable | 175s | 24 | $0.59 | clean |
| 15-stray-pods-share-label/r2 | correct | correct | acceptable | 118s | 17 | $0.35 | clean |
| 16-dns-search-domain/r1 | correct | correct | acceptable | 140s | 15 | $0.40 | clean |
| 16-dns-search-domain/r2 | correct | correct | acceptable | 205s | 24 | $0.56 | clean |
| 17-slow-memory-leak/r1 | correct | correct | acceptable | 201s | 13 | $0.31 | clean |
| 17-slow-memory-leak/r2 | correct | correct | acceptable | 86s | 12 | $0.20 | clean |
| 18-init-waits-missing-service/r1 | correct | correct | acceptable | 158s | 20 | $0.40 | clean |
| 18-init-waits-missing-service/r2 | correct | correct | acceptable | 160s | 19 | $0.48 | clean |
| 19-config-drift-partial-restart/r1 | partial | partial | acceptable | 280s | 15 | $0.39 | clean |
| 19-config-drift-partial-restart/r2 | correct | correct | acceptable | 253s | 28 | $0.84 | clean |

Verdicts marked (judge) have not been reviewed by a person; the others are `human_verdict`. "AI review" is a second model's reading where it disagrees with the judge; it read only the report. "Full output" is the judge on the report, notes, suggestions and last chat message (runner/grade_full.py). "Fix" grades the suggested next steps (runner/grade_fixes.py).
