from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from omp_evals.benchmark import BenchmarkRunner, _summary, load_suite
from omp_evals.model import (
    ConditionRuntimeReadiness, ExperimentalCondition, RuntimeReadinessResult,
    ToolExecutionPlaneReadinessResult, ToolSandboxReadiness, TrialValidity,
)
from omp_evals.runner import _worker_validity
from omp_evals.storage import EvalDatabase
from omp_evals.worker import ProcessAgentWorker


class ToolSandboxReadinessContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.root = Path(__file__).resolve().parents[2]
        cls.experiment = cls.root / "eval_experiments/EXP-001R3-tool-sandbox-readiness-refreeze"

    def test_outer_launch_declares_private_tmp_for_nested_sandbox(self) -> None:
        root = Path(tempfile.mkdtemp(prefix="tool-plane-launch-"))
        for name in ("workspace", "home", "tmp"):
            (root / name).mkdir()
        argv, env, cwd = ProcessAgentWorker()._launch_plan(
            ["/usr/bin/true"], Path("/usr/bin/true"), root / "workspace",
            root / "home", root / "tmp", {}, "Denied", set(), None,
        )
        self.assertIn(["--tmpfs", "/tmp"], [argv[i:i + 2] for i in range(len(argv) - 1)])
        self.assertIn("--clearenv", argv)
        self.assertIn("--unshare-net", argv)
        self.assertEqual(env, {})
        self.assertEqual(cwd, "/")

    def test_typed_sandbox_setup_failure_is_environment_infrastructure(self) -> None:
        frames = [{"type": "agent_event", "event": {
            "kind": "configuration", "code": "sandbox.isolation_unsupported",
            "message": "sanitized diagnostic",
        }}]
        self.assertEqual(
            _worker_validity(frames), TrialValidity.INVALID_ENVIRONMENT_INFRASTRUCTURE
        )

    def test_normal_tool_and_policy_failures_remain_valid(self) -> None:
        fixtures = (
            {"kind": "invalid_input", "code": "process.exit_nonzero"},
            {"kind": "invalid_input", "code": "tool.file_missing"},
            {"kind": "invalid_input", "code": "tool.edit_malformed"},
            {"kind": "permission_denied", "code": "policy.denied"},
        )
        for event in fixtures:
            with self.subTest(event=event):
                self.assertEqual(
                    _worker_validity([{"type": "agent_event", "event": event}]),
                    TrialValidity.VALID,
                )

    def test_effective_validity_is_append_only_and_drives_aggregate(self) -> None:
        with tempfile.TemporaryDirectory(prefix="validity-assessment-") as temporary:
            database = EvalDatabase(Path(temporary) / "evals.db")
            database.connection.execute(
                "INSERT INTO experiment_plans VALUES(?,?,?)", ("exp", "{}", "now")
            )
            database.connection.execute(
                "INSERT INTO experiment_trials VALUES(?,?,?,?,?,?,?)",
                ("exp", 0, "task", "condition", 0, "trial", None),
            )
            raw = {"id": "trial", "validity": "Valid", "termination": "AgentFailed"}
            database.connection.execute(
                "INSERT INTO agent_trials VALUES(?,?,?,?,?,?,?,?)",
                ("trial", "{}", "Completed", "Valid", "AgentFailed", None,
                 json.dumps(raw), "now"),
            )
            database.connection.commit()
            database.save_validity_assessment({
                "id": "assessment-1", "trialId": "trial", "version": "infrastructure-v1",
                "effectiveValidity": "InvalidEnvironmentInfrastructure",
                "source": "DeterministicTypedEvidence", "evidenceRefs": ["trajectory:98"],
            })
            row = database.experiment_trials("exp")[0]
            self.assertEqual(row["trial_json"]["validity"], "Valid")
            self.assertEqual(row["effective_validity"], "InvalidEnvironmentInfrastructure")
            summary = _summary([{**row, "trial": {
                **row["trial_json"], "storedValidity": "Valid",
                "validity": row["effective_validity"],
            }, "result": {}, "metrics_json": None}])
            self.assertEqual(summary["validTrials"], 0)
            self.assertEqual(summary["invalidTrials"], 1)
            database.close()

    def test_tool_plane_failure_stops_before_database_and_trial(self) -> None:
        class ForbiddenDatabase:
            def __getattr__(self, name):
                raise AssertionError(f"database accessed before tool readiness: {name}")

        class FakeRunner:
            database = ForbiddenDatabase()

            @staticmethod
            def preflight_condition_runtime(condition):
                return RuntimeReadinessResult(
                    readiness=ConditionRuntimeReadiness.READY, closure_digest="closure",
                    process_started=True, protocol_ready=True, clean_shutdown=True,
                    residual_process=False, model_calls=0, provider_requests=0,
                )

            @staticmethod
            def preflight_condition_tool_execution(condition):
                return ToolExecutionPlaneReadinessResult(
                    readiness=ToolSandboxReadiness.INVALID, process_started=True,
                    protocol_ready=True, workspace_process_ready=False,
                    readonly_shell_ready=False, clean_shutdown=True,
                    residual_process=False, model_calls=0, provider_requests=0,
                    diagnostics=("sandbox setup failed",),
                )

        suite, tasks = load_suite(self.root / "eval_experiments/EXP-001-edit-aci-contract-alignment/suite.json")
        condition = ExperimentalCondition(
            id="fixture", version="1", fingerprint="fixture",
            manifest={"environmentClass": "fixture"}, agent={}, agent_binary="/missing",
            runtime_closure={"version": "fixture"},
        )
        with self.assertRaisesRegex(ValueError, "tool execution plane is not ready"):
            BenchmarkRunner(FakeRunner())._execute(
                suite, tasks, (condition,), 1, Path("/missing"), None, 0, "SuiteRun",
            )

    def test_frozen_a3_b3_preserve_single_capability_variable(self) -> None:
        controls = json.loads((self.experiment / "controlled-variables.json").read_text())
        self.assertEqual(controls["onlyCapabilityDifference"], "EditModelContract")
        self.assertNotEqual(
            controls["A3EditModelContractDigest"], controls["B3EditModelContractDigest"]
        )
        self.assertTrue(controls["equal"]["sharedRuntimeDependencies"])
        self.assertTrue(controls["equal"]["loaderConfiguration"])
        self.assertEqual(
            controls["equal"]["toolExecutionPlaneDigest"],
            "b6697b51616f6f4174acbefb452489e9d7b900243ebaaaf3c9588953522ed607",
        )

    def test_frozen_plan_has_six_empty_interleaved_slots(self) -> None:
        plan = json.loads((self.experiment / "experiment-plan.json").read_text())
        self.assertEqual(plan["seed"], 1003)
        self.assertEqual(plan["trialsPerCondition"], 3)
        self.assertEqual(len(plan["order"]), 6)
        self.assertTrue(all(item["trial_id"] is None for item in plan["order"]))
        self.assertEqual(
            [item["condition_fingerprint"] for item in plan["order"]],
            [
                "ec791cd525396278fbd44927f3900b30282eb208fd53472628bd4756ef6064a9",
                "664ce859d5eef9c9db82930a6546a28606c075aaa16c7ac0dc8961b57b590363",
                "664ce859d5eef9c9db82930a6546a28606c075aaa16c7ac0dc8961b57b590363",
                "ec791cd525396278fbd44927f3900b30282eb208fd53472628bd4756ef6064a9",
                "ec791cd525396278fbd44927f3900b30282eb208fd53472628bd4756ef6064a9",
                "664ce859d5eef9c9db82930a6546a28606c075aaa16c7ac0dc8961b57b590363",
            ],
        )

    def test_readiness_and_security_artifacts_are_zero_provider(self) -> None:
        readiness = json.loads((self.experiment / "tool-sandbox-readiness.json").read_text())
        security = json.loads((self.experiment / "security-verification.json").read_text())
        self.assertEqual(readiness["realTrialReadiness"], "Ready")
        self.assertEqual((readiness["modelCalls"], readiness["providerRequests"]), (0, 0))
        for probe in readiness["probes"].values():
            self.assertEqual(probe["readiness"], "Ready")
            self.assertTrue(probe["workspaceDigestUnchanged"])
            self.assertFalse(probe["residual_process"])
        self.assertEqual(security["result"], "Pass")
        self.assertTrue(security["clearenvRetained"])
        self.assertTrue(security["innerSandboxRetained"])
        self.assertFalse(security["arbitraryHostMountsAdded"])

    def test_historical_effective_validity_has_no_capability_denominator(self) -> None:
        value = json.loads((self.experiment / "historical-effective-validity.json").read_text())
        self.assertEqual(value["storedValidity"], {"Valid": 6})
        self.assertEqual(
            value["effectiveCapabilityValidity"],
            {"Valid": 0, "InvalidEnvironmentInfrastructure": 6},
        )
        self.assertEqual(value["strictCapabilityDenominator"], 0)
        self.assertFalse(value["rawRecordsMutated"])

    def test_real_product_tool_pipeline_fixture_covers_required_tools(self) -> None:
        value = json.loads((self.experiment / "tool-pipeline-contract.json").read_text())
        self.assertEqual(value["result"], "Pass")
        self.assertEqual(set(value["coveredTools"]), {"glob", "bash_readonly"})
        self.assertTrue(value["operationResultObserved"])
        self.assertEqual((value["modelCalls"], value["providerRequests"]), (0, 0))


if __name__ == "__main__":
    unittest.main()
