#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path

from dependency_pin_gate import check_root


LLM4CJ_COMMIT = "fd83641c4f39fc5c299298187028e581e7a8616c"
LLM4CJ_TAG = "v0.2.0"
LLM4CJ_REMOTE = "https://github.com/lIlIIlIll/llm4cj.git"
YJSON_TAG_OBJECT = "c91859feb77aeba392a1fad0f99d731df66be831"
YJSON_COMMIT = "54b4965dee0f0b96710cbc678ec5ec9a126b055c"
YJSON_TAG = "0.1.0"
YJSON_REMOTE = "https://github.com/lIlIIlIll/yjson.git"


def manifest(*, yjson_tag: str = YJSON_TAG) -> str:
    return f"""[package]
name = "model_adapters"

[dependencies]
  yjson = {{git = "{YJSON_REMOTE}", tag = "{yjson_tag}"}}
  llm4cj = {{git = "{LLM4CJ_REMOTE}", tag = "{LLM4CJ_TAG}"}}
"""


def lock(*, llm4cj_commit: str = LLM4CJ_COMMIT, yjson_commit: str = YJSON_TAG_OBJECT) -> str:
    return f"""version = 0

[requires]
  yjson = {{git = "{YJSON_REMOTE}", commitId = "{yjson_commit}", tag = "{YJSON_TAG}", output-type = "static"}}
  llm4cj = {{git = "{LLM4CJ_REMOTE}", commitId = "{llm4cj_commit}", tag = "{LLM4CJ_TAG}", output-type = "static"}}
"""



def lock_v1(*, yjson_source: str | None = None) -> str:
    source = yjson_source or f"git+{YJSON_REMOTE}?tag={YJSON_TAG}#{YJSON_COMMIT}"
    return f"""version = 1

[requires.yjson]
source = "{source}"
[requires.llm4cj]
source = "git+{LLM4CJ_REMOTE}?tag={LLM4CJ_TAG}#{LLM4CJ_COMMIT}"
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

    def test_format_zero_accepts_the_same_reviewed_peeled_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, lock_text=lock(yjson_commit=YJSON_COMMIT))
            self.assertEqual(check_root(root), [])
            (root / "agent_product/cjpm.lock").write_text(lock(), encoding="utf-8")
            self.assertEqual(check_root(root), [])

    def test_query_changes_cannot_reuse_the_reviewed_commit(self) -> None:
        contents = (
            lock(yjson_commit=YJSON_COMMIT).replace(
                f'git = "{YJSON_REMOTE}"', f'git = "{YJSON_REMOTE}?branch=main"'),
            lock_v1(yjson_source=f"git+{YJSON_REMOTE}?branch=main#{YJSON_COMMIT}"),
            lock_v1(yjson_source=f"git+{YJSON_REMOTE}?tag={YJSON_TAG}&rev=main#{YJSON_COMMIT}"),
        )
        for content in contents:
            with self.subTest(content=content), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_fixture(root, lock_text=content)
                errors = check_root(root)
                self.assertEqual(len(errors), 2)
                self.assertTrue(all("yjson" in error for error in errors))

    def test_format_one_and_mixed_formats_keep_the_same_reviewed_pins(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, lock_text=lock_v1())
            self.assertEqual(check_root(root), [])
            (root / "agent_product/cjpm.lock").write_text(lock(), encoding="utf-8")
            self.assertEqual(check_root(root), [])

    def test_format_one_rejects_changed_source_even_with_matching_legacy_fields(self) -> None:
        for source in (
            f"git+{YJSON_REMOTE}?tag={YJSON_TAG}#old",
            f"git+{YJSON_REMOTE}?tag=main#{YJSON_COMMIT}",
            f"git+https://example.test/yjson.git?tag={YJSON_TAG}#{YJSON_COMMIT}",
            f"git+{YJSON_REMOTE}?tag={YJSON_TAG}&branch=main#{YJSON_COMMIT}",
        ):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                content = lock_v1(yjson_source=source).replace(
                    "[requires.yjson]", f'[requires.yjson]\ngit = "{YJSON_REMOTE}"\ntag = "{YJSON_TAG}"\ncommitId = "{YJSON_COMMIT}"')
                write_fixture(root, lock_text=content)
                errors = check_root(root)
                self.assertEqual(len(errors), 2)
                self.assertTrue(all("yjson source=" in error for error in errors))

    def test_format_one_requires_the_reviewed_tags_peeled_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_fixture(root, lock_text=lock_v1(yjson_source=
                f"git+{YJSON_REMOTE}?tag={YJSON_TAG}#{YJSON_TAG_OBJECT}"))
            errors = check_root(root)
            self.assertEqual(len(errors), 2)
            self.assertTrue(all("yjson source=" in error for error in errors))

    def test_unknown_or_non_integer_lock_versions_fail_closed(self) -> None:
        for version in ("2", "true", '\"1\"'):
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_fixture(root, lock_text=lock_v1().replace("version = 1", f"version = {version}"))
                self.assertTrue(any("unsupported lock version" in error for error in check_root(root)))

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
