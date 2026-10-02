#!/usr/bin/env python3
"""Grade Aurora's investigations against each scenario's ground truth.

A judge model (a different model from the one Aurora ran on) reads the
scenario's ground truth and Aurora's final RCA, and marks each required
finding as met, partial or missed, quoting Aurora's words as evidence. It also
flags any listed wrong answer Aurora asserted. Every verdict is written to
grade.json next to the run so a person can check it; human_verdict starts
empty and a person fills it in before anything is published.

    python3 runner/grade.py runs/<run-id>            grade every scenario in the run
    python3 runner/grade.py runs/<run-id> --report   write report.md from the grades

A run holds runs/<run-id>/<scenario>/result.json (one repeat) or
runs/<run-id>/<scenario>/r<n>/result.json (repeats). Already graded runs are
skipped unless --force.
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
JUDGE_MODEL = os.environ.get("LAB_JUDGE_MODEL", "us.anthropic.claude-opus-5-5")

PROMPT = """You are grading an AI incident investigator against a known ground truth.
The fault was injected deliberately, so the ground truth is certain.

GROUND TRUTH (scenario definition):
{scenario}

THE INVESTIGATOR'S FINAL ROOT CAUSE ANALYSIS:
<<<
{rca}
>>>

COMMANDS THE INVESTIGATOR RAN (in order):
{commands}

Grade strictly and only on what the RCA text says. Do not give credit for things
the investigator could have concluded from its commands but did not state.

For each item in must_identify, decide:
- "met": the RCA clearly states it
- "partial": the RCA gestures at it but is vague, hedged among several options, or half right
- "missed": not stated, or stated wrongly
and quote the exact RCA sentence that supports your decision (empty string if missed).

List every item from wrong_answers that the RCA asserts as the cause or primary fix.
Decide whether the recommended fix is in acceptable_fixes (true/false/null if no fix given).

Overall verdict:
- "correct": every must_identify item met, no wrong answer asserted
- "partial": at least one must_identify met or partial, but not all met, or a wrong answer asserted alongside the right one
- "wrong": the main cause stated is incorrect
- "no_answer": no root cause given

