#!/usr/bin/env python3
"""Source guard for retired whole owners and their surviving helper consumers.

This resolves only identifiers formerly supplied by the retired files. It is a
regression guard for accidental helper deletion, not a Cangjie type checker or
evidence of native package execution.
"""
from pathlib import Path
from functools import lru_cache
import re
import tomllib
import unittest

ROOT = Path(__file__).resolve().parents[1]
ORACLES = (
    "support_tests/github_contract/src/legacy_github_oracle.cj",
    "support_tests/product_contract/src/legacy_lsp_tool_oracle.cj",
    "support_tests/product_contract/src/legacy_lsp_runtime_oracle.cj",
)
OLD_NAMES = {
    "LegacyGithubRuntime": "ProductGithubRuntime", "LegacyGithubTool": "GithubTool",
    "legacyGithubToolDefinition": "githubToolDefinition",
    "LegacyLspRuntime": "LspRuntime", "LegacyLspTool": "LspTool",
    "LegacyLspClient": "LspClient", "LegacyLspServerSpec": "LspServerSpec",
    "LegacyOpenLspDocument": "OpenLspDocument",
}
RETIRED_OWNERS = {"GithubTool", "ProductGithubRuntime", "registerGithubTool",
    "LspTool", "LspRuntime", "installLspTools"}
DECLARATION = re.compile(
    r"^(?P<public>public )?(?:private |internal )?(?:open )?"
    r"(?:func|class|struct|enum|interface|type|let|const)\s+(?P<name>\w+)", re.M)
IMPORT = re.compile(r"^import (\w+)\.\*\s*$", re.M)


@lru_cache(maxsize=1024)
def code_only(text):
    """Remove comments/literals while retaining offsets and physical lines."""
    output = list(text)
    at = 0
    while at < len(text):
        end = at
        if text.startswith("//", at):
            end = text.find("\n", at)
            if end < 0:
                end = len(text)
        elif text.startswith("/*", at):
            end = text.find("*/", at + 2)
            if end < 0:
                raise ValueError("unclosed block comment")
            end += 2
        elif text[at] in ('"', "'"):
            quote = text[at]
            end = at + 1
            while end < len(text):
                if text[end] == "\\":
                    end += 2
                elif text[end] == quote:
                    end += 1
                    break
                else:
                    end += 1
        if end > at:
            for index in range(at, min(end, len(text))):
                if output[index] != "\n":
                    output[index] = " "
            at = end
        else:
            at += 1
    return "".join(output)


def declarations(text, public=False):
    return {match["name"] for match in DECLARATION.finditer(code_only(text))
            if not public or match["public"]}


def inspect_sources(product, oracles, dependencies, imports):
    current = set().union(*(declarations(text) for text in product.values()))
    former = {OLD_NAMES.get(name, name) for text in oracles for name in declarations(text)}
    errors = []
    for owner in sorted(current & RETIRED_OWNERS):
        errors.append("retired production owner/factory: " + owner)
    if "lsp4cj" in dependencies:
        errors.append("Product still depends directly on the retired LSP protocol implementation")
    for name, entry in dependencies.items():
        if name in {"github_contract", "product_contract"} or "support_tests/" in entry.get("path", ""):
            errors.append("production imports a private historical oracle: " + name)
    for path, text in product.items():
        code = code_only(text)
        public_imports = set().union(*(imports.get(package, set()) for package in IMPORT.findall(code)))
        identifiers = set(re.findall(r"(?<![\w.])\b[A-Za-z_]\w*\b", code))
        for name in sorted((former - current - public_imports) & identifiers):
            errors.append(path + ": removed provider has a surviving unresolved consumer: " + name)
    return sorted(set(errors))


def actual_inputs(root):
    product = {path.relative_to(root).as_posix(): path.read_text(encoding="utf-8")
               for path in sorted((root / "agent_product/src").glob("*.cj"))}
    oracles = [(root / name).read_text(encoding="utf-8") for name in ORACLES]
    dependencies = tomllib.loads((root / "agent_product/cjpm.toml").read_text(encoding="utf-8"))["dependencies"]
    imports = {}
    for entry in dependencies.values():
        authored = entry.get("path")
        if authored is None:
            continue
        directory = (root / "agent_product" / authored).resolve()
        metadata = tomllib.loads((directory / "cjpm.toml").read_text(encoding="utf-8"))
        package = metadata["package"]["name"]
        imports[package] = set().union(*(declarations(path.read_text(encoding="utf-8"), public=True)
                                       for path in (directory / "src").glob("*.cj")))
    return product, oracles, dependencies, imports


def without_function(text, name):
    code = code_only(text)
    match = re.search(r"^func " + re.escape(name) + r"\(", code, re.M)
    if match is None:
        raise ValueError("negative control requires the actual helper " + name)
    start = match.start()
    opening = code.index("{", start)
    depth = 1
    end = opening + 1
    while depth and end < len(code):
        if code[end] == "{":
            depth += 1
        elif code[end] == "}":
            depth -= 1
        end += 1
    if depth:
        raise ValueError("unclosed function in negative control")
    return text[:start] + text[end:]


class RetiredBusinessSourceContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.product, cls.oracles, cls.dependencies, cls.imports = actual_inputs(ROOT)

    def check(self, product=None, dependencies=None):
        return inspect_sources(self.product if product is None else product, self.oracles,
                               self.dependencies if dependencies is None else dependencies, self.imports)

    def test_actual_retired_owners_and_all_former_provider_consumers(self):
        self.assertFalse((ROOT / "agent_product/src/github_tool.cj").exists())
        self.assertFalse((ROOT / "agent_product/src/lsp_tool.cj").exists())
        self.assertFalse((ROOT / "agent_product/src/lsp_runtime.cj").exists())
        self.assertEqual(self.check(), [])

    def test_missing_actual_shared_operation_encoder_is_rejected(self):
        product = dict(self.product)
        name = "agent_product/src/worktree_runtime.cj"
        product[name] = without_function(product[name], "safeOperationPart")
        errors = self.check(product)
        self.assertTrue(any("safeOperationPart" in error and name in error for error in errors), errors)

    def test_missing_actual_shared_executable_lookup_is_rejected(self):
        product = dict(self.product)
        name = "agent_product/src/worktree_runtime.cj"
        product[name] = without_function(product[name], "resolveExecutable")
        errors = self.check(product)
        self.assertTrue(any("resolveExecutable" in error and name in error for error in errors), errors)

    def test_static_business_restore_is_rejected(self):
        product = dict(self.product)
        product["agent_product/src/retired_restored.cj"] = "package agent_product\nclass LspRuntime {}\nclass GithubTool {}\n"
        errors = self.check(product)
        self.assertIn("retired production owner/factory: LspRuntime", errors)
        self.assertIn("retired production owner/factory: GithubTool", errors)

    def test_private_oracle_cannot_be_production_dependency(self):
        dependencies = dict(self.dependencies)
        dependencies["private_oracle"] = {"path": "../support_tests/product_contract"}
        self.assertIn("production imports a private historical oracle: private_oracle", self.check(dependencies=dependencies))


if __name__ == "__main__":
    unittest.main(verbosity=2)
