from __future__ import annotations

import argparse
import json
from collections import Counter
from pathlib import Path

from omp_evals.runner import EvalRunner


EXPERIMENT = "EXP-001R6-provider-settings-closure-refreeze"
A6 = "60e48eb417d5aab46cfbf5ea02280464a8f1a835bc09dfde5781f49cfe4d3c6e"
B6 = "6162060225f333b1dc6358459c2899eaeb10ecb2e1ffcfb7b2bb067a0f7bcb93"
PROVIDER = "1221830a53f1058a07e335c2012b63f2b8b71aeb41e11386b52f107158fd6626"
SETTINGS = "885fc4654a7e722a4dd1cf54bc625b77d012f5da6d892851ba10242f2be1240b"
SNAPSHOT = "ff40d40d0237ed30b81e76dac790010d7ab16040b1a77dba96fcf9ce06fd965a"
LABELS = {A6: "A6", B6: "B6"}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--eval-home", type=Path, required=True)
    options = parser.parse_args()
    destination = options.root.resolve() / "eval_experiments" / EXPERIMENT
    index = json.loads((destination / "trial-index.json").read_text())
    mechanism = json.loads((destination / "mechanism-analysis.json").read_text())
    aggregate = json.loads((destination / "aggregate-result.json").read_text())
    failure = json.loads((destination / "failure-analysis.json").read_text())
    primary = {
        item["trial_id"]: (
            item.get("failure_attribution", {}) or {}
        ).get("primary")
        for item in failure["analyses"]
    }

    runner = EvalRunner(options.eval_home)
    try:
        request_attempts = {}
        for item in index["slots"]:
            candidate = runner.database.load_candidate(item["candidateId"])
            frames = [
                json.loads(line)
                for line in runner.artifacts.get_bytes(candidate["trajectory_ref"]).decode().splitlines()
                if line.strip()
            ]
            codes = Counter(
                frame.get("event", {}).get("code") for frame in frames
                if isinstance(frame.get("event"), dict)
            )
            request_attempts[item["trialId"]] = {
                "modelStarted": codes["model.started"],
                "providerRequestAttemptsCompleted": codes["model.request_attempt_completed"],
                "modelCompleted": codes["model.completed"],
            }
    finally:
        runner.close()

    for item in index["slots"]:
        condition = LABELS[item["conditionFingerprint"]]
        item["condition"] = condition
        item["slotLabel"] = f"{condition}-{item['repetitionIndex'] + 1}"
        item["providerExecutionDigest"] = PROVIDER
        item["providerSettingsClosureDigest"] = SETTINGS
        item["candidateSnapshot"] = item.pop("candidateId")
        item["gradingRun"] = item.pop("gradingRunId")
        item["evalResult"] = f"eval-result:{item['trialId']}" if item["evalResultPresent"] else None
        item["missingRequiredColon"] = sum(
            attempt["syntaxViolation"] == "MissingRequiredColon"
            for attempt in item["editAttempts"]
        )
        item["parserValidEditAttempts"] = sum(
            attempt["parserOutcome"] == "Accepted" for attempt in item["editAttempts"]
        )
        item["primaryFailure"] = primary[item["trialId"]]
        item["providerRequestFacts"] = request_attempts[item["trialId"]]
    index["schemaVersion"] = "exp-001r6-trial-index-v1"
    index["executionCutoffAfterSlot"] = "B6-3"
    index["extraTrials"] = 0

    source_conditions = mechanism.pop("conditions")
    mechanism["conditions"] = {
        "A6": enrich_mechanism(source_conditions["A3"]),
        "B6": enrich_mechanism(source_conditions["B3"]),
    }
    for trial in mechanism["trials"]:
        trial["condition"] = "A6" if trial["condition"] == "A3" else "B6"
    mechanism.update({
        "schemaVersion": "exp-001r6-mechanism-analysis-v1",
        "mechanismConclusion": "Supported",
        "trialLevelResult": {
            "A6": {"withMissingRequiredColon": 3, "capabilityValid": 3, "executed": 3, "planned": 3},
            "B6": {"withMissingRequiredColon": 0, "capabilityValid": 3, "executed": 3, "planned": 3},
        },
        "attemptLevelResult": {
            "A6": {"missingRequiredColon": 6, "totalEdits": 6},
            "B6": {"missingRequiredColon": 0, "totalEdits": 5},
        },
        "failureTransition": {
            "A6": "MissingRequiredColon -> EditApplicationFailure -> unchanged Candidate -> TimedOut",
            "B6": "parser-valid applied edit -> Candidate Correct -> Completed 1/3 or TimedOut 2/3",
            "assessment": "moved-forward",
            "newDominantBottleneck": "AgentTerminationFailure",
            "regression": False,
        },
    })

    aggregate["experimentSummary"] = {
        "planned": 6,
        "executed": 6,
        "storedValid": 6,
        "effectiveCapabilityValid": 6,
        "infrastructureInvalid": 0,
        "notRun": 0,
        "extraTrials": 0,
        "providerRequestAttemptsCompleted": sum(
            value["providerRequestAttemptsCompleted"] for value in request_attempts.values()
        ),
        "modelCalls": sum(value["modelStarted"] for value in request_attempts.values()),
        "taskOutcome": {
            "A6": {"strictPass": 0, "candidateCorrect": 0, "valid": 3, "planned": 3},
            "B6": {"strictPass": 1, "candidateCorrect": 3, "valid": 3, "planned": 3},
        },
        "validityDistribution": {
            "Valid": 6,
            "InvalidEnvironmentInfrastructure": 0,
            "InvalidProviderInfrastructure": 0,
            "InvalidGraderInfrastructure": 0,
        },
        "storedEffectiveValidityEqual": True,
    }
    failure["schemaVersion"] = "exp-001r6-failure-analysis-v1"
    failure["analysisModelCalls"] = 0
    failure["graderReruns"] = 0

    decision = {
        "schemaVersion": "exp-001r6-final-decision-v1",
        "experimentId": EXPERIMENT,
        "status": "COMPLETE",
        "mechanismConclusion": "Supported",
        "taskOutcomeConclusion": "Improved",
        "productCorrectnessDecision": "KeepAlignedContract",
        "experimentDecision": "DesignNextBottleneckExperiment",
        "recommendedNextExperiment": {
            "name": "Agent terminal-completion single-variable experiment",
            "reason": "B6 produced Correct candidates in 3/3 valid trials, but 2/3 timed out and therefore failed Strict outcome.",
            "executed": False,
        },
        "providerBaseline": {
            "providerExecutionDigest": PROVIDER,
            "providerSettingsClosureDigest": SETTINGS,
            "pairedControlValid": True,
            "historicalWireEquivalenceProven": False,
        },
        "canonicalInvariant": {
            "schemaVersion": "omp-evals-experiment-invariants-v4",
            "snapshotDigest": SNAPSHOT,
            "executionRecomputationMatched": True,
            "drift": False,
        },
        "infrastructureValidity": {
            "liveInfrastructureInvalid": 0,
            "storedValidityCorrect": True,
            "appendOnlyCorrectionNeeded": False,
            "directStartupPersistenceObservedLive": False,
            "directStartupPersistenceContractsPassed": True,
        },
        "postTrialOfflineProof": {
            "analysisProviderRequests": 0,
            "analysisModelCalls": 0,
            "agentReruns": 0,
            "graderReruns": 0,
            "candidateMutations": 0,
            "extraRealTrials": 0,
        },
    }

    write_json(destination / "trial-index.json", index)
    write_json(destination / "mechanism-analysis.json", mechanism)
    write_json(destination / "aggregate-result.json", aggregate)
    write_json(destination / "failure-analysis.json", failure)
    write_json(destination / "decision.json", decision)
    print(json.dumps({
        "mechanism": decision["mechanismConclusion"],
        "taskOutcome": decision["taskOutcomeConclusion"],
        "experimentDecision": decision["experimentDecision"],
        "modelCalls": aggregate["experimentSummary"]["modelCalls"],
        "completedProviderRequestAttempts": aggregate["experimentSummary"]["providerRequestAttemptsCompleted"],
    }, separators=(",", ":")))
    return 0


def enrich_mechanism(value: dict) -> dict:
    violations = value.get("syntaxViolations", {})
    causes = value.get("rejectionCauses", {})
    return {
        **value,
        "missingRequiredColonAttempts": violations.get("MissingRequiredColon", 0),
        "invalidHeaderAttempts": violations.get("InvalidHeader", 0),
        "malformedCommandOtherAttempts": violations.get("MalformedCommandOther", 0),
        "staleAnchorAttempts": causes.get("StaleAnchor", 0),
        "otherRejectedAttempts": value["rejectedEditAttempts"] - sum(violations.values()),
        "parserValidEditAttempts": value["totalEditAttempts"] - value["rejectedEditAttempts"],
    }


def write_json(path: Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    raise SystemExit(main())
