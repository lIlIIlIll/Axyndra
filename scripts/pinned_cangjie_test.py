#!/usr/bin/env python3
"""Regression tests for toolchain-isolated canonical Cangjie targets."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts" / "pinned_cangjie"


class PinnedCangjieTest(unittest.TestCase):
    def make_sdk(self, root: Path, version: str, invocation_log: Path) -> Path:
        sdk = root / version
        (sdk / "bin").mkdir(parents=True)
        (sdk / "tools" / "bin").mkdir(parents=True)
        stdx = sdk / "linux_x86_64_cjnative" / "dynamic" / "stdx"
        stdx.mkdir(parents=True)
        (stdx / "libstdx.net.http.so").touch()
        cjc = sdk / "bin" / "cjc"
        cjc.write_text(f"#!/bin/sh\necho 'Cangjie Compiler: {version}'\n", encoding="utf-8")
        cjpm = sdk / "tools" / "bin" / "cjpm"
        cjpm.write_text(
            "#!/bin/sh\n"
            "if [ \"${1:-}\" = --version ]; then\n"
            f"  echo 'Cangjie Project Manager: {version}'\n"
            "else\n"
            f"  printf '%s\\n' \"$*\" >> '{invocation_log}'\n"
            "fi\n",
            encoding="utf-8",
        )
        cjc.chmod(0o755)
        cjpm.chmod(0o755)
        return sdk

    def run_wrapper(self, sdk: Path, root: Path, log: Path) -> str:
        real_clang = shutil.which("clang")
        if real_clang is None:
            self.skipTest("clang is unavailable")
        environment = {
            **os.environ,
            "AXYNDRA_SDK_ROOT": str(sdk),
            "AXYNDRA_SDK_CHECK_CACHE_DIR": str(root / "sdk-cache"),
            "AXYNDRA_NATIVE_CC": real_clang,
            "AXYNDRA_NATIVE_OUTPUT": str(root / "libprocess4cj_native.so"),
            "AXYNDRA_CANONICAL_TARGET_ROOT": str(root / "targets"),
        }
        result = subprocess.run(
            [str(WRAPPER), "cjpm", "build"],
            cwd=ROOT,
            env=environment,
            text=True,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return log.read_text(encoding="utf-8").splitlines()[-1]

    def test_canonical_target_changes_with_sdk_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "invocations.log"
            first_sdk = self.make_sdk(root, "1.1.3", log)
            second_sdk = self.make_sdk(root, "1.2.0", log)

            first = self.run_wrapper(first_sdk, root, log)
            repeated = self.run_wrapper(first_sdk, root, log)
            second = self.run_wrapper(second_sdk, root, log)

            self.assertEqual(first, repeated)
            self.assertNotEqual(first, second)
            self.assertIn("--target-dir", first)
            self.assertIn("--target-dir", second)


if __name__ == "__main__":
    unittest.main()
