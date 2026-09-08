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
    def test_workflow_environment_and_actual_stdx_selection(self):
        import zipfile
        import yaml
        for workflow in ("pr-gate.yml", "release-gate.yml"):
            with self.subTest(workflow=workflow), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                sdk = root / "sdk"
                selected = sdk / "linux_x86_64_cjnative/dynamic/stdx"
                selected.mkdir(parents=True)
                (selected / "libstdx.net.http.so").write_bytes(b"sdk selected library")
                archive = root / "fixture.zip"
                with zipfile.ZipFile(archive, "w") as output:
                    output.writestr("linux_x86_64_cjnative/dynamic/stdx/libstdx.net.http.so", b"downloaded library")
                fakebin = root / "bin"
                fakebin.mkdir()
                curl = fakebin / "curl"
                curl.write_text('#!/bin/bash\nwhile [[ "$1" != "-o" ]]; do shift; done\ncp "$FIXTURE_ARCHIVE" "$2"\n')
                curl.chmod(0o755)
                for tool, relative in [('cjc', 'bin/cjc'), ('cjpm', 'tools/bin/cjpm')]:
                    precise = sdk / relative
                    precise.parent.mkdir(parents=True, exist_ok=True)
                    precise.write_text('#!/bin/sh\necho selected-' + tool + '\n')
                    precise.chmod(0o755)
                    ambient = fakebin / tool
                    ambient.write_text('#!/bin/sh\necho ambient-' + tool + '\n')
                    ambient.chmod(0o755)
                envfile, outputs = root / "env", root / "outputs"
                environment = dict(os.environ, GITHUB_ENV=str(envfile), GITHUB_OUTPUT=str(outputs),
                    FIXTURE_ARCHIVE=str(archive), PATH=str(fakebin)+os.pathsep+os.environ['PATH'])
                data = yaml.safe_load((ROOT / ".github/workflows" / workflow).read_text())
                steps = next(iter(data['jobs'].values()))['steps']
                load = next(step['run'] for step in steps if step.get('id') == 'cangjie-toolchain')
                subprocess.run(['bash', '-e', '-c', load], cwd=ROOT, env=environment, check=True)
                for line in envfile.read_text().splitlines():
                    key, value = line.split('=', 1)
                    environment[key] = value
                self.assertTrue(environment['AXYNDRA_CI_CANGJIE_VERSION'])
                self.assertTrue(environment['AXYNDRA_CI_STDX_SHA256'])
                expected = hashlib.sha256(archive.read_bytes()).hexdigest()
                environment['AXYNDRA_CI_STDX_SHA256'] = expected
                download = subprocess.run(['bash', str(ROOT / 'scripts/setup_ci_nightly_stdx.sh'),
                    environment['AXYNDRA_CI_CANGJIE_VERSION'], str(root / 'download'), expected],
                    env=environment, check=True, capture_output=True, text=True)
                for line in envfile.read_text().splitlines():
                    key, value = line.split('=', 1)
                    environment[key] = value
                environment.update(AXYNDRA_CI_STDX_SHA256=expected, AXYNDRA_SDK_ROOT=str(sdk),
                    CANGJIE_STDX_PATH=download.stdout.strip())
                output = root / 'evidence'
                subprocess.run(['python3', str(SCRIPT), '--gate', 'fixture', '--output-dir', str(output)],
                    env=environment, check=True, capture_output=True)
                toolchain = json.loads((output / 'gate-manifest.json').read_text())['toolchain']
                self.assertEqual(toolchain['cangjie_version'], environment['AXYNDRA_CI_CANGJIE_VERSION'])
                self.assertEqual(toolchain['cjc'], 'selected-cjc')
                self.assertEqual(toolchain['cjpm'], 'selected-cjpm')
                self.assertEqual(toolchain['stdx']['actual_archive_sha256'], expected)
                self.assertEqual(toolchain['stdx']['expected_archive_sha256'], expected)
                self.assertEqual(toolchain['stdx']['selected']['path'], str(selected))
                self.assertEqual(toolchain['stdx']['selected']['file_count'], 1)
                self.assertNotEqual(toolchain['stdx']['selected']['tree_sha256'], expected)
                (sdk / 'bin/cjc').unlink()
                subprocess.run(['python3', str(SCRIPT), '--gate', 'fixture', '--output-dir', str(output)],
                    env=environment, check=True, capture_output=True)
                missing = json.loads((output / 'gate-manifest.json').read_text())['toolchain']
                self.assertIsNone(missing['cjc'])
                failed = subprocess.run(['bash', str(ROOT / 'scripts/setup_ci_nightly_stdx.sh'),
                    environment['AXYNDRA_CI_CANGJIE_VERSION'], str(root / 'bad-download'), '0'*64],
                    env=environment, capture_output=True)
                self.assertNotEqual(failed.returncode, 0)

    def test_early_failure_writes_unknown_toolchain(self):
        with tempfile.TemporaryDirectory() as temporary:
            environment = {key: value for key, value in os.environ.items()
                if not key.startswith(('AXYNDRA_', 'CANGJIE_'))}
            subprocess.run(['python3', str(SCRIPT), '--gate', 'fixture', '--status', 'failure',
                '--output-dir', temporary], env=environment, check=True, capture_output=True)
            manifest = json.loads((Path(temporary) / 'gate-manifest.json').read_text())
            self.assertEqual(manifest['toolchain']['stdx']['status'], 'unknown')
            self.assertIsNone(manifest['toolchain']['stdx']['selected'])
            self.assertEqual(manifest['status'], 'failure')

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
