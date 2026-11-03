"""Real ELF relocation fixtures, not Product or independent plugin acceptance."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NativeCandidateTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='native-candidate-')
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.native = self.work / 'native'
        self.native.mkdir()
        # A real, independently linked DSO/consumer proves loader selection even
        # when a different process-native DSO exists in the checkout.
        library = self.work / 'native.c'
        library.write_text('int fixture_native_identity(void) { return 49; }\n')
        consumer = self.work / 'consumer.c'
        consumer.write_text('extern int fixture_native_identity(void);\nint main(void) { return fixture_native_identity() == 49 ? 0 : 1; }\n')
        compiler = shutil.which(os.environ.get('CC', 'cc'))
        self.assertIsNotNone(compiler, 'a C compiler is required for real ELF relocation fixtures')
        subprocess.run([compiler, '-shared', '-fPIC', str(library), '-Wl,-soname,libprocess4cj_native.so',
            '-o', str(self.native / 'libprocess4cj_native.so')], check=True, capture_output=True)
        self.binary = self.work / 'consumer'
        subprocess.run([compiler, str(consumer), '-L' + str(self.native), '-lprocess4cj_native',
            '-o', str(self.binary)], check=True, capture_output=True)
        self.environment = dict(os.environ, AXYNDRA_DISTRIBUTION='minimal',
            AXYNDRA_SOURCE_BINARY=str(self.binary), AXYNDRA_SOURCE_NATIVE_ROOT=str(self.native),
            AXYNDRA_PACKAGE_ROOT=str(self.work / 'package'))

    def package(self):
        return subprocess.run(['bash', str(ROOT / 'scripts/package_candidate.sh')], cwd=ROOT,
            env=self.environment, text=True, capture_output=True, timeout=60, check=False)

    def test_explicit_native_dso_is_relocated_and_selected_without_live_library_or_sdk_environment(self):
        completed = self.package()
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        package = self.work / 'package'
        provenance = json.loads((package / 'package-provenance.json').read_bytes())
        native = provenance['native_input']
        expected = hashlib.sha256((self.native / 'libprocess4cj_native.so').read_bytes()).hexdigest()
        self.assertEqual(native['before_sha256'], expected)
        self.assertEqual(native['copied_sha256'], expected)
        self.assertEqual(native['after_sha256'], expected)
        self.assertEqual(native['source_binary_sha256'], provenance['source_binary_sha256'])
        self.assertEqual(native['packaged_sha256'], hashlib.sha256((package / 'lib/libprocess4cj_native.so').read_bytes()).hexdigest())
        relocated = self.work / 'relocated'
        shutil.copytree(package, relocated)
        shutil.rmtree(package)
        shutil.rmtree(self.native)
        self.binary.unlink()
        run = subprocess.run([str(relocated / 'bin/axyndra')], cwd=relocated,
            env={'PATH': '', 'LANG': 'C.UTF-8'}, capture_output=True, timeout=10, check=False)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)

    def test_dynamic_explicit_host_without_matched_native_root_fails_closed(self):
        self.environment.pop('AXYNDRA_SOURCE_NATIVE_ROOT')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('requires its matched AXYNDRA_SOURCE_NATIVE_ROOT', result.stderr)
        self.assertFalse((self.work / 'package/package-provenance.json').exists())

    def test_missing_native_input_never_uses_checkout_library(self):
        (self.native / 'libprocess4cj_native.so').unlink()
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'package/package-provenance.json').exists())

    def test_symlink_native_input_is_not_a_frozen_regular_file(self):
        library = self.native / 'libprocess4cj_native.so'
        target = self.native / 'other.so'
        library.rename(target)
        library.symlink_to(target.name)
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'package/package-provenance.json').exists())

    def test_native_mutation_during_actual_copy_prevents_provenance_publication(self):
        commands = self.work / 'commands'; commands.mkdir()
        copy = commands / 'cp'
        copy.write_text('#!/usr/bin/env bash\nset -e\n"$REAL_CP" "$@"\n'
            'for source in "$@"; do\n  if [[ "$source" == "$FROZEN_NATIVE" ]]; then\n'
            '    printf changed >> "$source"\n  fi\ndone\n')
        copy.chmod(0o755)
        self.environment.update(REAL_CP=shutil.which('cp'),
            FROZEN_NATIVE=str(self.native / 'libprocess4cj_native.so'),
            PATH=str(commands) + os.pathsep + self.environment['PATH'])
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('native input changed during package copy', result.stderr)
        self.assertFalse((self.work / 'package/package-provenance.json').exists())

    def test_unreadable_host_elf_cannot_bypass_native_pair_validation(self):
        self.binary.write_bytes(b'#!/bin/sh\nexit 0\n')
        result = self.package()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.work / 'package/package-provenance.json').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
