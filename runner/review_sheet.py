#!/usr/bin/env python3
"""One file a person reads to check every HolmesGPT and K8sGPT grade.

    python3 runner/review_sheet.py runs/h2h-v1            # writes runs/h2h-v1/REVIEW.md
    python3 runner/review_sheet.py runs/h2h-v1 --apply    # writes human_verdict from REVIEW.md

Each block shows the alert, what the scenario requires, the judge's grade with
its evidence, and the tool's final answer. The `human:` line is prefilled with
the judge's verdict; change the word where you disagree (correct | partial |
wrong | no_answer) and add notes after a semicolon. `--apply` records every
`human:` line into the grade file, then run benchmark_export.py.
"""
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grade_h2h import holmes_answer, k8sgpt_answer  # noqa: E402

ORDER = {"wrong": 0, "no_answer": 1, "partial": 2, "correct": 3}
VERDICTS = {"correct", "partial", "wrong", "no_answer"}


def runs(run_dir):
    for tool, fname, parse in (("holmes", "holmes.md", holmes_answer), ("k8sgpt", "k8sgpt.txt", k8sgpt_answer)):
        for gf in sorted(run_dir.rglob(f"{tool}.grade.json")):
            d = gf.parent
            g = json.loads(gf.read_text())
            meta = json.loads((d / "meta.json").read_text()) if (d / "meta.json").exists() else {}
            answer, _ = parse((d / fname).read_text()) if (d / fname).exists() else ("(no answer file)", "")
            yield tool, f"{d.parent.name}/{d.name}", gf, g, meta, answer


def key(item):
    tool, rel, gf, g, meta, answer = item
    return (tool, ORDER.get(g.get("verdict"), 9), rel)


def build(run_dir):
    items = sorted(runs(run_dir), key=key)
    out = [f"# Human review of {run_dir.name}", "",
           "Read each block, change the word on the `human:` line where you disagree "
           "(correct | partial | wrong | no_answer), notes after a semicolon. "
           f"Then `python3 runner/review_sheet.py {run_dir} --apply && python3 runner/benchmark_export.py`.",
           "", f"{len(items)} grades. Non-correct ones come first within each tool.", ""]
    for tool, rel, gf, g, meta, answer in items:
        rev = g.get("reviewer_ai") or {}
        agree = "reviewer agreed" if rev.get("agree") else f"reviewer said {rev.get('verdict')}" if rev else "no second opinion"
        out.append(f"### {rel} · {tool} · judge: {g.get('verdict')} ({agree})")
        out.append(f"alert: {meta.get('alert', '')}")
        out.append("must identify:")
        for m in g.get("must_identify", []):
            ev = (m.get("evidence") or "").strip()
            out.append(f"- {m['result']}: {m['item']}" + (f"\n  evidence: {ev}" if ev else ""))
        if g.get("wrong_answers_asserted"):
            out.append(f"wrong answers asserted: {g['wrong_answers_asserted']}")
        out.append(f"fix acceptable: {g.get('fix_acceptable')}")
        out.append(f"judge notes: {g.get('notes', '')}")
        tail = answer[-2500:] if len(answer) > 2500 else answer
        out.append("answer" + (" (last 2500 chars)" if len(answer) > 2500 else "") + ":")
        out.append("```")
        out.append(tail.strip())
        out.append("```")
        hv = g.get("human_verdict") or g.get("verdict")
        notes = g.get("human_notes") or ""
        out.append(f"human: {hv}" + (f"; {notes}" if notes else ""))
        out.append("")
    (run_dir / "REVIEW.md").write_text("\n".join(out))
    print(f"wrote {run_dir / 'REVIEW.md'} ({len(items)} grades)")


def apply(run_dir):
    text = (run_dir / "REVIEW.md").read_text()
    blocks = re.split(r"^### ", text, flags=re.M)[1:]
    n = 0
    for b in blocks:
        head = b.split("\n", 1)[0]
        rel, tool = [s.strip() for s in head.split("·")[:2]]
        m = re.search(r"^human:\s*(\S+?)\s*(?:;\s*(.*))?$", b, re.M)
        if not m:
            print(f"no human line: {head}")
            continue
        verdict, notes = m.group(1), (m.group(2) or "").strip()
        if verdict not in VERDICTS:
            sys.exit(f"bad verdict {verdict!r} in {head}")
        gf = run_dir / rel / f"{tool}.grade.json"
        g = json.loads(gf.read_text())
        g["human_verdict"], g["human_notes"] = verdict, notes
        gf.write_text(json.dumps(g, indent=2, ensure_ascii=False) + "\n")
        n += 1
    print(f"recorded {n} human verdicts")


if __name__ == "__main__":
    rd = Path(sys.argv[1])
    apply(rd) if "--apply" in sys.argv else build(rd)
