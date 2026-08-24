from __future__ import annotations

import json
import unittest
from pathlib import Path

from omp_evals.benchmark import build_condition
from omp_evals.experiment_invariants import experiment_plan_from_mapping
from omp_evals.task import parse_qualified_task
from omp_evals.util import hash_file


ROOT = Path(__file__).resolve().parents[2]
EXPERIMENT = ROOT / "eval_experiments/EXP-003R-controlled-incomplete-stream-recovery-replication"


class Exp003RFreezeContract(unittest.TestCase):
    def test_corrected_replication_is_frozen_without_executions(self) -> None:
        manifest = read_json(EXPERIMENT / "manifest.json")
        decision = read_json(EXPERIMENT / "decision.json")
        plan = experiment_plan_from_mapping(read_json(EXPERIMENT / "experiment-plan.json"))
        self.assertEqual((manifest["status"], manifest["readiness"]),
                         ("FROZEN", "READY_FOR_EXECUTION"))
        self.assertEqual(manifest["futureFormalTrials"], 10)
        self.assertEqual(manifest["formalTrialsExecuted"], 0)
        self.assertEqual(decision["recoveryV1CurrentSourceContract"], "VERIFIED")
        self.assertEqual(decision["partialStateIsolation"], "VERIFIED")
        self.assertEqual(len(plan.order), 10)
        self.assertEqual(sum(1 for item in plan.order if item.condition_fingerprint == plan.condition_fingerprints[0]), 5)
        self.assertEqual(sum(1 for item in plan.order if item.condition_fingerprint == plan.condition_fingerprints[1]), 5)
        self.assertTrue(all(item.trial_id is None for item in plan.order))

    def test_only_recovery_policy_differs(self) -> None:
        task = parse_qualified_task(ROOT / "eval_tasks/cangjie_clamp_missing/qualified-task.json")
        refs = [read_json(EXPERIMENT / name)["conditionRef"]
                for name in ("condition-a.json", "condition-b.json")]
        values = [read_json(ROOT / ref) for ref in refs]
        conditions = [build_condition(ROOT / ref, task, Path(value["agentBinary"]), None)
                      for ref, value in zip(refs, values)]
        omitted = {"id", "arguments", "modelStreamRecoveryPolicy",
                   "modelStreamRecoveryPolicyDigest"}
        project = lambda value: {key: item for key, item in value.items() if key not in omitted}
        self.assertEqual(project(conditions[0].manifest), project(conditions[1].manifest))
        self.assertNotEqual(conditions[0].manifest["modelStreamRecoveryPolicyDigest"],
                            conditions[1].manifest["modelStreamRecoveryPolicyDigest"])
        self.assertEqual(conditions[0].manifest["modelStreamFaultProfileDigest"],
                         conditions[1].manifest["modelStreamFaultProfileDigest"])

    def test_safety_endpoints_and_historical_hashes_are_bound(self) -> None:
        endpoints = read_json(EXPERIMENT / "endpoints.json")["safety"]
        self.assertEqual(endpoints["CanonicalStatePartialLeakRate"], 0)
        self.assertEqual(endpoints["SemanticRetryInputPartialLeakRate"], 0)
        self.assertEqual(endpoints["FinalAnswerProjectionPartialLeakRate"], 0)
        self.assertTrue(endpoints["DiagnosticTraceContainsPartial"])
        history = read_json(EXPERIMENT / "historical-integrity.json")
        exp003 = ROOT / "eval_experiments/EXP-003-controlled-incomplete-stream-recovery"
        for name, digest in history["EXP-003ResultHashes"].items():
            self.assertEqual(hash_file(exp003 / name), digest)

    def test_readiness_is_credential_free(self) -> None:
        readiness = read_json(EXPERIMENT / "runtime-readiness.json")
        for evidence in readiness["conditions"].values():
            self.assertEqual(evidence["modelPathDynamicLinkReadiness"]["readiness"], "Pass")
            self.assertEqual(evidence["runtimeReadiness"]["readiness"], "Ready")
            self.assertEqual(evidence["toolSandboxReadiness"]["readiness"], "Ready")
            self.assertEqual(evidence["providerSettingsCompatibility"]["readiness"], "Ready")
        self.assertEqual((readiness["providerRequests"], readiness["realModelCalls"],
                          readiness["credentialReads"]), (0, 0, 0))


def read_json(path: Path) -> dict:
    return json.loads(path.read_text())


if __name__ == "__main__":
    unittest.main()
