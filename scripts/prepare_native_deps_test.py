#!/usr/bin/env python3
"""Regression tests for native compiler selection and artifact freshness."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / "scripts" / "prepare_native_deps.sh"


class PrepareNativeDepsTest(unittest.TestCase):
    def make_compiler(self, path: Path, version: int, real_clang: str, log: Path) -> None:
        path.write_text(
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = --version ]; then\n"
            f"  echo 'clang version {version}.0.0'\n"
            "  exit 0\n"
            "fi\n"
            f"printf '%s\\n' \"$*\" >> '{log}'\n"
            f"exec '{real_clang}' \"$@\"\n",
            encoding="utf-8",
        )
        path.chmod(0o755)

    def test_rebuilds_when_selected_compiler_changes(self) -> None:
        real_clang = shutil.which("clang")
        if real_clang is None:
            self.skipTest("clang is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "libprocess4cj_native.so"
            log = root / "compiler.log"
            first = root / "clang-17"
            second = root / "clang-18"
            self.make_compiler(first, 17, real_clang, log)
            self.make_compiler(second, 18, real_clang, log)

            environment = {**os.environ, "AXYNDRA_NATIVE_OUTPUT": str(output)}
            for compiler in [first, first, second]:
                result = subprocess.run(
                    [str(PREPARE)],
                    env={**environment, "AXYNDRA_NATIVE_CC": str(compiler)},
                    text=True,
                    capture_output=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

            shared_builds = [line for line in log.read_text().splitlines() if "-shared" in line]
            self.assertEqual(len(shared_builds), 2)
            stamp = Path(f"{output}.compiler-id").read_text()
            self.assertIn(str(second), stamp)


if __name__ == "__main__":
    unittest.main()
