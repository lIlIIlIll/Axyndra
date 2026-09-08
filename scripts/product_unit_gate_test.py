#!/usr/bin/env python3
import unittest
from product_unit_gate import summary, inventory, run_logged
from pathlib import Path
import tempfile
import subprocess
import sys

class UnitGateTest(unittest.TestCase):
    def test_inventory_detects_added_tests_and_removed_members(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / 'pkg/src').mkdir(parents=True)
            manifest = root / 'cjpm.toml'
            manifest.write_text('[workspace]\nmembers=["pkg"]\ntest-members=["pkg"]\n')
            (root / 'pkg/src/one_test.cj').write_text('test')
            before = inventory(root)
            (root / 'pkg/src/two_test.cj').write_text('test')
            self.assertNotEqual(before, inventory(root))
            manifest.write_text('[workspace]\nmembers=["pkg"]\ntest-members=[]\n')
            with self.assertRaises(ValueError): inventory(root)
            manifest.write_text('[workspace]\nmembers=[]\ntest-members=[]\n')
            with self.assertRaises(ValueError): inventory(root)

    def test_timeout_terminates_descendants(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            child = root / 'child.py'
            child.write_text("import time\nfrom pathlib import Path\ntime.sleep(0.5)\nPath('survived').touch()\n")
            parent = root / 'parent.py'
            parent.write_text("import subprocess,sys,time\nsubprocess.Popen([sys.executable, 'child.py'])\ntime.sleep(30)\n")
            self.assertEqual(run_logged([sys.executable, str(parent)], root / 'log', root, 0.2), 124)
            subprocess.run([sys.executable, '-c', 'import time; time.sleep(0.6)'], check=True)
            self.assertFalse((root / 'survived').exists())

    def test_real_summary(self):
        self.assertEqual(summary('Summary: TOTAL: 3\n    PASSED: 2, SKIPPED: 0, ERROR: 0\n    FAILED: 1')['failed'], 1)
    def test_fail_closed(self):
        for text in ['build success', 'Summary: TOTAL: 0\n    PASSED: 0, SKIPPED: 0, ERROR: 0\n    FAILED: 0', 'Summary: TOTAL: 2\n    PASSED: 1, SKIPPED: 0, ERROR: 0\n    FAILED: 0']:
            with self.assertRaises(ValueError): summary(text)

if __name__ == '__main__': unittest.main()
