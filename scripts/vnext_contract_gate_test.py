#!/usr/bin/env python3
"""Product gate coverage and failure propagation across fixture processes."""
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

import vnext_contract_gate as gate


class ProductCaseExecutionTests(unittest.TestCase):
    def test_every_original_product_case_and_complete_broker_matrix_are_required(self):
        commands = []
        with patch.object(gate, "run", side_effect=lambda command, **_: commands.append(command)), \
                patch.object(gate.subprocess, "check_output", return_value="/fixture/target\n"):
            gate.run_product_contracts(Path("/fixture/wrapper"), Path("/fixture/product"), Path("/fixture"), {})
        self.assertEqual([command[-1] for command in commands[:-1]], [
            "--registry-worker-refusal-contract", "--plugin-acquisition-contract",
            "--ast-plugin-contract", "--ast-edit-plugin-contract", "--core-and-recovery-contract",
        ])
        self.assertEqual(commands[-1][1], "/fixture/scripts/readonly_bridge_lifecycle_gate.py")
        self.assertIn("/fixture/target/release/bin/main", commands[-1])

    def test_failed_case_stops_gate_before_later_cases_or_broker_matrix(self):
        commands = []
        def fail_ast(command, **_):
            commands.append(command)
            if command[-1] == "--ast-plugin-contract":
                raise subprocess.CalledProcessError(17, command)
        with patch.object(gate, "run", side_effect=fail_ast), \
                patch.object(gate.subprocess, "check_output") as target:
            with self.assertRaises(subprocess.CalledProcessError) as error:
                gate.run_product_contracts(Path("/fixture/wrapper"), Path("/fixture/product"), Path("/fixture"), {})
        self.assertEqual(error.exception.returncode, 17)
        self.assertEqual(len(commands), 3)
        target.assert_not_called()


if __name__ == "__main__":
    unittest.main()
