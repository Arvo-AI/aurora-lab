#!/usr/bin/env python3
"""Grade the diagnosis on everything Aurora shows the user for an incident:
the report (`summary`), the investigation notes (`streamingThoughts`), the
suggested next steps (`suggestions`) and the agent's last chat message.
grade.py reads only the report, so it can miss findings made elsewhere.

    python3 runner/grade_full.py runs/<run-id> [...]

Writes `full_output` into each grade.json and leaves the report-only grade unchanged.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grade import PROMPT, ROOT, commands_from_timeline, judge  # noqa: E402

LIMIT = 30000


def scenario_of(sdir):
    name = sdir.name if (ROOT / "scenarios" / sdir.name).exists() else sdir.parent.name
    return (ROOT / "scenarios" / name / "scenario.yaml").read_text()


def full_output(inc):
    parts = ["## REPORT\n" + (inc.get("summary") or "")]
    notes = "\n\n".join(t.get("content", "") for t in inc.get("streamingThoughts") or [])
    parts.append("## INVESTIGATION NOTES\n" + notes)
    sugg = "\n".join(f"- {s.get('title')}: {s.get('description', '')} `{s.get('command') or ''}`"
                     for s in inc.get("suggestions") or [])
    parts.append("## SUGGESTED NEXT STEPS\n" + sugg)
    msgs = [m for s in inc.get("chatSessions") or [] for m in s.get("messages", []) if m.get("sender") == "bot"]
    if msgs:
        parts.append("## AGENT'S LAST CHAT MESSAGE\n" + (msgs[-1].get("text") or "")[:6000])
    return "\n\n".join(parts)[:LIMIT]


def main():
    for run in sys.argv[1:]:
        for g in sorted(Path(run).resolve().rglob("grade.json")):
            sdir = g.parent
            inc = json.loads((sdir / "incident.json").read_text())
            inc = inc.get("incident", inc)
            timeline = json.loads((sdir / "timeline.json").read_text() or "{}")
            prompt = PROMPT.format(scenario=scenario_of(sdir), rca=full_output(inc),
                                   commands=commands_from_timeline(timeline))
            prompt = prompt.replace("THE INVESTIGATOR'S FINAL ROOT CAUSE ANALYSIS",
                                    "EVERYTHING THE INVESTIGATOR SHOWED THE USER (report, notes, suggested next steps, last message)")
            prompt = prompt.replace("only on what the RCA text says", "only on what this output says")
            res = judge(prompt)
            grade = json.loads(g.read_text())
            grade["full_output"] = res
            g.write_text(json.dumps(grade, indent=2))
            print(f"{sdir.relative_to(ROOT)}: report-only {grade['verdict']} -> full {res['verdict']}")


if __name__ == "__main__":
    main()
