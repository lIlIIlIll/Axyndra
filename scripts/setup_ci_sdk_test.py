"""Exercise the real SDK installer without a network or executable SDK."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
VERSION = '1.3.0-alpha.20261104001050'

class SdkArchiveTests(unittest.TestCase):
    def invoke(self, base, archive, digest):
        commands = base / 'commands'
        commands.mkdir()
        curl = commands / 'curl'
        curl.write_text('#!/bin/bash\nwhile (($#)); do if [[ "$1" == -o ]]; then cp "$TEST_ARCHIVE" "$2"; exit; fi; shift; done; exit 2\n')
        curl.chmod(0o755)
        return subprocess.run(['bash', str(ROOT / 'scripts/setup_ci_sdk.sh'), VERSION,
            str(base / 'download'), digest], env=dict(os.environ, PATH=str(commands)+':'+os.environ['PATH'],
            TEST_ARCHIVE=str(archive), GITHUB_ENV=str(base / 'fixture-env'),
            GITHUB_PATH=str(base / 'fixture-path')), capture_output=True, text=True)

    def archive(self, base, escape=False):
        path = base / 'input.tar.gz'
        with tarfile.open(path, 'w:gz') as output:
            for name in ['cangjie/bin/cjc', 'cangjie/tools/bin/cjpm'] + (['../../escaped'] if escape else []):
                body = b'#!/bin/sh\nexit 99\n'
                member = tarfile.TarInfo(name); member.size=len(body); member.mode=0o755
                output.addfile(member, io.BytesIO(body))
        return path

    def test_verified_archive_extracts_without_running_downloaded_programs(self):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp); archive=self.archive(base)
            result=self.invoke(base, archive, hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((Path(result.stdout.strip()) / 'bin/cjc').exists())

    def test_installer_fixture_exports_stay_out_of_parent_github_files(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            parent_env = base / 'parent-env'
            parent_path = base / 'parent-path'
            parent_env.write_text('real-sdk-environment\n')
            parent_path.write_text('real-sdk-path\n')
            archive = self.archive(base)
            digest = hashlib.sha256(archive.read_bytes()).hexdigest()
            with mock.patch.dict(os.environ, GITHUB_ENV=str(parent_env), GITHUB_PATH=str(parent_path)):
                result = self.invoke(base, archive, digest)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(parent_env.read_text(), 'real-sdk-environment\n')
            self.assertEqual(parent_path.read_text(), 'real-sdk-path\n')
            installed = Path(result.stdout.strip())
            self.assertEqual((base / 'fixture-env').read_text(),
                f'AXYNDRA_CI_SDK_ACTUAL_SHA256={digest}\nAXYNDRA_SDK_ROOT={installed}\n')
            self.assertEqual((base / 'fixture-path').read_text(),
                f'{installed}/bin\n{installed}/tools/bin\n')

    def test_digest_mismatch_prevents_extraction(self):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp); archive=self.archive(base)
            result=self.invoke(base, archive, '0'*64)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base/'download'/('cangjie-sdk-'+VERSION)).exists())

    def test_verified_archive_cannot_escape_destination(self):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp); archive=self.archive(base, escape=True)
            result=self.invoke(base, archive, hashlib.sha256(archive.read_bytes()).hexdigest())
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((base/'escaped').exists())

if __name__ == '__main__':
    unittest.main()
