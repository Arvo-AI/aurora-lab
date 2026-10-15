#!/usr/bin/env python3
"""Build benchmark/results.json: every scenario, every tool, every graded run.

    python3 runner/benchmark_export.py [--site ~/Claude/arvo-website]

Aurora comes from runs/v0-run2 and runs/v1-run1 (human-reviewed verdicts).
HolmesGPT and K8sGPT come from runs/h2h-*/<repeat>/<scenario>/. A run counts
once it has a grade file; ungraded answers show as pending. The site copies the
file to lib/benchmark/results.json.
"""
import argparse
import json
import re
import shutil
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
AURORA_RUNS = ["v0-run2", "v1-run1"]
GITHUB = "https://github.com/Arvo-AI/aurora-lab/tree/main"


def yaml_field(text, key):
    m = re.search(rf"^{key}:\s*(.*)$", text, re.M)
    return m.group(1).strip().strip('"') if m else ""


def verdict_of(g):
    return g.get("human_verdict") or g.get("verdict") or "pending"


def median(xs):
    xs = [x for x in xs if isinstance(x, (int, float))]
    return round(statistics.median(xs), 2) if xs else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--site", default=str(Path.home() / "Claude/arvo-website"))
    a = ap.parse_args()

    scenarios = []
    for sdir in sorted((ROOT / "scenarios").iterdir()):
        if not (sdir / "scenario.yaml").exists():
            continue
        y = (sdir / "scenario.yaml").read_text()
        tools = {"aurora": [], "holmesgpt": [], "k8sgpt": []}
        for run in AURORA_RUNS:
            for rdir in sorted((ROOT / "runs" / run / sdir.name).glob("r*")) if (ROOT / "runs" / run / sdir.name).exists() else []:
                g = json.loads((rdir / "grade.json").read_text()) if (rdir / "grade.json").exists() else {}
                r = json.loads((rdir / "result.json").read_text()) if (rdir / "result.json").exists() else {}
                tools["aurora"].append({"run": f"{run}/{rdir.name}", "verdict": verdict_of(g), "reviewed": bool(g.get("human_verdict")),
                                        "seconds": r.get("duration_seconds"), "cost": r.get("cost_usd"), "tool_calls": r.get("tool_calls"),
                                        "link": f"{GITHUB}/runs/{run}/{sdir.name}/{rdir.name}"})
        for h2h in sorted((ROOT / "runs").glob("h2h-*")):
            for rep in sorted(h2h.glob("r*")):
                d = rep / sdir.name
                if not d.exists():
                    continue
                for tool, meta_name in (("holmesgpt", "holmes.meta.json"), ("k8sgpt", "k8sgpt.meta.json")):
                    meta = json.loads((d / meta_name).read_text()) if (d / meta_name).exists() else None
                    if not meta:
                        continue
                    gf = d / f"{'holmes' if tool == 'holmesgpt' else 'k8sgpt'}.grade.json"
                    g = json.loads(gf.read_text()) if gf.exists() else {}
                    tools[tool].append({"run": f"{h2h.name}/{rep.name}", "verdict": verdict_of(g), "reviewed": bool(g.get("human_verdict")),
                                        "seconds": meta.get("seconds"), "cost": None, "model": meta.get("model"),
                                        "link": f"{GITHUB}/runs/{h2h.name}/{rep.name}/{sdir.name}"})
        scenarios.append({
            "id": sdir.name, "title": yaml_field(y, "title"), "alert": yaml_field(y, "alert"),
            "link": f"{GITHUB}/scenarios/{sdir.name}",
            "tools": {t: {"runs": rs, "correct": sum(1 for x in rs if x["verdict"] == "correct"), "graded": sum(1 for x in rs if x["verdict"] != "pending"),
                          "median_seconds": median([x["seconds"] for x in rs]), "median_cost": median([x["cost"] for x in rs])}
                      for t, rs in tools.items()},
        })

    tools_meta = {
        "aurora": {"name": "Aurora", "version": "commit 87d22baf", "model": "bedrock/us.anthropic.claude-sonnet-5", "url": "https://github.com/Arvo-AI/aurora", "input": "alert text + read-only kubectl (observability_only policy)"},
        "holmesgpt": {"name": "HolmesGPT", "version": "0.43.0", "model": "bedrock/us.anthropic.claude-sonnet-5", "url": "https://github.com/robusta-dev/holmesgpt", "input": "alert text, `holmes ask`, default toolsets"},
        "k8sgpt": {"name": "K8sGPT", "version": "0.4.40", "model": "us.anthropic.claude-sonnet-4-5 (K8sGPT sends temperature, which Bedrock rejects for Sonnet 5)", "url": "https://github.com/k8sgpt-ai/k8sgpt", "input": "`k8sgpt analyze --explain --namespace shop`"},
    }
    totals = {}
    for t in tools_meta:
        runs = [x for s in scenarios for x in s["tools"][t]["runs"]]
        graded = [x for x in runs if x["verdict"] != "pending"]
        totals[t] = {"runs": len(runs), "graded": len(graded), "correct": sum(1 for x in graded if x["verdict"] == "correct"),
                     "partial": sum(1 for x in graded if x["verdict"] == "partial"),
                     "wrong": sum(1 for x in graded if x["verdict"] in ("wrong", "no_answer")),
                     "median_seconds": median([x["seconds"] for x in runs]), "median_cost": median([x["cost"] for x in runs])}
    out = {"generated": __import__("datetime").date.today().isoformat(), "cluster": "kind v0.33.0, Kubernetes v1.37.0, 3 nodes",
           "judge": "us.anthropic.claude-opus-5-5, then a person", "tools": tools_meta, "totals": totals, "scenarios": scenarios}
    (ROOT / "benchmark").mkdir(exist_ok=True)
    (ROOT / "benchmark" / "results.json").write_text(json.dumps(out, indent=1))
    site = Path(a.site) / "lib" / "benchmark"
    if site.parent.exists():
        site.mkdir(exist_ok=True)
        shutil.copy(ROOT / "benchmark" / "results.json", site / "results.json")
    print(json.dumps(totals))


if __name__ == "__main__":
    main()
