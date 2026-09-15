#!/usr/bin/env python3
"""Regression tests for supported and reproducible Cangjie toolchain checks."""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CHECK = ROOT / "scripts" / "check_sdk.sh"


class CheckSdkTest(unittest.TestCase):
    def make_sdk(self, root: Path, cjc_version: str, cjpm_version: str) -> Path:
        sdk = root / "sdk"
        (sdk / "bin").mkdir(parents=True)
        (sdk / "tools" / "bin").mkdir(parents=True)
        for path, label, version in [
            (sdk / "bin" / "cjc", "Cangjie Compiler", cjc_version),
            (sdk / "tools" / "bin" / "cjpm", "Cangjie Project Manager", cjpm_version),
        ]:
            path.write_text(f"#!/bin/sh\necho '{label}: {version}'\n", encoding="utf-8")
            path.chmod(0o755)
        return sdk

    def run_check(self, sdk: Path, **extra: str) -> subprocess.CompletedProcess[str]:
        environment = {
            **os.environ,
            "AXYNDRA_SDK_ROOT": str(sdk),
            "AXYNDRA_SDK_CHECK_CACHE_DIR": str(sdk.parent / "cache"),
            **extra,
        }
        return subprocess.run([str(CHECK)], text=True, capture_output=True, env=environment)

    def test_accepts_newer_sts_and_nightly_versions(self) -> None:
        for version in ["1.1.4", "1.2.0-alpha.20260915010101"]:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                sdk = self.make_sdk(Path(directory), version, version)
                result = self.run_check(sdk)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_rejects_version_below_language_baseline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sdk = self.make_sdk(Path(directory), "1.0.9", "1.1.0")
            result = self.run_check(sdk)
            self.assertEqual(result.returncode, 2)
            self.assertIn("require >= 1.1.0", result.stderr)

    def test_rejects_prerelease_of_stable_minimum(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sdk = self.make_sdk(Path(directory), "1.1.0-alpha.1", "1.1.0-alpha.1")
            result = self.run_check(sdk)
            self.assertEqual(result.returncode, 2)
            self.assertIn("require >= 1.1.0", result.stderr)

    def test_exact_release_mode_keeps_reproducible_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            sdk = self.make_sdk(Path(directory), "1.1.4", "1.1.4")
            result = self.run_check(
                sdk,
                AXYNDRA_REQUIRE_EXACT_TOOLCHAIN="1",
                AXYNDRA_CI_EXPECTED_CJC_VERSION="1.1.3",
                AXYNDRA_CI_EXPECTED_CJPM_VERSION="1.1.3",
            )
            self.assertEqual(result.returncode, 2)
            self.assertIn("release toolchain requires cjc 1.1.3", result.stderr)


if __name__ == "__main__":
    unittest.main()
