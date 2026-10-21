#!/usr/bin/env python3
"""Blinded regrade of every published answer, as a bias check on the judge.

    python3 runner/grade_blind.py            grade every run that has no blind grade yet
    python3 runner/grade_blind.py --report   write runs/blind-regrade.md from the blind grades

Same judge model and prompt as grade.py and grade_h2h.py, but with everything
that names the agent removed before the judge sees it: the tool-name tags in the
command list ("[on_prem_kubectl]", "[bash]"), the K8sGPT sentence that stood in
for its command list, the "AI Provider:" header, and the words aurora, holmes,
holmesgpt and k8sgpt anywhere in the answer or the commands. The published
verdicts are not changed; the blind verdict is written next to each run as
blind.grade.json (Aurora) or <tool>.blind.grade.json, and the report lists
every disagreement.
"""
import argparse
import json
import re
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grade import JUDGE_MODEL, PROMPT, ROOT, commands_from_timeline, judge  # noqa: E402
from grade_h2h import holmes_answer, k8sgpt_answer  # noqa: E402

AURORA_RUNS = ["v0-run2", "v1-run1"]
NAMES = re.compile(r"holmesgpt|holmes|k8sgpt|aurora", re.I)


def blind_text(s):
    return NAMES.sub("acme", s)


def blind_commands(cmds):
    # "- [tool_name] command" -> "- command"
    return "\n".join(re.sub(r"^- \[[^\]]*\] ", "- ", line) for line in cmds.splitlines()) or "(none recorded)"


def jobs():
    for run in AURORA_RUNS:
        for gf in sorted((ROOT / "runs" / run).glob("*/r*/grade.json")):
            d = gf.parent
            rca = (d / "aurora-rca.md").read_text() if (d / "aurora-rca.md").exists() else ""
            timeline = json.loads((d / "timeline.json").read_text() or "{}")
            yield ("aurora", f"{run}/{d.parent.name}/{d.name}", d / "blind.grade.json", gf, d.parent.name,
                   blind_text(rca), blind_text(blind_commands(commands_from_timeline(timeline))))
    for tool, fname, parse in (("holmes", "holmes.md", holmes_answer), ("k8sgpt", "k8sgpt.txt", k8sgpt_answer)):
        for gf in sorted((ROOT / "runs" / "h2h-v1").glob(f"r*/*/{tool}.grade.json")):
            d = gf.parent
            answer, commands = parse((d / fname).read_text(errors="replace"))
            if tool == "k8sgpt":
                answer = "\n".join(l for l in answer.splitlines() if not l.startswith("AI Provider:"))
                commands = "(none recorded)"
            yield (tool, f"h2h-v1/{d.parent.name}/{d.name}", d / f"{tool}.blind.grade.json", gf, d.name,
                   blind_text(answer), blind_text(blind_commands(commands)))


def grade_one(job):
    tool, rel, out, gf, scenario_id, answer, commands = job
    if out.exists():
        return rel, "cached"
    scenario = (ROOT / "scenarios" / scenario_id / "scenario.yaml").read_text()
    if not answer.strip() or answer.startswith("Error:"):
        g = {"must_identify": [], "wrong_answers_asserted": [], "fix_acceptable": None,
             "verdict": "no_answer", "notes": "no answer"}
    else:
        g = {}
        for attempt in range(3):  # the judge sometimes returns JSON without a verdict; ask again
            try:
                g = judge(PROMPT.format(scenario=scenario, rca=answer[:12000], commands=commands))
            except Exception as e:  # noqa: BLE001
                g = {"error": repr(e)}
            if g.get("verdict") in ("correct", "partial", "wrong", "no_answer"):
                break
        if g.get("verdict") not in ("correct", "partial", "wrong", "no_answer"):
            return rel, f"FAILED after 3 attempts: {json.dumps(g)[:200]}"
    g.update(judge_model=JUDGE_MODEL, blinded=True, tool=tool)
    out.write_text(json.dumps(g, indent=2))
    return rel, g["verdict"]


def report():
    rows, agree, counts = [], {}, {}
    for tool, rel, out, gf, *_ in jobs():
        if not out.exists():
            continue
        pub = json.loads(gf.read_text())
        published = pub.get("human_verdict") or pub.get("verdict")
        blind = json.loads(out.read_text())["verdict"]
        a = agree.setdefault(tool, [0, 0])
        a[1] += 1
        counts.setdefault(tool, {}).setdefault(blind, 0)
        counts[tool][blind] += 1
        if blind == published:
            a[0] += 1
        else:
            rows.append((tool, rel, published, blind, json.loads(out.read_text()).get("notes", "")))
    lines = ["# Blinded regrade", "",
             f"Judge {JUDGE_MODEL}, same prompt as the published grades, with agent names, tool names and the "
             "K8sGPT stand-in sentence removed (runner/grade_blind.py). Published verdicts are unchanged; this is a check.", ""]
    for tool in ("aurora", "holmes", "k8sgpt"):
        if tool in agree:
            c = counts[tool]
            lines.append(f"- {tool}: blind verdict equals the published one in {agree[tool][0]} of {agree[tool][1]}. "
                         f"Blind totals: " + ", ".join(f"{k} {v}" for k, v in sorted(c.items())) + ".")
    lines.append("")
    if rows:
        lines += ["| Tool | Run | Published | Blind | Blind judge notes |", "|---|---|---|---|---|"]
        for tool, rel, pubv, blind, notes in rows:
            lines.append(f"| {tool} | {rel} | {pubv} | {blind} | {notes.replace('|', '/')} |")
    (ROOT / "runs" / "blind-regrade.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--workers", type=int, default=6)
    a = ap.parse_args()
    if a.report:
        report()
        return
    with ThreadPoolExecutor(a.workers) as ex:
        for rel, v in ex.map(grade_one, list(jobs())):
            print(rel, v, flush=True)
    report()


if __name__ == "__main__":
    main()
