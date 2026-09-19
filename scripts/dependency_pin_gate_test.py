#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from dependency_pin_gate import check_root


LLM4CJ_COMMIT = "c80ab51ed1f8786ba4e5e06557dd43da92bdd94d"
LLM4CJ_TAG = "v0.1.0"
LLM4CJ_REMOTE = "https://github.com/lIlIIlIll/llm4cj.git"
YJSON_COMMIT = "c91859feb77aeba392a1fad0f99d731df66be831"
YJSON_TAG = "0.1.0"
YJSON_REMOTE = "https://github.com/lIlIIlIll/yjson.git"


def manifest(*, yjson_tag: str = YJSON_TAG) -> str:
    return f"""[package]
name = "model_adapters"

[dependencies]
  yjson = {{git = "{YJSON_REMOTE}", tag = "{yjson_tag}"}}
  llm4cj = {{git = "{LLM4CJ_REMOTE}", tag = "{LLM4CJ_TAG}"}}
"""


def lock(*, llm4cj_commit: str = LLM4CJ_COMMIT, yjson_commit: str = YJSON_COMMIT) -> str:
    return f"""version = 0

[requires]
  yjson = {{git = "{YJSON_REMOTE}", commitId = "{yjson_commit}", tag = "{YJSON_TAG}", output-type = "static"}}
  llm4cj = {{git = "{LLM4CJ_REMOTE}", commitId = "{llm4cj_commit}", tag = "{LLM4CJ_TAG}", output-type = "static"}}
"""


def write_fixture(root: Path, *, lock_text: str | None = None) -> None:
    manifest_path = root / "model_adapters" / "cjpm.toml"
    manifest_path.parent.mkdir(parents=True)
    manifest_path.write_text(manifest(), encoding="utf-8")
    for name in ("agent_product", "support_tests/product_contract"):
        path = root / name / "cjpm.lock"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(lock_text or lock(), encoding="utf-8")


class DependencyPinGateTest(unittest.TestCase):
    def test_all_manifests_and_locks_share_reviewed_tags(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root)
            self.assertEqual(check_root(root), [])

    def test_stale_llm4cj_lock_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, lock_text=lock(llm4cj_commit="old"))
            errors = check_root(root)
            self.assertEqual(len(errors), 2)
            self.assertIn("llm4cj", errors[0])

    def test_stale_yjson_lock_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, lock_text=lock(yjson_commit="old"))
            errors = check_root(root)
            self.assertEqual(len(errors), 2)
            self.assertIn("yjson", errors[0])

    def test_stale_yjson_manifest_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root)
            stale_manifest = root / "agent_product" / "cjpm.toml"
            stale_manifest.write_text(manifest(yjson_tag="main"), encoding="utf-8")
            errors = check_root(root)
            self.assertEqual(len(errors), 1)
            self.assertIn("agent_product/cjpm.toml", errors[0])
            self.assertIn("yjson", errors[0])


if __name__ == "__main__":
    unittest.main()
