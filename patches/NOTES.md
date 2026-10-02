# Fixes on lab/rollout-readonly (base 87d22baf)

Worktree: ~/Dev/aurora-lab-fix. Three commits, one patch each (0001-0003). Nothing pushed.
Line numbers below are at 87d22baf.

## 1. kubectl rollout history/status blocked (0001)

Cause: `server/utils/auth/command_policy.py:704` (observability_only) and `:790` (standard_ops) deny rules matched the bare `kubectl rollout` verb. Both templates are also allowlist-based (seeding turns the allowlist on), and the Kubernetes read allow rules (`:643` and `:723`) had no `rollout` entry. Removing it from the deny rule alone would not have been enough.

Change: the deny rules now match only `rollout\s+(restart|undo|pause|resume)`. `rollout\s+(history|status)` is added to the Kubernetes read allow rule in both templates.

Test: new `tests/auth/test_command_policy_rollout.py`. It loads the real template rules with both lists on and checks them through `evaluate_compound_command`, which is the path `command_gate` uses. It covers history and status (allowed) and restart, undo, pause and resume (denied by the deny rule), in both templates. Result: 12 passed. Before the fix, 4 of the 12 failed. Existing `tests/auth/test_command_policy.py` and `tests/security/test_allowlist_bypass.py` still pass.

Caveats for a rerun:
- Templates are copied into `org_command_policies` rows when an org is created (`seed_default_command_policy`). An existing org, like the lab org, keeps its old patterns until the template is re-applied (Settings > Security, or the apply-template route in `routes/command_policies.py`) or the rows are edited.
- Not changed: the Ask-mode classifier `utils/security/read_only_classifier.py:47` lists `rollout` as a write verb, so `kubectl rollout history` is still refused on the cloud_exec kubectl path (EKS/GKE/AKS). It does not affect `on_prem_kubectl`, which the lab uses: that tool only goes through `gate_command` (signature check + org policy + LLM judge). Fixing the classifier needs a kubectl-specific `rollout <sub>` rule. I left it alone because it is a security gate.

## 2. write_artifact loop (0002)

Cause: the model's output was cut off at the token limit. In timeline.json every agent LLM call from 15:27:50 to 15:38:31 has `output_tokens = 4096` exactly. The agent never sets `max_tokens` (`chat/backend/agent/providers/bedrock_provider.py:196-197`), so Bedrock Converse falls back to its 4096 default. The model was rewriting the whole Incident Index in a single write_artifact call, and the arguments JSON was cut off mid-`content`. The parsed args were `{"title": ...}`, or `{}` once the model moved content first. The model then guessed at an "ordering issue" and tried test payloads ("placeholder", "test2", "x").

Why the model got no useful feedback and the steps stayed "running":
- `cloud_tools.py:1755` registers the tool with the pydantic `WriteArtifactArgs` (`artifact_tool.py:36-38`, content required). The ToolNode rejects the call during validation, before the tool function runs. The model only sees "content: Field required. Please fix the error and try again." (I reproduced this with create_agent and a scripted model.)
- The execution_steps row is inserted as 'running' when the model emits the call (`tool_context_capture.py:96`). It is only closed by the capture wrapper inside the tool function (`cloud_tools.py` ~1250/1330), and that wrapper never ran.

Change: the tool is registered with the same schema as a plain JSON-schema dict. The model still sees title and content as required, but pydantic no longer validates the call, so a call without content reaches `write_artifact`. When content is missing, `write_artifact` now returns an error saying the call was probably cut off by the output-token limit and asking for a shorter document. Because the tool function now runs, the capture wrapper closes the step as an error.

Not changed: the underlying 4096 output cap. Raising `max_tokens` for Bedrock is a cost and config decision. The same cut-off can hit any tool that takes a long argument, and other tools will still show stuck 'running' steps for validation errors.

Test: new `tests/chat/backend/agent/tools/test_write_artifact_truncated_call.py`. It runs a real `create_agent` graph and ToolNode with a scripted model. It checks that `{"title": ...}` and `{}` reach the tool function and return the cut-off error without touching the DB, and that the schema the model sees still requires title and content. Result: 4 passed (directory total 14 passed).

## 3. Summary dropped the PVC evidence (0003)

Cause: `chat/background/summarization.py:211`: `for c in citations[-30:]` sends only the 30 most recent citations to the summary model. Citations are every tool message except `_NON_EVIDENCE_TOOLS` (`citation_extractor.py:115`, filter at `:295`), so artifact and memory writes counted too. This run had 45 tool calls, and calls 19-45 were read_artifact, append_to_memory and write_artifact, including about 23 failed retries. The last-30 window started around citation 16, so the PVC, StorageClass and PVC-yaml calls (steps 7, 8, 11) never reached the prompt. The report only cites [17] and [18], which fits. It then filed the PVC under "Not Checked" for lack of numbered evidence. Citations come from llm_context_history, not execution_steps, and I could not read that from the DB, so the exact numbering is inferred.

Change: `write_artifact`, `write_memory`, `append_to_memory` and `edit_memory` are added to `_NON_EVIDENCE_TOOLS`. Their output is a save receipt or an error, never evidence. Reads (read_artifact, read_memory) are still citable.

Not changed: the `[-30:]` recency window. Any investigation with more than 30 real evidence calls will still drop its earliest evidence. A real fix would be a character budget, or keeping the first N plus the last M; that is a design choice.

Test: new `tests/chat/background/test_citations_artifact_writes.py`. It builds a synthetic message history shaped like the run, runs it through `CitationExtractor._parse_tool_messages` and `_build_summary_prompt_with_chat`, and checks that the PVC evidence is in the prompt and no write receipts are. Result: 2 passed. Both failed before the fix. This test needs Redis at import time (`chat/background/task.py:314`), so it ran with a throwaway `redis:7-alpine` sidecar on an `--internal` docker network.

## Regression run

`tests/auth tests/security tests/chat` in aurora_lab_server:87d22baf (with the Redis sidecar):
- base 87d22baf: 9 failed, 1025 passed, 1 skipped, 12 errors
- HEAD: 9 failed, 1043 passed, 1 skipped, 12 errors

Same failure list on both, all from the test environment: no Postgres (test_rls_cross_tenant, test_enforcer), `client/` not mounted (test_model_catalog reads ModelSelector.tsx), and SEARXNG_URL unset (test_bitbucket_file_ops builds the cloud tools). The +18 passes are the new tests.
