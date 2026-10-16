#!/usr/bin/env python3
"""Second-model review of the head-to-head grades, so a person only has to look at
the disagreements.

    python3 runner/review_h2h.py runs/h2h-v1

For every holmes.grade.json and k8sgpt.grade.json, a different model from the
judge reads the scenario, the tool's answer and the judge's grade, and says
whether it agrees. Writes `reviewer_ai` into the grade file and a summary to
runs/<run>/review-summary.md listing every disagreement with both opinions.
human_verdict is left for a person.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grade import ROOT  # noqa: E402
from grade_h2h import holmes_answer, k8sgpt_answer  # noqa: E402

REVIEW_MODEL = os.environ.get("LAB_REVIEW_MODEL", "us.anthropic.claude-sonnet-5")

PROMPT = """You are checking another model's grade of an AI incident investigator.

GROUND TRUTH (scenario definition):
{scenario}

THE INVESTIGATOR'S ANSWER:
<<<
{answer}
>>>

THE JUDGE'S GRADE (JSON):
{grade}

Rules the judge applied: "correct" means every must_identify item is clearly stated and no
listed wrong answer is asserted; "partial" means some items met or hedged; "wrong" means the
main cause is incorrect; "no_answer" means no root cause given. Grade only what the answer
text says.

Decide whether the judge's verdict is right. Reply with JSON only:
{{"agree": true|false, "verdict": "correct|partial|wrong|no_answer", "reason": "one or two sentences quoting the answer where it matters"}}"""


def ask(prompt):
    body = [{"role": "user", "content": [{"text": prompt}]}]
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(body, f)
        path = f.name
    try:
        r = subprocess.run(["aws", "bedrock-runtime", "converse", "--region", "us-east-1", "--model-id", REVIEW_MODEL,
                            "--messages", f"file://{path}", "--inference-config", '{"maxTokens":800}',
                            "--query", "output.message.content", "--output", "json"], check=True, text=True, capture_output=True)
    finally:
        os.unlink(path)
    text = "".join(b.get("text", "") for b in json.loads(r.stdout))
    return json.loads(text[text.find("{"):text.rfind("}") + 1])


def main():
    run = Path(sys.argv[1])
    rows = []
    for tool, fname, parse in (("holmes", "holmes.md", holmes_answer), ("k8sgpt", "k8sgpt.txt", k8sgpt_answer)):
        for gf in sorted(run.rglob(f"{tool}.grade.json")):
            g = json.loads(gf.read_text())
            if g.get("reviewer_ai"):
                rows.append((gf, g)); continue
            scenario = (ROOT / "scenarios" / gf.parent.name / "scenario.yaml").read_text()
            answer, _ = parse((gf.parent / fname).read_text(errors="replace"))
            g["reviewer_ai"] = {**ask(PROMPT.format(scenario=scenario, answer=answer[:12000], grade=json.dumps({k: g[k] for k in ("must_identify", "wrong_answers_asserted", "fix_acceptable", "verdict", "notes") if k in g}))), "model": REVIEW_MODEL}
            gf.write_text(json.dumps(g, indent=2))
            rows.append((gf, g))
            print(f"{gf.parent.relative_to(run)} {tool}: judge={g['verdict']} review={g['reviewer_ai']['verdict']} agree={g['reviewer_ai']['agree']}", flush=True)
    dis = [(gf, g) for gf, g in rows if not g["reviewer_ai"].get("agree")]
    lines = [f"# Review of {run.name}", "", f"Judge: {rows[0][1].get('judge_model') if rows else '?'}. Reviewer: {REVIEW_MODEL}. "
             f"{len(rows)} grades, {len(rows) - len(dis)} agreed, {len(dis)} disagreements for a person to settle.", ""]
    if dis:
        lines += ["| Run | Tool | Judge | Reviewer | Reviewer's reason |", "|---|---|---|---|---|"]
        for gf, g in dis:
            lines.append(f"| {gf.parent.relative_to(run)} | {g['tool']} | {g['verdict']} | {g['reviewer_ai']['verdict']} | {g['reviewer_ai']['reason'].replace('|', '/')} |")
    (run / "review-summary.md").write_text("\n".join(lines) + "\n")
    print(f"{len(dis)} disagreements, summary in {run / 'review-summary.md'}")


if __name__ == "__main__":
    main()
