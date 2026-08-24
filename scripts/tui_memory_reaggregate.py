#!/usr/bin/env python3
"""Recompute soak summaries from preserved raw CSV/process artifacts.

This is intentionally independent of running the TUI. It lets diagnostic
formulae and schema labels be corrected without rerunning multi-hour PTY
experiments or rewriting the raw observations.
"""

from __future__ import annotations

import argparse
import csv
import importlib.util
import json
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("tui_memory_soak", ROOT / "tui_memory_soak.py")
assert SPEC is not None and SPEC.loader is not None
SOAK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SOAK)


def value(text: str) -> Any:
    if text == SOAK.UNAVAILABLE or text == "":
        return SOAK.UNAVAILABLE
    try:
        return int(text)
    except ValueError:
        try:
            return float(text)
        except ValueError:
            return text


def load_samples(path: Path) -> list[dict[str, Any]]:
    with path.open(newline="") as handle:
        rows = [{key: value(item) for key, item in row.items()} for row in csv.DictReader(handle)]
    # Early soak revisions put the audited two-buffer geometry bound in a
    # field named like an observed capacity. Preserve the raw CSV and correct
    # only the recomputed semantic summary.
    for row in rows:
        old = row.get("frame_buffer_capacity_cells")
        if isinstance(old, int) and "frame_buffer_design_bound_cells" not in row:
            row["frame_buffer_design_bound_cells"] = old
            row["frame_buffer_capacity_cells"] = SOAK.UNAVAILABLE
    return rows


def reaggregate_variant(variant_dir: Path, scenario: str) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    combined_path = variant_dir / scenario / "summary.json"
    combined = json.loads(combined_path.read_text())
    summaries: list[dict[str, Any]] = []
    for run_dir in sorted((variant_dir / scenario).glob("run-*")):
        previous = json.loads((run_dir / "summary.json").read_text())
        status = json.loads((run_dir / "process-status.json").read_text())
        summary = SOAK.summarize_run(load_samples(run_dir / "samples.csv"), status, scenario)
        summary["failure"] = previous.get("failure")
        (run_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
        summaries.append(summary)
    combined["aggregate"] = SOAK.aggregate_runs(summaries)
    combined["summaries"] = summaries
    combined_path.write_text(json.dumps(combined, ensure_ascii=False, indent=2) + "\n")
    return combined, summaries


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("experiment", type=Path, help="directory containing experiment.json")
    args = parser.parse_args()
    experiment_path = args.experiment / "experiment.json"
    experiment = json.loads(experiment_path.read_text())
    scenario = experiment["scenario"]
    variants = list(experiment["variants"])
    aggregates: dict[str, Any] = {}
    rebuilt_variants: dict[str, Any] = {}
    for variant in variants:
        variant_dir = args.experiment / variant if len(variants) > 1 else args.experiment
        _, summaries = reaggregate_variant(variant_dir, scenario)
        rebuilt_variants[variant] = summaries
        aggregates[variant] = SOAK.aggregate_runs(summaries)
    experiment["variants"] = rebuilt_variants
    if "baseline" in aggregates and "candidate" in aggregates:
        experiment["comparison"] = SOAK.compare_aggregates(
            aggregates["baseline"], aggregates["candidate"]
        )
    experiment["reaggregated_with"] = "scripts/tui_memory_reaggregate.py"
    experiment_path.write_text(json.dumps(experiment, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"scenario": scenario, "aggregates": aggregates}, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
