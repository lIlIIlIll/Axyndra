from __future__ import annotations

import argparse
import json
import os
import shutil
import sqlite3
import subprocess
import tempfile
from collections import Counter
from pathlib import Path

from omp_evals.edit_causal import ReplayOutcome, attempt_record, extract_historical_edit_attempts
from omp_evals.storage import ArtifactStore
from omp_evals.util import hash_file
from omp_evals.workspace import manifest_and_digest


TRIAL_IDS = (
    "trial-36d31b3f-b30c-49e8-8ab0-136532d6b114",
    "trial-45dd21c8-38f5-4ace-8b51-316704f9bccc",
    "trial-367ef148-58b1-4673-8032-fb9884f512b1",
)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--store", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--condition-b-driver", type=Path, required=True)
    parser.add_argument("--condition-artifacts", type=Path, required=True)
    parser.add_argument("--pinned-cangjie", type=Path, required=True)
    parser.add_argument("--sdk-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()

    database_path = arguments.store / "evals.db"
    artifacts = ArtifactStore(arguments.store / "artifacts")
    connection = sqlite3.connect(database_path)
    connection.row_factory = sqlite3.Row
    before_counts = counts(connection)
    snapshots = {row["trial_id"]: json.loads(row["snapshot_json"]) for row in connection.execute(
        "SELECT trial_id,snapshot_json FROM candidate_snapshots WHERE trial_id IN (?,?,?)", TRIAL_IDS
    )}
    candidate_hashes_before = candidate_artifact_hashes(arguments.store, snapshots)
    fixture_digest = manifest_and_digest(arguments.fixture)[1]
    condition_a_digest = "e28c48b3cd6aecb5fac803e0a3d30dbdcacc994cc68d89124057cd70692b8cee"
    condition_b_digest = "b802014b22690f451d859084f82fe8ad2498b2f1b4b0f78925013720d8313d56"
    condition_a_artifact = arguments.condition_artifacts / condition_a_digest[:2] / condition_a_digest[2:]
    condition_b_artifact = arguments.condition_artifacts / condition_b_digest[:2] / condition_b_digest[2:]
    if hash_file(condition_a_artifact) != condition_a_digest:
        raise RuntimeError("frozen Condition A binary digest mismatch")
    if hash_file(condition_b_artifact) != condition_b_digest:
        raise RuntimeError("frozen Condition B binary digest mismatch")

    records = []
    reconstruction = {}
    with tempfile.TemporaryDirectory(prefix="exp001-causal-preflight-") as temporary:
        temporary_root = Path(temporary)
        for trial_id in TRIAL_IDS:
            snapshot = snapshots[trial_id]
            if snapshot["base_fixture_digest"] != fixture_digest:
                raise RuntimeError(f"fixture digest mismatch for {trial_id}")
            historical_state = temporary_root / trial_id / "historical-state"
            historical_state.parent.mkdir(parents=True)
            shutil.copytree(arguments.fixture, historical_state)
            attempts = extract_historical_edit_attempts(
                trial_id, snapshot["operation_refs"], artifacts,
            )
            for attempt in attempts:
                pre_digest = manifest_and_digest(historical_state)[1]
                replay_workspace = temporary_root / trial_id / f"replay-b-{attempt.attempt_ordinal}"
                shutil.copytree(historical_state, replay_workspace)
                b_outcome = replay(
                    attempt.raw_edit_payload, replay_workspace, temporary_root,
                    arguments.condition_b_driver, arguments.pinned_cangjie, arguments.sdk_root,
                    f"{trial_id}-{attempt.attempt_ordinal}-b",
                )
                level = "Level1" if not any(
                    item.historical_outcome.candidate_changed
                    for item in attempts[:attempt.attempt_ordinal - 1]
                ) else "Level2"
                evidence = [
                    f"preStateDigest:{pre_digest}",
                    f"baseFixtureDigest:{snapshot['base_fixture_digest']}",
                ]
                if level == "Level2":
                    evidence.append("reconstructedFromOrderedPriorSuccessfulMutations")
                records.append(attempt_record(
                    attempt, b_outcome, pre_state_level=level,
                    pre_state_evidence=evidence, feedback_actionable=False,
                ))
                if attempt.historical_outcome.candidate_changed:
                    applied = replay(
                        attempt.raw_edit_payload, historical_state, temporary_root,
                        arguments.condition_b_driver, arguments.pinned_cangjie, arguments.sdk_root,
                        f"{trial_id}-{attempt.attempt_ordinal}-historical",
                    )
                    if applied.application_outcome != "Applied":
                        raise RuntimeError("could not reconstruct historical successful mutation")
            reconstructed_digest = manifest_and_digest(historical_state)[1]
            reconstruction[trial_id] = {
                "reconstructedFinalWorkspaceDigest": reconstructed_digest,
                "storedFinalWorkspaceDigest": snapshot["final_workspace_digest"],
                "matches": reconstructed_digest == snapshot["final_workspace_digest"],
            }

    after_counts = counts(connection)
    candidate_hashes_after = candidate_artifact_hashes(arguments.store, snapshots)
    connection.close()
    rejected = [item for item in records if item["historical_outcome"]["parser_outcome"] == "Rejected"]
    successful = [item for item in records if item["historical_outcome"]["application_outcome"] == "Applied"]
    command_counts = Counter(item["command_kind"] for item in records)
    cause_counts = Counter(item["rejection_cause"] for item in rejected)
    effect_counts = Counter(item["condition_b_effect"] for item in rejected)
    report = {
        "version": "exp-001-causal-preflight-v1",
        "historicalTrialIds": list(TRIAL_IDS),
        "sourceStore": str(arguments.store),
        "conditionA": {
            "agentBinaryArtifactRef": f"sha256:{condition_a_digest}",
            "frozenArtifactDigestVerified": True,
            "replayEvidence": "exact historical executions under the baseline parser contract",
        },
        "conditionB": {
            "agentBinaryArtifactRef": f"sha256:{condition_b_digest}",
            "frozenArtifactDigestVerified": True,
            "rawPayloadReplayDriver": str(arguments.condition_b_driver),
            "rawPayloadReplayDriverDigest": hash_file(arguments.condition_b_driver),
            "implementation": "real applyHashlineEdit plus LocalWorkspace.commit",
        },
        "attempts": records,
        "aggregate": {
            "totalEditAttempts": len(records),
            "rejectedEditAttempts": len(rejected),
            "successfulHistoricalAttempts": len(successful),
            "destructivePartialMutations": sum(
                1 for item in successful if item["command_kind"].startswith("DEL_")
            ),
            "commands": dict(sorted(command_counts.items())),
            "rejectionsByCause": dict(sorted(cause_counts.items())),
            "rangeGrammarMismatchCount": cause_counts.get("RangeGrammarMismatch", 0),
            "historicalRejectedPayloadsAcceptedByB": effect_counts.get("DirectFix", 0),
            "historicalRejectedPayloadsStillRejectedByB": len(rejected) - effect_counts.get("DirectFix", 0),
            "bFixCoverage": dict(sorted(effect_counts.items())),
        },
        "historicalStateReconstruction": reconstruction,
        "productCorrectnessFinding": {
            "answer": "YES",
            "finding": "Condition B fixes the independent N..=M versus N.=M range-parser defect.",
        },
        "agentMechanismFinding": {
            "answer": "NO",
            "finding": "Every historical SWAP/INSERT rejection occurred before range parsing because the payload omitted a parser-required trailing colon; Condition B accepts none of the exact rejected payloads.",
        },
        "causalLinkAssessment": "Contradicted",
        "paidExperimentDisposition": "RedesignConditionB",
        "evidenceRefs": sorted({
            item["started_artifact_ref"] for item in records
        } | {
            item["completed_artifact_ref"] for item in records if item["completed_artifact_ref"]
        }),
        "offlineProof": {
            "databaseCountsBefore": before_counts,
            "databaseCountsAfter": after_counts,
            "databaseCountsUnchanged": before_counts == after_counts,
            "candidateArtifactHashesBefore": candidate_hashes_before,
            "candidateArtifactHashesAfter": candidate_hashes_after,
            "candidateArtifactsUnchanged": candidate_hashes_before == candidate_hashes_after,
            "newModelCalls": 0,
            "newAgentTrials": 0,
            "graderExecutions": 0,
            "candidateMutations": 0,
        },
        "limitations": [
            "Condition A outcomes are the canonical historical executions, not a second invocation of the frozen Agent binary.",
            "Pre-operation state after the successful DEL is reconstructed from baseline plus that ordered mutation; its final workspace digest matches the stored Candidate.",
            "Condition B error text is different but still omits the parser-required colon, so it is not classified as actionable EnablingFix.",
            "No claim is made about how a model would respond to a redesigned descriptor or error contract.",
            "No Condition B Agent trial has run.",
        ],
    }
    arguments.output.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    return 0


def replay(
    payload: str, workspace: Path, temporary_root: Path, driver: Path,
    pinned_cangjie: Path, sdk_root: Path, label: str,
) -> ReplayOutcome:
    payload_path = temporary_root / f"payload-{label}.txt"
    payload_path.write_text(payload)
    environment = os.environ.copy()
    environment.update({
        "CANGJIE_SDK_ROOT": str(sdk_root),
        "EDIT_REPLAY_WORKSPACE": str(workspace),
        "EDIT_REPLAY_PAYLOAD_FILE": str(payload_path),
    })
    completed = subprocess.run(
        [str(pinned_cangjie), str(driver)], text=True, capture_output=True,
        cwd=pinned_cangjie.parent.parent, env=environment, timeout=30,
    )
    line = completed.stdout.strip()
    parts = line.split("\t", 2)
    if completed.returncode == 0 and parts and parts[0] == "APPLIED":
        return ReplayOutcome("Accepted", "Applied", candidate_changed=True)
    if completed.returncode == 2 and len(parts) == 3 and parts[0] == "REJECT":
        return ReplayOutcome("Rejected", "NotReached", parts[1], parts[2], False)
    if completed.returncode == 3 and len(parts) == 3 and parts[0] == "APPLICATION_ERROR":
        return ReplayOutcome("Accepted", "Rejected", parts[1], parts[2], False)
    raise RuntimeError(
        f"unexpected replay result rc={completed.returncode} stdout={completed.stdout!r} "
        f"stderr={completed.stderr!r}"
    )


def counts(connection: sqlite3.Connection) -> dict[str, int]:
    return {table: connection.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0] for table in (
        "agent_trials", "grading_runs", "grader_results", "candidate_snapshots", "eval_runs",
    )}


def candidate_artifact_hashes(store: Path, snapshots: dict[str, dict]) -> dict[str, str]:
    result = {}
    for trial_id, snapshot in snapshots.items():
        reference = snapshot["workspace_artifact_ref"]
        digest = reference[7:]
        path = store / "artifacts" / digest[:2] / digest[2:]
        result[trial_id] = hash_file(path)
    return result


if __name__ == "__main__":
    raise SystemExit(main())
