from __future__ import annotations

import json
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path

from omp_evals.benchmark import (
    BenchmarkRunner, build_experiment_plan, validate_experiment_plan_inputs,
)
from omp_evals.experiment_invariants import (
    EXPERIMENT_INVARIANT_SCHEMA_VERSION, ExperimentInvariantMismatch,
    LEGACY_TYPED_INVARIANT_SCHEMA_VERSION,
    UnsupportedInvariantSchema, build_experiment_invariant_snapshot,
    canonical_invariant_bytes, experiment_plan_from_mapping,
    invariant_snapshot_digest, parse_experiment_invariant_snapshot,
)
from omp_evals.model import (
    CachePolicy, EvalSuite, EvalSuiteTask, ExperimentalCondition,
    QualifiedEvalTask, ResourcePolicy, SuiteKind, TaskLifecycle, jsonable,
)
from omp_evals.util import canonical_json, hash_file, hash_json


class ExperimentInvariantContractTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = Path(__file__).resolve().parents[2]
        self.task = QualifiedEvalTask(
            id="invariant-task", version="1", category="BugFix", prompt="fix it",
            fixture="fixture", fixture_digest="fixture-digest", base_revision="base",
            visible_constraints=("keep API",),
            resource_policy=ResourcePolicy(agent_wall_time_seconds=300),
            cache_policy=CachePolicy(), network_policy="ProviderOnly",
            graders=({"id": "targeted", "version": "1", "severity": "Gate"},),
            grader_bundle="hidden", task_fingerprint="task-fingerprint",
            qualification_fingerprint="qualification", bundle_root=str(self.root),
            lifecycle=TaskLifecycle.QUALIFIED,
        )
        self.suite = EvalSuite(
            id="suite", version="1", kind=SuiteKind.RESEARCH,
            tasks=(EvalSuiteTask("invariant-task", "1", "task-fingerprint", ""),),
            metadata={}, fingerprint="suite-fingerprint", root=str(self.root),
        )
        self.conditions = (self._condition("A", "contract-a"), self._condition("B", "contract-b"))

    def _condition(self, name: str, contract: str) -> ExperimentalCondition:
        manifest = {
            "id": name, "provider": "DEEPSEEK", "model": "DEEPSEEK/model",
            "settingsManifestDigest": "settings", "systemPromptDigest": "unsupported",
            "generalPromptDigest": "unsupported", "contextPolicyDigest": "unsupported",
            "compactionPolicyDigest": "unsupported", "permissionProfileDigest": "permissions",
            "nonEditToolSetDigest": "non-edit", "toolSetDigest": "tools",
            "runtimeClosureDigest": "closure-" + name,
            "runtimeClosureRef": "sha256:closure-" + name,
            "environmentFingerprint": "environment-v1",
            "toolExecutionPlaneDigest": "tool-plane-v1",
            "toolExecutionPlane": {"sandboxPolicyDigest": "sandbox-v1"},
            "editModelContractDigest": contract,
        }
        return ExperimentalCondition(
            id=name, version="1", fingerprint=hash_json(manifest),
            manifest=manifest, agent={}, agent_binary="/unused",
        )

    def _plan(self):
        return build_experiment_plan(
            "experiment-current", "PairedAB", self.suite, (self.task,),
            self.conditions, 3, 1004, "2026-08-13T00:00:00Z",
        )

    def test_freeze_and_runtime_use_same_canonical_builder(self) -> None:
        plan = self._plan()
        current = build_experiment_invariant_snapshot((self.task,), self.conditions, True)
        self.assertEqual(plan.invariant_snapshot, current)
        validate_experiment_plan_inputs(self.suite, (self.task,), self.conditions, plan)

    def test_tool_plane_runtime_environment_round_trip(self) -> None:
        snapshot = self._plan().invariant_snapshot
        self.assertEqual(snapshot.tool_execution_plane_digest, "tool-plane-v1")
        self.assertEqual(snapshot.environment_class, "environment-v1")
        self.assertEqual(
            [item.runtime_closure_digest for item in snapshot.conditions],
            ["closure-A", "closure-B"],
        )

    def test_serialization_is_deterministic_and_reload_equal(self) -> None:
        plan = self._plan()
        first = canonical_json(jsonable(plan))
        second = canonical_json(jsonable(plan))
        self.assertEqual(first, second)
        loaded = experiment_plan_from_mapping(json.loads(first))
        self.assertEqual(loaded, plan)
        self.assertEqual(canonical_invariant_bytes(loaded.invariant_snapshot),
                         canonical_invariant_bytes(plan.invariant_snapshot))

    def test_tool_plane_mutation_is_rejected(self) -> None:
        mutated_conditions = []
        for condition in self.conditions:
            changed = dict(condition.manifest)
            changed["toolExecutionPlaneDigest"] = "tool-plane-v2"
            mutated_conditions.append(replace(condition, manifest=changed))
        with self.assertRaises(ExperimentInvariantMismatch) as caught:
            validate_experiment_plan_inputs(
                self.suite, (self.task,), tuple(mutated_conditions), self._plan()
            )
        self.assertTrue(any("tool_execution_plane_digest" in x["field"] for x in caught.exception.differences))

    def test_task_fingerprint_mutation_is_rejected(self) -> None:
        mutated = replace(self.task, task_fingerprint="other-task")
        with self.assertRaises(ExperimentInvariantMismatch):
            validate_experiment_plan_inputs(self.suite, (mutated,), self.conditions, self._plan())

    def test_condition_fingerprint_mutation_is_rejected(self) -> None:
        mutated = replace(self.conditions[0], fingerprint="other-condition")
        with self.assertRaises(ExperimentInvariantMismatch):
            validate_experiment_plan_inputs(self.suite, (self.task,), (mutated, self.conditions[1]), self._plan())

    def test_budget_mutation_is_rejected(self) -> None:
        policy = replace(self.task.resource_policy, agent_wall_time_seconds=301)
        mutated = replace(self.task, resource_policy=policy)
        with self.assertRaises(ExperimentInvariantMismatch):
            validate_experiment_plan_inputs(self.suite, (mutated,), self.conditions, self._plan())

    def test_non_invariant_created_at_is_ignored(self) -> None:
        plan = replace(self._plan(), created_at="later-report-time")
        validate_experiment_plan_inputs(self.suite, (self.task,), self.conditions, plan)

    def test_mismatch_stops_before_database_or_trial(self) -> None:
        class ForbiddenDatabase:
            def __getattr__(self, name):
                raise AssertionError(f"database accessed before invariant validation: {name}")
        class FakeRunner:
            database = ForbiddenDatabase()
        mutated = replace(self.task, task_fingerprint="other-task")
        with self.assertRaises(ExperimentInvariantMismatch):
            BenchmarkRunner(FakeRunner()).execute_plan(
                self.suite, (mutated,), self.conditions, self._plan(), Path("/unused"), None,
            )

    def test_current_schema_missing_field_is_rejected(self) -> None:
        value = jsonable(self._plan().invariant_snapshot)
        del value["tool_execution_plane_digest"]
        with self.assertRaisesRegex(ValueError, "missing experiment invariant fields"):
            parse_experiment_invariant_snapshot(value)

    def test_current_schema_unknown_field_is_rejected(self) -> None:
        value = jsonable(self._plan().invariant_snapshot)
        value["futureInvariant"] = "must-not-be-ignored"
        with self.assertRaisesRegex(ValueError, "unknown experiment invariant fields"):
            parse_experiment_invariant_snapshot(value)

    def test_unknown_schema_is_rejected(self) -> None:
        value = jsonable(self._plan())
        value["invariant_schema_version"] = "999"
        value["invariant_snapshot"]["schema_version"] = "999"
        with self.assertRaises(UnsupportedInvariantSchema):
            experiment_plan_from_mapping(value)

    def test_legacy_plan_is_readable_but_not_upgraded(self) -> None:
        value = json.loads((
            self.root / "eval_experiments/EXP-001R3-tool-sandbox-readiness-refreeze/experiment-plan.json"
        ).read_text())
        plan = experiment_plan_from_mapping(value)
        self.assertIsNone(plan.invariant_schema_version)
        self.assertIsNone(plan.invariant_snapshot)
        self.assertEqual(plan.invariants["toolExecutionPlaneDigest"], "b6697b51616f6f4174acbefb452489e9d7b900243ebaaaf3c9588953522ed607")

    def test_frozen_exp001r4_is_current_schema_and_has_no_trials(self) -> None:
        experiment = self.root / "eval_experiments/EXP-001R4-canonical-experiment-invariants-refreeze"
        value = json.loads((experiment / "experiment-plan.json").read_text())
        plan = experiment_plan_from_mapping(value)
        self.assertEqual(plan.invariant_schema_version, LEGACY_TYPED_INVARIANT_SCHEMA_VERSION)
        self.assertEqual(
            plan.invariant_snapshot_digest,
            "18b71e798ef00e2d7324648cec04916a470b1b412e729cf4b53c2c6059ab7486",
        )
        self.assertEqual(len(plan.order), 6)
        self.assertTrue(all(item.trial_id is None for item in plan.order))
        readiness = json.loads((experiment / "readiness.json").read_text())
        self.assertTrue(readiness["executableExperimentReady"])
        self.assertEqual((readiness["modelCalls"], readiness["providerRequests"]), (0, 0))

    def test_old_exp001r3_artifacts_are_immutable(self) -> None:
        experiment = self.root / "eval_experiments/EXP-001R3-tool-sandbox-readiness-refreeze"
        expected = {
            "experiment-plan.json": "ec6ac2c8bbc71aa030f1ce6150ef6a2badfa2209f98d4e247a9b76b25bc2124f",
            "decision.json": "68f167e2622b3d23997144caadb578b9b0e24dca94b7fcca4a76e7c30ad9d9c9",
            "condition-a3.json": "8c167fc12022b634b872c9d25362f9afc80f36566482aba79e5ae6c4f3c95298",
            "condition-b3.json": "ef6b40d2ec5a18b4848f358c6e55d73680649697526873de11d3904287e94678",
        }
        self.assertEqual({name: hash_file(experiment / name) for name in expected}, expected)

    def test_snapshot_contains_no_credential_value(self) -> None:
        encoded = canonical_invariant_bytes(self._plan().invariant_snapshot).decode()
        self.assertNotIn("DEEPSEEK_API_KEY", encoded)
        self.assertNotIn("Authorization", encoded)

    def test_snapshot_digest_covers_full_typed_snapshot(self) -> None:
        snapshot = self._plan().invariant_snapshot
        self.assertEqual(invariant_snapshot_digest(snapshot), sha256(canonical_invariant_bytes(snapshot)))
        changed = replace(snapshot, tool_execution_plane_digest="changed")
        self.assertNotEqual(invariant_snapshot_digest(snapshot), invariant_snapshot_digest(changed))


def sha256(value: bytes) -> str:
    import hashlib
    return hashlib.sha256(value).hexdigest()


if __name__ == "__main__":
    unittest.main()
