#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from dependency_pin_gate import check_root


PIN = "7d4f225a24db8eba697855f54039702ad0bbc81d"
REMOTE = "https://github.com/lIlIIlIll/llm4cj.git"


def lock(commit: str) -> str:
    return (
        "version = 0\n\n[requires]\n"
        f'  llm4cj = {{git = "{REMOTE}", commitId = "{commit}", '
        'branch = "main", output-type = "static"}\n'
    )


class DependencyPinGateTest(unittest.TestCase):
    def test_all_locks_share_the_manifest_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "model_adapters" / "cjpm.toml"
            manifest.parent.mkdir()
            manifest.write_text(
                "[package]\nname = \"model_adapters\"\n\n[dependencies]\n"
                f'  llm4cj = {{git = "{REMOTE}", commitId = "{PIN}", branch = "main"}}\n',
                encoding="utf-8",
            )
            for name in ("agent_product", "support_tests/product_contract"):
                path = root / name / "cjpm.lock"
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(lock(PIN), encoding="utf-8")
            self.assertEqual(check_root(root), [])

    def test_stale_lock_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            manifest = root / "model_adapters" / "cjpm.toml"
            manifest.parent.mkdir()
            manifest.write_text(
                "[dependencies]\n"
                f'  llm4cj = {{git = "{REMOTE}", commitId = "{PIN}", branch = "main"}}\n',
                encoding="utf-8",
            )
            lock_path = root / "agent_product" / "cjpm.lock"
            lock_path.parent.mkdir()
            lock_path.write_text(lock("old"), encoding="utf-8")
            errors = check_root(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("differs from reviewed", errors[0])


if __name__ == "__main__":
    unittest.main()
