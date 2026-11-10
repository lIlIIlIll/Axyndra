"""Canonical initial-prompt evidence must belong to the new Run."""
import importlib.util
from contextlib import closing, redirect_stderr, redirect_stdout
import io
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "support_tests"))
spec = importlib.util.spec_from_file_location("tui_workflow_evidence", ROOT / "support_tests/tui_workflow_operator.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
gate_spec = importlib.util.spec_from_file_location("native_tui_golden_cli", ROOT / "scripts/tui_golden_gate.py")
gate = importlib.util.module_from_spec(gate_spec)
gate_spec.loader.exec_module(gate)


class NativeInitialEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.home = Path(self.temporary.name)
        self.database = self.home / "sessions/fixture/state.db"
        self.database.parent.mkdir(parents=True)
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.executescript("""
                CREATE TABLE runs (id TEXT PRIMARY KEY,state TEXT);
                CREATE TABLE model_attempts (id TEXT PRIMARY KEY,run_id TEXT,lifecycle TEXT);
                CREATE TABLE operations (id TEXT PRIMARY KEY,run_id TEXT,state TEXT);
                CREATE TABLE operation_receipts (id TEXT PRIMARY KEY,operation_id TEXT,outcome TEXT);
                CREATE TABLE operation_effect_records (operation_id TEXT PRIMARY KEY,tool_id TEXT);
            """)

    def complete(self, identifier="new", state="completed", attempt="completed", receipt="completed"):
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("INSERT INTO runs VALUES (?,?)", (identifier, state))
            connection.execute("INSERT INTO model_attempts VALUES (?,?,?)", ("attempt-"+identifier, identifier, attempt))
            connection.execute("INSERT INTO operations VALUES (?,?,?)", ("operation-"+identifier, identifier, "committed"))
            connection.execute("INSERT INTO operation_receipts VALUES (?,?,?)", ("receipt-"+identifier, "operation-"+identifier, receipt))
            connection.execute("INSERT INTO operation_effect_records VALUES (?,?)", ("operation-"+identifier, "host.context.read"))

    def test_ui_marker_does_not_satisfy_native_cli_evidence(self):
        # The candidate is a deliberately empty fixture, not a Native-runtime
        # substitute. This regression verifies rejection by the public gate.
        candidate = self.home / "candidate.py"
        candidate.write_text("print(" + repr(gate.EXPECTED) + ")\n")
        package = self.home / "package"
        package.mkdir()
        arguments = ["tui_golden_gate.py", "--candidate", sys.executable + " " + str(candidate),
                     "--workflow-package", str(package), "--scenario", "initial-prompt",
                     "--diagnostics", str(self.home / "diagnostics")]
        with patch.dict(os.environ, {"AXYNDRA_HOME": str(self.home)}), patch.object(sys, "argv", arguments), \
                patch.dict(sys.modules, {"tui_workflow_operator": module}), \
                patch.object(module, "prepare_todo", return_value={}), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            self.assertEqual(gate.main(), 1)
        self.assertTrue((self.home / "diagnostics/initial-prompt/process.txt").exists())

    def test_ui_marker_without_new_run_cannot_pass(self):
        with self.assertRaisesRegex(ValueError, "exactly one new Run"):
            module.verify_initial_completion(self.home, set())

    def test_an_old_completed_run_cannot_substitute_for_this_prompt(self):
        self.complete("old")
        before = module.initial_run_ids(self.home)
        with self.assertRaisesRegex(ValueError, "exactly one new Run"):
            module.verify_initial_completion(self.home, before)

    def test_running_run_after_one_receipt_cannot_pass(self):
        self.complete(state="running", attempt="created")
        with self.assertRaisesRegex(ValueError, "exactly one new Run"):
            module.verify_initial_completion(self.home, set())

    def test_another_runs_model_attempt_cannot_substitute(self):
        self.complete("old")
        before = module.initial_run_ids(self.home)
        self.complete("new", attempt="failed")
        with self.assertRaisesRegex(ValueError, "completed model Attempt"):
            module.verify_initial_completion(self.home, before)

    def test_missing_or_failed_receipt_cannot_pass(self):
        self.complete(receipt="failed")
        with self.assertRaisesRegex(ValueError, "canonical ContextRead"):
            module.verify_initial_completion(self.home, set())
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("DELETE FROM operation_receipts")
        with self.assertRaisesRegex(ValueError, "canonical ContextRead"):
            module.verify_initial_completion(self.home, set())

    def test_new_completed_fixture_run_has_only_numeric_evidence(self):
        self.complete("old")
        before = module.initial_run_ids(self.home)
        self.complete()
        self.assertEqual(module.verify_initial_completion(self.home, before), dict(
            new_completed_runs=1, completed_model_attempts=1, committed_operations=1,
            completed_receipts=1, context_reads=1))
        self.assertEqual(module.initial_run_ids(self.home), {"old", "new"})

    def test_maintenance_database_is_not_fixture_execution(self):
        self.database.unlink()
        maintenance = self.home / "sessions/state.db"
        with closing(sqlite3.connect(maintenance)) as connection, connection:
            connection.execute("CREATE TABLE runs (id TEXT PRIMARY KEY,state TEXT)")
            connection.execute("INSERT INTO runs VALUES ('old','completed')")
        self.assertEqual(module.initial_run_ids(self.home), set())
        with self.assertRaisesRegex(ValueError, "no fixture execution database"):
            module.verify_initial_completion(self.home, set())
        self.assertFalse(self.database.exists())


if __name__ == "__main__":
    unittest.main()
