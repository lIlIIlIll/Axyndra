from __future__ import annotations

import json
import unittest
from pathlib import Path

from omp_evals.benchmark import build_condition
from omp_evals.experiment_invariants import experiment_plan_from_mapping
from omp_evals.model_stream_fault import model_stream_fault_profile_digest
from omp_evals.task import parse_qualified_task
from omp_evals.util import hash_file


ROOT = Path(__file__).resolve().parents[2]
EXPERIMENT = ROOT / "eval_experiments/EXP-003-controlled-incomplete-stream-recovery"


class Exp003FreezeContract(unittest.TestCase):
    def test_plan_is_frozen_without_executions(self) -> None:
        manifest = read_json(EXPERIMENT / "manifest.json")
        plan_value = read_json(EXPERIMENT / "experiment-plan.json")
        plan = experiment_plan_from_mapping(plan_value)

        self.assertEqual(manifest["status"], "FROZEN")
        self.assertEqual(manifest["readiness"], "READY_FOR_EXECUTION")
        self.assertEqual(manifest["futureFormalTrials"], 10)
        self.assertEqual(manifest["formalTrialsExecuted"], 0)
        self.assertEqual(plan.trials_per_task, 5)
        self.assertEqual(len(plan.order), 10)
        self.assertTrue(all(item.trial_id is None for item in plan.order))
        self.assertEqual(
            [item.ordinal for item in plan.order], list(range(10))
        )

    def test_fault_is_controlled_and_recovery_is_the_only_variable(self) -> None:
        task = parse_qualified_task(
            ROOT / "eval_tasks/cangjie_clamp_missing/qualified-task.json"
        )
        condition_refs = [
            read_json(EXPERIMENT / name)["conditionRef"]
            for name in ("condition-a.json", "condition-b.json")
        ]
        condition_values = [read_json(ROOT / ref) for ref in condition_refs]
        conditions = [
            build_condition(ROOT / ref, task, Path(value["agentBinary"]), None)
            for ref, value in zip(condition_refs, condition_values)
        ]
        a, b = (condition.manifest for condition in conditions)
        omitted = {
            "id", "arguments", "modelStreamRecoveryPolicy",
            "modelStreamRecoveryPolicyDigest",
        }
        projection = lambda value: {
            key: item for key, item in value.items() if key not in omitted
        }

        self.assertEqual(projection(a), projection(b))
        self.assertEqual(
            a["modelStreamFaultProfileDigest"],
            b["modelStreamFaultProfileDigest"],
        )
        self.assertNotEqual(
            a["modelStreamRecoveryPolicyDigest"],
            b["modelStreamRecoveryPolicyDigest"],
        )
        self.assertEqual(
            arguments_without_recovery_mode(a["arguments"]),
            arguments_without_recovery_mode(b["arguments"]),
        )
        self.assertEqual(argument_value(a["arguments"], "--model-attempt-recovery"), "disabled")
        self.assertEqual(argument_value(b["arguments"], "--model-attempt-recovery"), "recovery-v1")
        profile = read_json(EXPERIMENT / "fault-profile.json")
        digest = profile.pop("digest")
        self.assertEqual(model_stream_fault_profile_digest(profile), digest)

    def test_readiness_and_historical_result_hashes_are_bound(self) -> None:
        readiness = read_json(EXPERIMENT / "runtime-readiness.json")
        for evidence in readiness["conditions"].values():
            self.assertEqual(
                evidence["modelPathDynamicLinkReadiness"]["readiness"], "Pass"
            )
            self.assertEqual(evidence["runtimeReadiness"]["readiness"], "Ready")
            self.assertEqual(evidence["toolSandboxReadiness"]["readiness"], "Ready")
            self.assertEqual(
                evidence["providerSettingsCompatibility"]["readiness"], "Ready"
            )
        self.assertEqual(readiness["providerRequests"], 0)
        self.assertEqual(readiness["realModelCalls"], 0)
        self.assertEqual(readiness["credentialReads"], 0)

        parent = read_json(EXPERIMENT / "parent-evidence.json")["EXP-002R2"]
        r2 = ROOT / "eval_experiments/EXP-002R2-runtime-closure-refreeze"
        for name, digest in parent["resultHashes"].items():
            self.assertEqual(hash_file(r2 / name), digest)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


def argument_value(arguments: list[str], name: str) -> str:
    index = arguments.index(name)
    return arguments[index + 1]


def arguments_without_recovery_mode(arguments: list[str]) -> list[str]:
    result = list(arguments)
    index = result.index("--model-attempt-recovery")
    del result[index:index + 2]
    return result


if __name__ == "__main__":
    unittest.main()
