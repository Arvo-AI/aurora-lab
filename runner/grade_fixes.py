#!/usr/bin/env python3
"""Grade Aurora's suggested fixes, which live in the incident's `suggestions`
list (the Next Steps shown in the UI), not in the RCA text that grade.py reads.

    python3 runner/grade_fixes.py runs/<run-id> [...]

Adds `fix_from_suggestions` to each grade.json. Verdicts are left unchanged.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from grade import ROOT, judge  # noqa: E402

PROMPT = """You are checking whether an incident investigator's suggested fixes would fix a known, injected fault.

GROUND TRUTH (scenario definition):
{scenario}

THE INVESTIGATOR'S SUGGESTED NEXT STEPS:
{suggestions}

Decide:
- "acceptable": at least one suggestion matches acceptable_fixes, and would fix the root cause, not just a symptom
- "partial": the suggestions fix only part of it (for example one of two faults), or only mitigate
- "unacceptable": none of them would fix the root cause, or the main suggestion is in wrong_answers
- "none": no suggestions

Reply with JSON only:
{{"result":"acceptable|partial|unacceptable|none","best_suggestion":"title of the best one or empty","reason":"one sentence"}}"""


def scenario_of(sdir):
    name = sdir.name if (ROOT / "scenarios" / sdir.name).exists() else sdir.parent.name
    return (ROOT / "scenarios" / name / "scenario.yaml").read_text()


def main():
    for run in sys.argv[1:]:
        for g in sorted(Path(run).resolve().rglob("grade.json")):
            sdir = g.parent
            inc = json.loads((sdir / "incident.json").read_text())
            inc = inc.get("incident", inc)
            sugg = inc.get("suggestions") or []
            text = "\n".join(f"- {s.get('title')}: {s.get('description', '')} {s.get('command') or ''}" for s in sugg)
            res = {"result": "none", "best_suggestion": "", "reason": "no suggestions"} if not sugg else \
                judge(PROMPT.format(scenario=scenario_of(sdir), suggestions=text))
            grade = json.loads(g.read_text())
            grade["fix_from_suggestions"] = res
            g.write_text(json.dumps(grade, indent=2))
            print(f"{g.parent.relative_to(ROOT)}: {res['result']}")


if __name__ == "__main__":
    main()
