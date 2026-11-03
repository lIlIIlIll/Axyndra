#!/usr/bin/env python3
"""Materialize the dedicated minimal CLI without optional business source/cache.

This only prepares build inputs. A successful copy is not a successful build or
proof that an installed component works with the resulting binary.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tomllib

FORBIDDEN_NAMES = {
    "agent_product", "agent_app", "agent_mcp", "mcp_extension", "mcp4cj",
    "model_adapters", "llm4cj", "lsp4cj", "dap4cj", "agent_skills",
    "skill_runtime", "prompt_runtime", "workspace_write_extension", "workspace_search_extension",
    "gh_extension", "eval_extension", "shell_extension", "ast_extension", "web_search_extension",
    "ast_plugin", "dap_plugin", "eval_plugin", "github_plugin", "lsp_plugin",
    "mcp_client_plugin", "mcp_server_plugin", "native_model_providers", "program_language",
    "shell_plugin", "skills_plugin", "web_search_plugin", "workspace_plugin",
}
FORBIDDEN_ROOTS = ("agent_product", "agent_app", "agent_mcp", "model_adapters",
    "agent_skills", "extensions", "libs/mcp4cj", "libs/lsp4cj", "libs/dap4cj", "libs/llm4cj", "plugins")
NEUTRAL_MODEL_PACKAGE = "model_provider_runtime"
NEUTRAL_MODEL_DEPENDENCIES = {"agent_domain", "agent_ports", "yjson", "yjson_support"}
NEUTRAL_MODEL_IMPORTS = NEUTRAL_MODEL_DEPENDENCIES | {"std"}
IGNORED_DIRS = {"target", ".git", "__pycache__", ".venv", "node_modules"}
COMPILED_SUFFIXES = {".so", ".dll", ".dylib", ".o", ".a", ".bc", ".pyc", ".cjo", ".cjd"}
MAX_FILE_BYTES = 32 * 1024 * 1024
MAX_TOTAL_BYTES = 256 * 1024 * 1024
MAX_FILES = 20000


class SourceBoundaryError(ValueError):
    pass


def dependency_entries(value):
    """Include target-specific dependencies without treating binary flags as packages."""
    if not isinstance(value, dict):
        return
    for key, child in value.items():
        if key == "dependencies":
            if not isinstance(child, dict):
                raise SourceBoundaryError("dependencies must be a table")
            yield from child.items()
        elif key not in {"dev-dependencies", "test-dependencies", "bin-dependencies"}:
            yield from dependency_entries(child)


def checked(root: Path, value: Path) -> Path:
    absolute = value.absolute()
    try:
        relative = absolute.relative_to(root)
    except ValueError as exc:
        raise SourceBoundaryError("local dependency escapes repository") from exc
    cursor = root
    for part in relative.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            raise SourceBoundaryError("source paths must not contain symbolic links")
    resolved = absolute.resolve(strict=True)
    if not resolved.is_relative_to(root):
        raise SourceBoundaryError("local dependency resolves outside repository")
    return resolved


def package_closure(root: Path, entry: str = "agent_minimal") -> dict[str, dict]:
    root = root.resolve(strict=True)
    found: dict[str, dict] = {}
    names: dict[str, str] = {}

    def visit(path: Path) -> None:
        path = checked(root, path)
        relative = path.relative_to(root).as_posix()
        if relative in found:
            return
        if any(relative == denied or relative.startswith(denied + "/") for denied in FORBIDDEN_ROOTS):
            raise SourceBoundaryError("optional MCP/plugin source reachable from host: " + relative)
        manifest_path = checked(root, path / "cjpm.toml")
        manifest = tomllib.loads(manifest_path.read_text(encoding="utf-8"))
        name = manifest.get("package", {}).get("name")
        if not isinstance(name, str) or not name or name in FORBIDDEN_NAMES:
            raise SourceBoundaryError("invalid or forbidden host package: " + str(name))
        if name in names and names[name] != relative:
            raise SourceBoundaryError("ambiguous local package identity: " + name)
        if name == NEUTRAL_MODEL_PACKAGE:
            declared = list(dependency_entries(manifest))
            if relative != NEUTRAL_MODEL_PACKAGE or {key for key, _ in declared} != NEUTRAL_MODEL_DEPENDENCIES:
                raise SourceBoundaryError("forbidden neutral model dependency boundary")
        names[name] = relative
        found[relative] = {"name": name, "dependencies": []}
        for dep_name, declaration in dependency_entries(manifest):
            if dep_name in FORBIDDEN_NAMES:
                raise SourceBoundaryError("forbidden host dependency: " + dep_name)
            if not isinstance(declaration, dict):
                raise SourceBoundaryError("dependency must be explicit")
            if "path" not in declaration:
                if not (declaration.get("git") and (declaration.get("commitId") or declaration.get("tag"))):
                    raise SourceBoundaryError("external dependency requires a version tag or commit; branch-only input is not reproducible")
                continue
            value = declaration["path"]
            if not isinstance(value, str) or not value or "$" in value:
                raise SourceBoundaryError("local dependency path must be explicit")
            dependency = checked(root, path / value)
            visit(dependency)
            dep_relative = dependency.relative_to(root).as_posix()
            if found[dep_relative]["name"] != dep_name:
                raise SourceBoundaryError("dependency name differs from manifest identity")
            found[relative]["dependencies"].append(dep_relative)

    visit(root / entry)
    return dict(sorted(found.items()))


def materialize(root: Path, output: Path, entry: str = "agent_minimal") -> dict:
    root = root.resolve(strict=True)
    output = output.absolute()
    if output.exists() or output.is_symlink():
        raise SourceBoundaryError("output must be a new empty path; existing targets are never reused")
    if output.is_relative_to(root):
        raise SourceBoundaryError("output must be outside the source repository")
    packages = package_closure(root, entry)
    selected: dict[str, Path] = {}
    for package in packages:
        package_path = root / package
        for source in sorted(package_path.rglob("*")):
            relative_parts = source.relative_to(package_path).parts
            if any(part in IGNORED_DIRS for part in relative_parts):
                continue
            if source.is_symlink():
                raise SourceBoundaryError("package contains a symbolic link")
            if source.is_dir() or source.suffix.lower() in COMPILED_SUFFIXES:
                continue
            if source.name.endswith(".compiler-id"):
                continue
            if source.is_file():
                with source.open("rb") as probe:
                    magic = probe.read(8)
                if magic.startswith((b"\x7fELF", b"MZ", b"!<arch>")):
                    continue
            if source.name == "cjpm.lock":
                # The isolated compiler resolves the unchanged pinned manifests.
                # Reusing a workspace lock could pull optional historical nodes.
                continue
            checked(root, source)
            if not source.is_file() or source.stat().st_size > MAX_FILE_BYTES:
                raise SourceBoundaryError("source file type/size exceeds bounded input")
            if source.suffix == ".cj":
                # Manifest closure is necessary but insufficient if source code
                # imports an undeclared optional package through ambient caches.
                text = source.read_text(encoding="utf-8")
                import re
                for imported in re.findall(r"(?m)^\s*(?:public\s+|internal\s+|protected\s+)?import\s+([A-Za-z_][A-Za-z0-9_]*)", text):
                    if package == NEUTRAL_MODEL_PACKAGE and imported not in NEUTRAL_MODEL_IMPORTS:
                        raise SourceBoundaryError("forbidden neutral model source import: " + imported)
                    if imported in FORBIDDEN_NAMES:
                        raise SourceBoundaryError("forbidden source import: " + imported)
            selected[source.relative_to(root).as_posix()] = source
    # Build drivers are part of the same bounded source input, before creation.
    for relative in ["scripts/pinned_cangjie", "scripts/check_sdk.sh", "scripts/sdk_paths.sh",
                     "scripts/prepare_native_deps.sh", "scripts/check_native_compiler.sh"]:
        source = root / relative
        if not source.exists():
            continue  # Tiny unit fixtures omit drivers; the build gate requires them.
        checked(root, source)
        if not source.is_file() or source.stat().st_size > MAX_FILE_BYTES:
            raise SourceBoundaryError("invalid build driver")
        selected[relative] = source
    if len(selected) > MAX_FILES or sum(p.stat().st_size for p in selected.values()) > MAX_TOTAL_BYTES:
        raise SourceBoundaryError("host source input exceeds bounded total")
    # All boundary checks precede creation. Subsequent I/O failures leave a
    # visibly incomplete tree with no successful inventory, never a stale cache.
    output.mkdir(parents=True, exist_ok=False)
    hashes = []
    copied_total = 0
    for relative, source in sorted(selected.items()):
        destination = output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        digest = hashlib.sha256()
        copied = 0
        with source.open("rb") as src, destination.open("xb") as dst:
            while chunk := src.read(1024 * 1024):
                copied += len(chunk)
                copied_total += len(chunk)
                if copied > MAX_FILE_BYTES or copied_total > MAX_TOTAL_BYTES:
                    raise SourceBoundaryError("source changed beyond size limit during copy")
                digest.update(chunk)
                dst.write(chunk)
        shutil.copymode(source, destination)
        hashes.append({"path": relative, "bytes": copied, "sha256": digest.hexdigest()})
    test_members = [p for p in packages if list((root / p / "src").rglob("*_test.cj"))]
    members = ", ".join(json.dumps(p) for p in packages)
    # The SDK requires every test member to be a build member. This is
    # exactly the already validated closure, with no optional packages added.
    workspace = "[workspace]\nmembers = [" + members + "]\nbuild-members = [" + members + "]\n"
    workspace += "test-members = [" + ", ".join(json.dumps(p) for p in test_members) + "]\n"
    (output / "cjpm.toml").write_text(workspace, encoding="utf-8", newline="\n")
    for forbidden in FORBIDDEN_ROOTS:
        if (output / forbidden).exists():
            raise SourceBoundaryError("forbidden source unexpectedly copied")
    report = {"version": 1, "status": "SOURCE_INPUT_ONLY_NOT_BUILT", "entry": entry,
              "packages": packages, "files": hashes, "workspace_sha256": hashlib.sha256(workspace.encode()).hexdigest(),
              "excluded_source_roots": list(FORBIDDEN_ROOTS), "compiled_artifacts_copied": False}
    (output / "minimal-source.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    return report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = materialize(args.root, args.output)
    print(json.dumps({"status": report["status"], "packages": len(report["packages"]), "files": len(report["files"])}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
