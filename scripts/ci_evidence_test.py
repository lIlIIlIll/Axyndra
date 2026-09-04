#!/usr/bin/env python3

from __future__ import annotations

import json
import hashlib
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "ci_evidence.py"


class CiEvidenceTest(unittest.TestCase):
    def test_manifest_contains_commit_tree_and_artifact_digest(self) -> None:
        with tempfile.TemporaryDirectory(prefix="axyndra-ci-evidence-") as directory:
            output = Path(directory) / "evidence"
            artifact = Path(directory) / "agent_app"
            artifact.write_bytes(b"fixture-binary")
            package = Path(directory) / "package"
            package.mkdir()
            (package / "axyndra").write_bytes(b"packaged-binary")
            output.mkdir()
            (output / "package-root-path.txt").write_text(
                str(package) + "\n", encoding="utf-8"
            )
            environment = os.environ.copy()
            environment.update({
                "GITHUB_SHA": "fixture-commit",
                "GITHUB_REF": "refs/pull/1/merge",
            })
            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--gate",
                    "pr-gate",
                    "--status",
                    "success",
                    "--output-dir",
                    str(output),
                    "--artifact-path",
                    str(artifact),
                ],
                check=False,
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            manifest = json.loads((output / "gate-manifest.json").read_text(encoding="utf-8"))
            self.assertIsNotNone(manifest["repository"]["commit"])
            self.assertEqual(manifest["repository"]["github_sha"], "fixture-commit")
            self.assertIsNotNone(manifest["repository"]["tree"])
            expected = hashlib.sha256(b"fixture-binary").hexdigest()
            self.assertEqual(manifest["artifacts"][0]["sha256"], expected)
            self.assertEqual(manifest["artifacts"][1]["kind"], "directory")
            self.assertEqual(manifest["artifacts"][1]["file_count"], 1)


if __name__ == "__main__":
    unittest.main()
