# Blinded regrade

Judge us.anthropic.claude-opus-5-5, same prompt as the published grades, with agent names, tool names and the K8sGPT stand-in sentence removed (runner/grade_blind.py). Published verdicts are unchanged; this is a check.

- aurora: blind verdict equals the published one in 38 of 38. Blind totals: correct 34, partial 4.
- holmes: blind verdict equals the published one in 37 of 38. Blind totals: correct 30, partial 7, wrong 1.
- k8sgpt: blind verdict equals the published one in 36 of 38. Blind totals: no_answer 13, partial 19, wrong 6.

| Tool | Run | Published | Blind | Blind judge notes |
|---|---|---|---|---|
| holmes | h2h-v1/r2/19-config-drift-partial-restart | correct | partial | The RCA correctly finds the api:8000 ConfigMap edit and the one-broken, one-healthy pod split. It gets the mechanism wrong for the healthy pod. The mounted file in xmkdj already shows the new content, but nginx only reads its config at startup, so a kubelet volume sync will not break that pod. Only a restart would. The fix (revert to 8080, then rollout restart) is acceptable. |
| k8sgpt | h2h-v1/r1/05-nginx-config-error | partial | no_answer | The RCA only restates symptoms (the container exited with Error and the Service has no ready endpoints) and suggests generic next steps. It never names nginx, the ConfigMap or the typo. It also hedges toward probes ('adjust probe settings'), which is close to the wrong 'readiness probe' answer but is not asserted as the cause. |
| k8sgpt | h2h-v1/r1/18-init-waits-missing-service | partial | wrong | The RCA is generic k8sgpt-style output. It reports only the symptom (the Service has no ready endpoints) and implies a readiness-probe problem, with no mention of the init container, postgres, or the missing Service. The 'fix' is a list of generic diagnostic steps, not a remediation, and no commands were recorded. |
