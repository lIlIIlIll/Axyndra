#!/usr/bin/env python3

from __future__ import annotations

import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
GATE = ROOT / "scripts" / "tracked_artifact_gate.py"


class TrackedArtifactGateTest(unittest.TestCase):
    def run_gate(self, paths: list[str]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / "paths.txt"
            fixture.write_text("\n".join(paths) + "\n", encoding="utf-8")
            return subprocess.run(
                ["python3", str(GATE), "--paths-file", str(fixture)],
                check=False,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

    def test_source_and_documentation_are_allowed(self) -> None:
        result = self.run_gate(["agent_core/src/core.cj", "docs/architecture.md"])
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_runtime_and_generated_artifacts_are_rejected(self) -> None:
        for path in (
            ".agent-state/fixture/state.db",
            ".agent-state/fixture/state.db-wal",
            "dist/axyndra/bin/axyndra",
            "mock.log",
            "worker.pid",
        ):
            with self.subTest(path=path):
                result = self.run_gate([path])
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(path, result.stdout)


if __name__ == "__main__":
    unittest.main()
