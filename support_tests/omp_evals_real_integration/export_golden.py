#!/usr/bin/env python3
"""Export one completed real trial into a self-contained, secret-free bundle."""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
from pathlib import Path
from typing import Any


def _json_row(connection: sqlite3.Connection, query: str, values: tuple[str, ...]) -> dict[str, Any]:
    row = connection.execute(query, values).fetchone()
    if row is None:
        raise KeyError(values[0])
    return json.loads(row[0])


def _artifact_path(eval_home: Path, reference: str) -> Path:
    if not reference.startswith("sha256:") or len(reference) != 71:
        raise ValueError(f"invalid artifact reference: {reference}")
    digest = reference[7:]
    return eval_home / "artifacts" / digest[:2] / digest[2:]


def _write_json(path: Path, value: Any) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n")


def export(eval_home: Path, trial_id: str, output: Path) -> None:
    connection = sqlite3.connect(eval_home / "evals.db")
    try:
        plan = _json_row(connection, "SELECT plan_json FROM trial_plans WHERE trial_id=?", (trial_id,))
        trial = _json_row(connection, "SELECT trial_json FROM agent_trials WHERE id=?", (trial_id,))
        candidate_id = trial.get("candidate_snapshot_id")
        if not candidate_id:
            raise ValueError("trial has no CandidateSnapshot")
        candidate = _json_row(
            connection, "SELECT snapshot_json FROM candidate_snapshots WHERE id=?", (candidate_id,)
        )
        eval_result = _json_row(
            connection, "SELECT result_json FROM eval_runs WHERE trial_id=?", (trial_id,)
        )
        grading_runs = [
            json.loads(row[0])
            for row in connection.execute(
                "SELECT run_json FROM grading_runs WHERE candidate_snapshot_id=? ORDER BY created_at,id",
                (candidate_id,),
            )
        ]
    finally:
        connection.close()

    if len(grading_runs) < 2:
        raise ValueError("golden export requires at least two grading runs")
    if output.exists():
        raise FileExistsError(output)
    artifacts = output / "artifacts"
    artifacts.mkdir(parents=True)
    references = {
        "workspace": candidate["workspace_artifact_ref"],
        "diff": candidate["diff_ref"],
        "filesystem-manifest": candidate["filesystem_manifest_ref"],
        "transcript": candidate["transcript_ref"],
        "trajectory": candidate["trajectory_ref"],
        "final-answer": candidate["final_answer_ref"],
        "runtime-log": candidate["runtime_log_ref"],
    }
    for index, reference in enumerate(candidate.get("operation_refs", []), start=1):
        references[f"operation-{index:02d}"] = reference
    exported: dict[str, dict[str, str]] = {}
    for name, reference in references.items():
        source = _artifact_path(eval_home, reference)
        suffix = ".tar.gz" if name in ("workspace", "runtime-log") else ".artifact"
        destination = artifacts / f"{name}{suffix}"
        shutil.copyfile(source, destination)
        exported[name] = {"reference": reference, "path": destination.relative_to(output).as_posix()}

    _write_json(output / "trial-plan.json", plan)
    _write_json(output / "agent-trial.json", trial)
    _write_json(output / "candidate-snapshot.json", candidate)
    _write_json(output / "grader-v1-result.json", grading_runs[-2])
    _write_json(output / "grader-v2-result.json", grading_runs[-1])
    _write_json(output / "final-eval-result.json", eval_result)
    _write_json(output / "usage.json", candidate["usage"])
    _write_json(
        output / "manifest.json",
        {
            "schemaVersion": "omp-evals-golden-real-trial/v0.1.1",
            "trialId": trial_id,
            "candidateSnapshotId": candidate_id,
            "taskFingerprint": plan["task_fingerprint"],
            "agentFingerprint": plan["agent_fingerprint"],
            "environmentFingerprint": plan["environment_fingerprint"],
            "sourceAgentWorkspaceRequired": False,
            "modelCallsDuringRegrade": 0,
            "gradingRunIds": [item["id"] for item in grading_runs[-2:]],
            "artifacts": exported,
        },
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--eval-home", required=True, type=Path)
    parser.add_argument("--trial-id", required=True)
    parser.add_argument("--output", required=True, type=Path)
    options = parser.parse_args()
    export(options.eval_home.resolve(), options.trial_id, options.output.resolve())


if __name__ == "__main__":
    main()