Reply with JSON only, no prose, in exactly this shape:
{{"must_identify":[{{"item":"...","result":"met|partial|missed","evidence":"..."}}],
"wrong_answers_asserted":["..."],"fix_acceptable":true,"verdict":"correct|partial|wrong|no_answer",
"notes":"one or two sentences on anything a human reviewer should check"}}"""


def commands_from_timeline(timeline):
    out = []
    for step in timeline.get("steps") or []:
        ti = step.get("tool_input") or step.get("input") or {}
        if isinstance(ti, str):
            try:
                ti = json.loads(ti)
            except ValueError:
                ti = {"raw": ti}
        cmd = ti.get("command") or ti.get("cmd") or ti.get("query") or json.dumps(ti)[:200]
        out.append(f"- [{step.get('tool_name')}] {cmd}")
    return "\n".join(out) or "(none recorded)"


def judge(prompt):
    body = [{"role": "user", "content": [{"text": prompt}]}]
    with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
        json.dump(body, f)
        path = f.name
    try:
        r = subprocess.run(
            ["aws", "bedrock-runtime", "converse", "--region", "us-east-1",
             "--model-id", JUDGE_MODEL, "--messages", f"file://{path}",
             "--inference-config", '{"maxTokens":2000}',
             "--query", "output.message.content", "--output", "json"],
            check=True, text=True, capture_output=True)
    finally:
        os.unlink(path)
    # The reply may hold reasoning blocks before the text block; keep text only.
    text = "".join(b.get("text", "") for b in json.loads(r.stdout))
    start, end = text.find("{"), text.rfind("}")
    return json.loads(text[start:end + 1])


def run_dirs(run_dir):
    """Every directory in the run that holds one investigation."""
    return sorted(p.parent for p in run_dir.rglob("result.json"))


def scenario_of(sdir):
    r = json.loads((sdir / "result.json").read_text())
    return r.get("scenario") or sdir.name


def grade_run(run_dir, force=False):
    for sdir in run_dirs(run_dir):
        if (sdir / "grade.json").exists() and not force:
            continue
        scenario = (ROOT / "scenarios" / scenario_of(sdir) / "scenario.yaml").read_text()
        rca = (sdir / "aurora-rca.md").read_text() if (sdir / "aurora-rca.md").exists() else ""
        timeline = json.loads((sdir / "timeline.json").read_text() or "{}")
        if not rca.strip():
            g = {"must_identify": [], "wrong_answers_asserted": [], "fix_acceptable": None,
                 "verdict": "no_answer", "notes": "Aurora produced no summary."}
        else:
            g = judge(PROMPT.format(scenario=scenario, rca=rca, commands=commands_from_timeline(timeline)))
        g["judge_model"] = JUDGE_MODEL
        g["human_verdict"] = None
        g["human_notes"] = ""
        (sdir / "grade.json").write_text(json.dumps(g, indent=2))
        print(f"{sdir.relative_to(run_dir)}: {g['verdict']}", flush=True)


def _median(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return statistics.median(xs) if xs else None


def report(run_dir):
    meta = json.loads((run_dir / "run.json").read_text())
    by_scenario, counts, all_dur, all_cost, n_total = {}, {}, [], [], 0
    rows = []
    for sdir in run_dirs(run_dir):
        r = json.loads((sdir / "result.json").read_text())
        g = json.loads((sdir / "grade.json").read_text()) if (sdir / "grade.json").exists() else {}
        verdict = g.get("human_verdict") or g.get("verdict") or "ungraded"
        reviewed = bool(g.get("human_verdict"))
        ai = (g.get("reviewer_ai") or {}).get("verdict")
        full = (g.get("full_output") or {}).get("verdict") or "-"
        fix = (g.get("fix_from_suggestions") or {}).get("result") or "-"
        counts[verdict] = counts.get(verdict, 0) + 1
        n_total += 1
        sc = by_scenario.setdefault(r.get("scenario") or sdir.name, [])
        sc.append((verdict, r))
        dur, cost = r.get("duration_seconds"), r.get("cost_usd")
        all_dur.append(dur)
        all_cost.append(cost)
        iso = r.get("isolation")
        iso_txt = "-" if iso is None else ("clean" if not iso["foreign_incident_ids"] else
                                           f"{len(iso['foreign_incident_ids'])} foreign")
        rows.append(f"| {sdir.relative_to(run_dir)} | {verdict}{'' if reviewed else ' (judge)'}"
                    f"{f' / AI review: {ai}' if ai and ai != verdict else ''} | {full} | {fix} | "
                    f"{round(dur) if dur else '?'}s | {r.get('tool_calls', '?')} | "
                    f"{'$%.2f' % cost if isinstance(cost, (int, float)) else '?'} | {iso_txt} |")
    summary = []
    for name, items in sorted(by_scenario.items()):
        ok = sum(1 for v, _ in items if v == "correct")
        md, mc = _median([r.get("duration_seconds") for _, r in items]), _median([r.get("cost_usd") for _, r in items])
        summary.append(f"| {name} | {ok}/{len(items)} | {', '.join(v for v, _ in items)} | "
                       f"{round(md) if md else '?'}s | {'$%.2f' % mc if mc is not None else '?'} |")
    ok_total = counts.get("correct", 0)
    total_cost = sum(c for c in all_cost if isinstance(c, (int, float)))
    md, mc = _median(all_dur), _median(all_cost)
    summary.append(f"| **total** | **{ok_total}/{n_total}** | | {round(md) if md else '?'}s | "
                   f"{'$%.2f' % mc if mc is not None else '?'} |")
    images = meta.get("images") or {}
    img_txt = ", ".join(f"`{v['image']}` ({v['image_id'][7:19]})" for v in images.values()) or "not recorded"
    lines = [
        f"# Lab run {meta['run_id']}",
        "",
        f"Aurora commit `{meta['aurora_commit'][:10]}`"
        f"{' (branch ' + meta['aurora_branch'] + ')' if meta.get('aurora_branch') not in (None, 'HEAD') else ''}, "
        f"RCA model `{meta['rca_model']}`, orchestrator {meta['orchestrator_enabled']}. Judge `{JUDGE_MODEL}`.",
        f"Images: {img_txt}.",
        f"Repeats: {meta.get('repeats', 1)}. Clusters: {', '.join(meta.get('clusters') or ['aurora-lab'])}. "
        f"Isolation: {meta.get('isolation', 'shared org')}.",
        "",
        "Totals: " + ", ".join(f"{k} {v}" for k, v in sorted(counts.items()))
        + f". Total cost ${total_cost:.2f} (Aurora only, judge not included).",
        "",
        "| Scenario | Correct | Verdicts | Median time | Median cost |",
        "|---|---|---|---|---|",
        *summary,
        "",
        "| Run | Verdict (report only) | Verdict (full output) | Fix (suggestions) | Time | Tool calls | Cost | Prior incidents seen |",
        "|---|---|---|---|---|---|---|---|",
        *rows,
        "",
        "Verdicts marked (judge) have not been reviewed by a person; the others are `human_verdict`. "
        "\"AI review\" is a second model's reading where it disagrees with the judge; it read only the report. "
        "\"Full output\" is the judge on the report, notes, suggestions and last chat message (runner/grade_full.py). "
        "\"Fix\" grades the suggested next steps (runner/grade_fixes.py).",
    ]
    (run_dir / "report.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir")
    ap.add_argument("--report", action="store_true")
    ap.add_argument("--force", action="store_true", help="regrade runs that already have grade.json")
    a = ap.parse_args()
    run_dir = Path(a.run_dir).resolve()
    if not (run_dir / "run.json").exists():
        sys.exit(f"{run_dir} is not a run directory")
    if a.report:
        report(run_dir)
    else:
        grade_run(run_dir, a.force)


if __name__ == "__main__":
    main()
