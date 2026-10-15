#!/usr/bin/env python3
"""Grade HolmesGPT and K8sGPT answers from a head-to-head run with the same judge
prompt used for Aurora (runner/grade.py), so the three are scored alike.

    python3 runner/grade_h2h.py runs/h2h-v1            grade every tool answer not yet graded
    python3 runner/grade_h2h.py runs/h2h-v1 --force

Reads runs/<run>/<repeat>/<scenario>/holmes.md and k8sgpt.txt, writes
holmes.grade.json and k8sgpt.grade.json next to them. human_verdict starts empty.
"""
import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grade import JUDGE_MODEL, PROMPT, ROOT, judge  # noqa: E402

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def holmes_answer(text):
    """HolmesGPT prints tool calls, then 'AI:' and the answer. Keep the answer and the tool list."""
    text = ANSI.sub("", text)
    cmds = re.findall(r"Running tool #\d+ (\S+): (.*)", text)
    commands = "\n".join(f"- [{t}] {c.strip()[:200]}" for t, c in cmds) or "(none recorded)"
    i = text.rfind("\nAI:")
    answer = text[i + 4:].strip() if i >= 0 else text.strip()
    return answer, commands


def k8sgpt_answer(text):
    text = ANSI.sub("", text)
    return text.strip(), "(K8sGPT runs its analyzers over the namespace; no agent tool calls)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--force", action="store_true")
    a = ap.parse_args()
    run = Path(a.run_dir)
    for tool, fname, parse in (("holmes", "holmes.md", holmes_answer), ("k8sgpt", "k8sgpt.txt", k8sgpt_answer)):
        for f in sorted(run.rglob(fname)):
            out = f.with_name(f"{tool}.grade.json")
            if out.exists() and not a.force:
                continue
            scenario_id = f.parent.name
            scenario = (ROOT / "scenarios" / scenario_id / "scenario.yaml").read_text()
            answer, commands = parse(f.read_text(errors="replace"))
            if not answer or answer.startswith("Error:"):
                g = {"must_identify": [], "wrong_answers_asserted": [], "fix_acceptable": None,
                     "verdict": "no_answer", "notes": f"{tool} produced no answer: {answer[:160]}"}
            else:
                g = judge(PROMPT.format(scenario=scenario, rca=answer[:12000], commands=commands))
            g.update(judge_model=JUDGE_MODEL, tool=tool, human_verdict=None, human_notes="")
            out.write_text(json.dumps(g, indent=2))
            print(f"{f.parent.relative_to(run)} {tool}: {g['verdict']}", flush=True)


if __name__ == "__main__":
    main()
