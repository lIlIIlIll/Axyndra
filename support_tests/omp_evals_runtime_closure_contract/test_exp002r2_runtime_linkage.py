from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

from omp_evals.benchmark import load_suite
from omp_evals.model import AgentTermination, ExperimentalCondition, TrialValidity
from omp_evals.runner import EvalRunner, InvalidTrialError
from omp_evals.runtime_closure import RuntimeClosureError, validate_runtime_closure
from omp_evals.storage import ArtifactStore
from omp_evals.util import hash_file
from omp_evals.worker import WorkerResult, _runtime_linkage_failure_phase


class Exp002R2RuntimeLinkageContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = Path(__file__).resolve().parents[2]
        cls.experiment = cls.root / "eval_experiments/EXP-002R2-runtime-closure-refreeze"
        cls.artifacts = ArtifactStore(Path.home() / ".omp-evals/artifacts")

    def load(self, name: str):
        return json.loads((self.experiment / name).read_text())

    def test_runtime_closure_v2_is_self_describing_and_symbol_validated(self) -> None:
        closure = self.load("runtime-closure.json")
        self.assertEqual(closure["version"], "omp-evals-runtime-closure-v2")
        self.assertEqual(closure["target"]["triple"], "x86_64-unknown-linux-gnu")
        self.assertTrue(closure["sdk_identity"]["compilerVersion"])
        self.assertTrue(closure["dependency_graph"])
        self.assertEqual(closure["linkage_validation"]["result"], "Pass")
        self.assertTrue(closure["linkage_validation"]["symbolVersionsResolvable"])
        self.assertTrue(closure["executable_runtime_compatibility_digest"])
        validate_runtime_closure(closure, self.artifacts)

    def test_historical_failure_is_a_negative_readiness_fixture(self) -> None:
        readiness = self.load("model-path-dynamic-link-readiness.json")
        negative = readiness["negativeHistoricalFixture"]
        self.assertEqual(negative["readiness"], "Fail")
        self.assertEqual((negative["provider_requests"], negative["model_calls"],
                          negative["credential_reads"]), (0, 0, 0))
        self.assertFalse(negative["symbol_version_validation"])

    def test_fixed_closure_passes_both_sandboxed_model_path_probes(self) -> None:
        readiness = self.load("model-path-dynamic-link-readiness.json")
        for label in ("Control", "RecoveryV1"):
            value = readiness["conditions"][label]
            self.assertEqual(value["readiness"], "Pass")
            self.assertTrue(value["static_dependency_closure"])
            self.assertTrue(value["symbol_version_validation"])
            self.assertTrue(value["sandbox_process_started"])
            self.assertTrue(value["model_path_initialized"])
            self.assertTrue(value["protocol_ready"])
            self.assertTrue(value["clean_shutdown"])
            self.assertFalse(value["residual_process"])
            self.assertEqual((value["provider_requests"], value["model_calls"],
                              value["credential_reads"]), (0, 0, 0))

    def test_control_and_recovery_only_differ_by_policy(self) -> None:
        proof = self.load("controlled-variables.json")
        self.assertTrue(all(proof["equal"].values()))
        self.assertTrue(proof["samePromptContextGraders"])
        self.assertTrue(proof["policyDigestDifferent"])
        self.assertTrue(proof["exactControlledProjectionEqual"])
        self.assertEqual(proof["onlyIndependentVariable"], "ModelStreamRecoveryPolicy")

    def test_frozen_plan_has_twelve_null_slots_and_original_seed_family(self) -> None:
        plan = self.load("experiment-plan.json")
        self.assertEqual(plan["futureRealTrials"], 12)
        self.assertEqual(len(plan["frozenExecutionWindowOrder"]), 12)
        self.assertIsNone(plan["allTrialIds"])
        self.assertIsNone(plan["allGradingRunIds"])
        self.assertEqual([item["seed"] for item in plan["subplans"]], [2002, 2003])

    def test_typed_runtime_linkage_failure_persists_direct_invalidity(self) -> None:
        phase_frames = ({"type": "agent_event", "event": {"code": "model.started"}},)
        self.assertTrue(_runtime_linkage_failure_phase(phase_frames))
        self.assertFalse(_runtime_linkage_failure_phase((*phase_frames, {
            "type": "agent_event", "event": {"code": "model.request_attempt_completed"},
        })))

        class LinkageFailureWorker:
            def run(self, *args, **kwargs):
                return WorkerResult(
                    pid=321, termination=AgentTermination.CRASHED, exit_code=127,
                    frames=phase_frames,
                    usage={}, final_answer="", diagnostics=("typed linkage failure",),
                    duration_millis=1, quiesce_millis=0, startup_ready=True,
                    infrastructure_failure="ConditionRuntimeLinkageFailure",
                )

        task = load_suite(
            self.root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json"
        )[1][0]
        condition = ExperimentalCondition(
            id="linkage-failure", version="1", fingerprint="linkage-failure",
            manifest={"id": "linkage-failure"}, agent={}, agent_binary=sys.executable,
        )
        with tempfile.TemporaryDirectory() as raw:
            runner = EvalRunner(Path(raw) / "eval-home", worker=LinkageFailureWorker())
            try:
                with self.assertRaises(InvalidTrialError) as caught:
                    runner.run(task, Path(sys.executable), condition=condition)
                trial = runner.database.load_trial(caught.exception.trial_id)
                authoritative = runner.database.load_authoritative_trial(caught.exception.trial_id)
                self.assertEqual(trial["validity"], TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE.value)
                self.assertEqual(authoritative["validity"], TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE.value)
                self.assertIsNone(trial["candidate_snapshot_id"])
            finally:
                runner.close()

    def test_historical_exp002r_remains_append_only_and_authoritatively_queryable(self) -> None:
        evidence = self.load("trial-validity-persistence.json")
        historical = evidence["historicalCompatibility"]
        self.assertEqual(historical["storedValidity"], "Valid")
        self.assertEqual(historical["authoritativeValidity"], "InvalidEnvironmentInfrastructure")
        self.assertFalse(historical["rawRowRewritten"])
        parent = self.load("parent-evidence.json")
        root = self.root / "eval_experiments/EXP-002R-final-response-attempt-recovery"
        self.assertEqual(
            {str(path.relative_to(root)): hash_file(path)
             for path in sorted(root.rglob("*")) if path.is_file()},
            parent["frozenArtifactHashes"],
        )

    def test_offline_and_secret_free_freeze(self) -> None:
        readiness = self.load("runtime-readiness.json")
        self.assertEqual((readiness["providerRequests"], readiness["modelCalls"],
                          readiness["credentialReads"]), (0, 0, 0))
        decision = self.load("decision.json")
        self.assertEqual(decision["realProviderCapabilityTrials"], 0)
        security = self.load("security-prerequisites.json")
        self.assertFalse(security["credentialValueRead"])


if __name__ == "__main__":
    unittest.main()
