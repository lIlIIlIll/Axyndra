#!/usr/bin/env python3

import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class DocumentationAuthoritiesTest(unittest.TestCase):
    def test_primary_architecture_documents_exist(self) -> None:
        for path in (
            "docs/architecture.md",
            "docs/runtime-capabilities.md",
            "docs/cj-tui-dependency.md",
        ):
            self.assertTrue((ROOT / path).is_file(), path)

    def test_vendored_cjtui_provenance_exists(self) -> None:
        self.assertTrue((ROOT / "vendor/cj_tui/PROVENANCE.json").is_file())


if __name__ == "__main__":
    unittest.main()
