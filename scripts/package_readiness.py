#!/usr/bin/env python3
"""Audit and stage the explicit axyndra public package set.

The source workspace keeps path dependencies for development. Staged publish
manifests replace those paths with exact package versions. This tool never
publishes and never mutates a source manifest.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import tomllib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
YJSON_COMMIT = "92858f75aedc3dd6f7322789117854514549e62c"
INVENTORY_PATH = ROOT / "packaging" / "public-packages.toml"
IMPORT = re.compile(r"^\s*import\s+([A-Za-z_][A-Za-z0-9_]*)", re.MULTILINE)
PATH_DEPENDENCY = re.compile(
    r'^(?P<indent>\s*)(?P<key>"?[A-Za-z_][A-Za-z0-9_]*"?)\s*=\s*\{(?P<body>[^\n{}]*?)\bpath\s*=\s*"[^"]+"(?P<tail>[^\n{}]*?)\}\s*$',
    re.MULTILINE,
)


def load_toml(path: Path) -> dict[str, object]:
    return tomllib.loads(path.read_text(encoding="utf-8"))


def workspace_members() -> list[str]:
    workspace = load_toml(ROOT / "cjpm.toml").get("workspace", {})
    assert isinstance(workspace, dict)
    members = workspace.get("members", [])
    assert isinstance(members, list)
    return [str(member) for member in members]


def inventory() -> tuple[list[str], list[str], list[str], dict[str, object]]:
    value = load_toml(INVENTORY_PATH)
    public = value["public"]
    hold = value["hold"]
    internal = value["internal"]
    assert isinstance(public, dict) and isinstance(hold, dict) and isinstance(internal, dict)
    publishable = [str(path) for path in public["generic"]] + [str(path) for path in public["ecosystem"]]
    held = [str(path) for path in hold["experimental"]]
    private = [str(path) for path in internal["packages"]]
    return publishable, held, private, value


def dependency_tables(value: object, parent: str = "") -> list[dict[str, object]]:
    if not isinstance(value, dict):
        return []
    result: list[dict[str, object]] = []
    for key, child in value.items():
        qualified = f"{parent}.{key}" if parent else str(key)
        if str(key) in {"dependencies", "test-dependencies"} and isinstance(child, dict):
            result.append(child)
        elif str(key) != "bin-dependencies":
            result.extend(dependency_tables(child, qualified))
    return result


def declared_dependencies(manifest: dict[str, object]) -> set[str]:
    result: set[str] = set()
    for table in dependency_tables(manifest):
        for raw_name in table:
            result.add(str(raw_name).split("::")[-1])
    return result


def package_records() -> dict[str, dict[str, object]]:
    records: dict[str, dict[str, object]] = {}
    for member in workspace_members():
        manifest_path = ROOT / member / "cjpm.toml"
        manifest = load_toml(manifest_path)
        package = manifest.get("package", {})
        assert isinstance(package, dict)
        name = str(package.get("name", ""))
        if not name or name in records:
            raise ValueError(f"invalid or duplicate workspace package name: {name!r}")
        records[name] = {
            "member": member,
            "manifest": manifest,
            "version": str(package.get("version", "")),
            "description": str(package.get("description", "")),
        }
    return records


def legal_metadata(root: Path = ROOT) -> tuple[list[Path], list[Path], list[str]]:
    """Return publishable legal files and fail-closed publication blockers.

    A NOTICE is supplemental metadata, not a substitute for the project
    license.  It is optional until the project or bundled attribution policy
    supplies one; any legal metadata that is supplied must be a non-empty
    regular file.
    """
    blockers: list[str] = []

    def collect(pattern: str, label: str) -> list[Path]:
        candidates = sorted(path for path in root.glob(pattern) if path.is_file())
        empty = [path.name for path in candidates if path.stat().st_size == 0]
        if empty:
            blockers.append(
                f"publication blocker: empty {label} metadata: {', '.join(empty)}"
            )
        return [path for path in candidates if path.stat().st_size > 0]

    licenses = collect("LICENSE*", "LICENSE")
    notices = collect("NOTICE*", "NOTICE")
    if not licenses:
        blockers.append(
            "publication blocker: repository has no non-empty LICENSE file; "
            "no license was inferred"
        )
    return licenses, notices, blockers


def audit() -> tuple[list[str], list[str]]:
    errors: list[str] = []
    warnings: list[str] = []
    publishable, held, private, _ = inventory()
    members = workspace_members()
    classified = publishable + held + private
    if len(classified) != len(set(classified)):
        errors.append("package inventory contains duplicate classifications")
    missing = sorted(set(members) - set(classified))
    extra = sorted(set(classified) - set(members))
    if missing:
        errors.append("unclassified workspace packages: " + ", ".join(missing))
    if extra:
        errors.append("inventory entries not in workspace: " + ", ".join(extra))

    records = package_records()
    public_names = {str(load_toml(ROOT / member / "cjpm.toml")["package"]["name"]): member for member in publishable}
    workspace_names = set(records)
    for name, member in sorted(public_names.items()):
        record = records[name]
        manifest = record["manifest"]
        assert isinstance(manifest, dict)
        declared = declared_dependencies(manifest)
        imported: set[str] = set()
        for source in sorted((ROOT / member / "src").glob("**/*.cj")):
            imported.update(IMPORT.findall(source.read_text(encoding="utf-8")))
        required = (imported & workspace_names) - {name}
        undeclared = sorted(required - declared)
        if undeclared:
            errors.append(f"{name}: direct imports missing dependency declarations: {', '.join(undeclared)}")
        internal = sorted(declared & (workspace_names - set(public_names)))
        if internal:
            errors.append(f"{name}: public package depends on internal/held packages: {', '.join(internal)}")
        if not record["version"]:
            errors.append(f"{name}: package version is empty")
        if not record["description"]:
            errors.append(f"{name}: package description is empty")

    _, _, legal_blockers = legal_metadata()
    warnings.extend(legal_blockers)
    return errors, warnings


def transform_manifest(text: str, versions: dict[str, str]) -> str:
    converted: set[str] = set()

    def replace(match: re.Match[str]) -> str:
        raw_key = match.group("key")
        name = raw_key.strip('"').split("::")[-1]
        if name not in versions:
            raise ValueError(f"path dependency {name} is not in the publish allowlist")
        body = (match.group("body") + match.group("tail")).strip().strip(",").strip()
        fields = [field.strip() for field in body.split(",") if field.strip() and not field.strip().startswith("path =")]
        fields.insert(0, f'version = "{versions[name]}"')
        converted.add(name)
        return f'{match.group("indent")}{raw_key} = {{ {", ".join(fields)} }}'

    output_lines: list[str] = []
    in_dependency_table = False
    for line in text.splitlines():
        section = re.match(r"^\s*\[([^]]+)\]\s*$", line)
        if section is not None:
            name = section.group(1)
            in_dependency_table = name == "dependencies" or (
                name.endswith(".dependencies") and not name.endswith(".bin-dependencies")
            )
        output_lines.append(PATH_DEPENDENCY.sub(replace, line) if in_dependency_table else line)
    output = "\n".join(output_lines) + ("\n" if text.endswith("\n") else "")
    parsed = tomllib.loads(output)
    for table in dependency_tables(parsed):
        for raw_name, specification in table.items():
            name = str(raw_name).split("::")[-1]
            if isinstance(specification, dict) and "path" in specification:
                raise ValueError(f"publish manifest retains path dependency {name}")
            if name in versions:
                actual = specification if isinstance(specification, str) else specification.get("version") if isinstance(specification, dict) else None
                if actual != versions[name]:
                    raise ValueError(f"publish dependency {name} has version {actual!r}, expected {versions[name]!r}")
    return output


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def git_identity() -> tuple[str, bool]:
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True, capture_output=True, check=True).stdout.strip()
    dirty = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, text=True, capture_output=True, check=True).stdout != ""
    return head, dirty


def toolchain_identity() -> dict[str, str]:
    sdk_root = os.environ.get("AXYNDRA_SDK_ROOT", "").strip()
    result = {"cjc": "not supplied", "cjpm": "not supplied", "nativeCompiler": "not supplied"}
    commands = {
        "cjc": [str(Path(sdk_root) / "bin" / "cjc"), "-v"] if sdk_root else [],
        "cjpm": [str(Path(sdk_root) / "tools" / "bin" / "cjpm"), "--version"] if sdk_root else [],
        "nativeCompiler": ["/usr/lib/llvm15/bin/clang++", "--version"],
    }
    for key, command in commands.items():
        if not command or not Path(command[0]).is_file():
            continue
        completed = subprocess.run(command, text=True, capture_output=True, check=True)
        output = (completed.stdout + completed.stderr).strip().splitlines()
        result[key] = output[0] if output else "unknown"
    return result


def readme(name: str, version: str, description: str, runtime: list[object], stability: str, has_license: bool) -> str:
    requirements = ", ".join(str(item) for item in runtime) if runtime else "None beyond the supported Cangjie SDK."
    license_note = "See the LICENSE file shipped with this package." if has_license else "License metadata is not declared yet; this candidate must not be published."
    return (
        f"# {name}\n\n{description}.\n\n"
        f"Package version: `{version}`. Stability: {stability}.\n\n"
        f"Runtime requirements: {requirements}\n\n"
        "This is a source package. Consumers rebuild Cangjie code against a compatible SDK. "
        "No Cangjie binary ABI compatibility is promised.\n\n"
        f"License: {license_note}\n"
    )


def stage(destination: Path) -> None:
    if destination.exists():
        raise ValueError(f"staging destination already exists: {destination}")
    errors, warnings = audit()
    if errors:
        raise ValueError("; ".join(errors))
    publishable, _, _, config = inventory()
    records = package_records()
    versions = {name: str(record["version"]) for name, record in records.items() if str(record["member"]) in publishable}
    runtime = config.get("runtime_requirements", {})
    stability = config.get("stability", {})
    assert isinstance(runtime, dict) and isinstance(stability, dict)
    license_files, notice_files, _ = legal_metadata()
    legal_files = license_files + notice_files
    head, dirty = git_identity()
    toolchain = toolchain_identity()
    destination.mkdir(parents=True)
    inventory_records: list[dict[str, object]] = []
    for member in publishable:
        source_root = ROOT / member
        source_manifest = load_toml(source_root / "cjpm.toml")
        package = source_manifest["package"]
        assert isinstance(package, dict)
        name = str(package["name"])
        version = str(package["version"])
        package_root = destination / f"{name}-{version}"
        package_root.mkdir()
        shutil.copytree(source_root / "src", package_root / "src")
        if name == "process4cj":
            native_root = package_root / "native"
            native_root.mkdir()
            shutil.copy2(source_root / "native" / "process4cj_native.c", native_root / "process4cj_native.c")
            compiler = Path("/usr/lib/llvm15/bin/clang++")
            archiver = Path("/usr/lib/llvm15/bin/llvm-ar")
            if not compiler.is_file() or not archiver.is_file():
                raise ValueError("process4cj source packaging requires /usr/lib/llvm15/bin/clang++ and llvm-ar")
            object_file = native_root / "process4cj_native.o"
            subprocess.run([
                str(compiler), "-x", "c", "-std=c11", "-O2", "-fPIC", "-c",
                "-o", str(object_file), str(native_root / "process4cj_native.c"),
            ], check=True)
            subprocess.run([
                str(archiver), "rcsD", str(native_root / "libprocess4cj_native.a"), str(object_file),
            ], check=True)
            object_file.unlink()
        transformed = transform_manifest((source_root / "cjpm.toml").read_text(encoding="utf-8"), versions)
        (package_root / "cjpm.toml").write_text(transformed, encoding="utf-8")
        for legal_file in legal_files:
            shutil.copy2(legal_file, package_root / legal_file.name)
        package_runtime = runtime.get(name, [])
        assert isinstance(package_runtime, list)
        (package_root / "README.md").write_text(readme(
            name, version, str(package.get("description", "")), package_runtime,
            str(stability.get(name, "unspecified")), bool(license_files),
        ), encoding="utf-8")

        forbidden = []
        for path in sorted(package_root.rglob("*")):
            if not path.is_file():
                continue
            if path.suffix in {".so", ".a", ".o"}:
                continue
            text = path.read_text(encoding="utf-8", errors="ignore")
            if "/home/elliot/" in text or "BEGIN PRIVATE KEY" in text:
                forbidden.append(path.relative_to(package_root).as_posix())
        if forbidden:
            raise ValueError(f"{name}: staged files contain developer path or private key marker: {forbidden}")

        files = [
            {"path": path.relative_to(package_root).as_posix(), "sha256": sha256(path), "size": path.stat().st_size}
            for path in sorted(package_root.rglob("*")) if path.is_file()
        ]
        manifest = load_toml(package_root / "cjpm.toml")
        entry = {
            "name": name,
            "version": version,
            "sourceHead": head,
            "sourceDirty": dirty,
            "toolchain": toolchain,
            "dependencies": sorted(declared_dependencies(manifest)),
            "runtimeRequirements": package_runtime,
            "licenseFiles": [path.name for path in license_files],
            "noticeFiles": [path.name for path in notice_files],
            "nativeArtifacts": [item["path"] for item in files if str(item["path"]).endswith((".so", ".a"))],
            "files": files,
        }
        (package_root / "package-manifest.json").write_text(json.dumps(entry, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        entry["candidateManifestSha256"] = sha256(package_root / "package-manifest.json")
        inventory_records.append(entry)

    root_manifest = {
        "formatVersion": 1,
        "sourceHead": head,
        "sourceDirty": dirty,
        "toolchain": toolchain,
        "packages": inventory_records,
        "publicationBlockers": warnings,
    }
    (destination / "package-inventory.json").write_text(json.dumps(root_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def normalized_tree(root: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            result[path.relative_to(root).as_posix()] = sha256(path)
    return result


CONSUMER_SOURCES = {
    "yjson_support": '''package yjson_support_consumer

import yjson_support.*
import std.unittest.*
import std.unittest.testmacro.*

func verify(): Unit {
    let value = parseUnifiedJson("{\\\"ok\\\":true}")
    if (stringifyUnifiedJson(value) != "{\\\"ok\\\":true}") { throw IllegalStateException("json round trip failed") }
}
@Test class ConsumerTests { @TestCase func packageWorks() { verify() } }
main(): Int64 { verify(); println("yjson_support external consumer passed"); 0 }
''',
    "jsonrpc4cj": '''package jsonrpc4cj_consumer

import jsonrpc4cj.*
import std.unittest.*
import std.unittest.testmacro.*

func verify(): Unit {
    if (!decodeJsonRpc("{\\\"jsonrpc\\\":\\\"2.0\\\",\\\"method\\\":\\\"ready\\\"}").isOk()) {
        throw IllegalStateException("json-rpc decode failed")
    }
}
@Test class ConsumerTests { @TestCase func packageWorks() { verify() } }
main(): Int64 { verify(); println("jsonrpc4cj external consumer passed"); 0 }
''',
    "process4cj": '''package process4cj_consumer

import process4cj.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

func verify(): Unit {
    let process = startProcess(ProcessCommand("/bin/cat"))
    process.writeStdin("package".toArray())
    process.flushInput()
    if (!process.closeInput()) { throw IllegalStateException("process input did not close") }
    if (!process.wait().succeeded) { throw IllegalStateException("process failed") }
    let output = Array<Byte>(7, repeat: 0)
    if (process.stdout.read(output) != 7 || String.fromUtf8(output) != "package") {
        throw IllegalStateException("process output mismatch")
    }
}
@Test class ConsumerTests { @TestCase func packageWorks() { verify() } }
main(): Int64 { verify(); println("process4cj external consumer passed"); 0 }
''',
    "mcp4cj": '''package mcp4cj_consumer

import mcp4cj.*
import std.unittest.*
import std.unittest.testmacro.*

func verify(): Unit {
    let lifecycle = McpLifecycle()
    if (!lifecycle.transition(McpLifecycleState.Starting).isOk()) { throw IllegalStateException("MCP lifecycle failed") }
}
@Test class ConsumerTests { @TestCase func packageWorks() { verify() } }
main(): Int64 { verify(); println("mcp4cj external consumer passed"); 0 }
''',
    "sandbox4cj": '''package sandbox4cj_consumer

import sandbox4cj.*
import std.fs.*
import std.unittest.*
import std.unittest.testmacro.*

func verify(): Unit {
    let sandbox = WorkspaceSandbox(WorkspaceSandboxPolicy(
        canonicalize(Path(".")).toString(), bubblewrapExecutable: "/definitely/missing/bwrap"
    ))
    match (sandbox.availability()) {
        case SandboxResult.Err(error) => if (error.code != "sandbox.bubblewrap_unavailable") { throw error }
        case SandboxResult.Ok(_) => throw IllegalStateException("missing bwrap unexpectedly available")
    }
}
@Test class ConsumerTests { @TestCase func packageWorks() { verify() } }
main(): Int64 { verify(); println("sandbox4cj external consumer passed"); 0 }
''',
    "lsp4cj": '''package lsp4cj_consumer

import lsp4cj.*
import std.io.*
import std.unittest.*
import std.unittest.testmacro.*

func verify(): Unit {
    let malformed = ByteBuffer()
    malformed.write("Content-Length: nope\\r\\n\\r\\n{}".toArray())
    if (readLspMessage(malformed).isOk()) { throw IllegalStateException("malformed LSP frame accepted") }
}
@Test class ConsumerTests { @TestCase func packageWorks() { verify() } }
main(): Int64 { verify(); println("lsp4cj external consumer passed"); 0 }
''',
    "dap4cj": '''package dap4cj_consumer

import dap4cj.*
import std.unittest.*
import std.unittest.testmacro.*

func verify(): Unit {
    let correlation = DapCorrelation()
    if (!correlation.reserve(7).isOk() || !correlation.complete(7).isOk()) { throw IllegalStateException("DAP correlation failed") }
}
@Test class ConsumerTests { @TestCase func packageWorks() { verify() } }
main(): Int64 { verify(); println("dap4cj external consumer passed"); 0 }
''',
}


def consumer_manifest(name: str, version: str, stage_root: Path, dependencies: list[str]) -> str:
    lines = [
        "[package]",
        '  cjc-version = "1.1.0"',
        f'  name = "{name}_consumer"',
        '  organization = ""',
        f'  description = "External package readiness consumer for {name}"',
        '  version = "1.0.0"',
        '  output-type = "executable"',
        "",
        "[dependencies]",
    ]
    for dependency in dependencies:
        if dependency == "yjson":
            lines.append(
                '  "yjson" = { git = "https://github.com/lIlIIlIll/yjson.git", '
                f'commitId = "{YJSON_COMMIT}", output-type = "static" }}'
            )
            continue
        dependency_manifest = load_toml(next(stage_root.glob(f"{dependency}-*/cjpm.toml")))
        package = dependency_manifest["package"]
        assert isinstance(package, dict)
        lines.append(f'  "{dependency}" = {{ version = "{package["version"]}", output-type = "static" }}')
    lines.extend(["", "[replace]"])
    for package_root in sorted(path for path in stage_root.iterdir() if path.is_dir()):
        package_manifest = load_toml(package_root / "cjpm.toml")
        package = package_manifest["package"]
        assert isinstance(package, dict)
        relative = Path("../../packages") / package_root.name
        lines.append(f'  "{package["name"]}" = {{ path = "{relative.as_posix()}" }}')
    return "\n".join(lines) + "\n"


def materialize_consumers(stage_root: Path, destination: Path) -> None:
    if destination.exists():
        raise ValueError(f"consumer destination already exists: {destination}")
    destination.mkdir(parents=True)
    versions = {
        str(load_toml(path)["package"]["name"]): str(load_toml(path)["package"]["version"])
        for path in stage_root.glob("*/cjpm.toml")
    }
    for name, source in CONSUMER_SOURCES.items():
        root = destination / name
        (root / "src").mkdir(parents=True)
        (root / "src" / "main.cj").write_text(source, encoding="utf-8")
        (root / "README.md").write_text(f"# {name} package readiness consumer\n", encoding="utf-8")
        (root / "cjpm.toml").write_text(consumer_manifest(name, versions[name], stage_root, [name]), encoding="utf-8")

    frozen = {
        "agent_sdk": (ROOT / "support_tests" / "sdk_fixture_extension", ["agent_sdk", "yjson", "yjson_support"]),
        "axyndra_agent_testkit": (ROOT / "support_tests" / "testkit_consumer", ["agent_sdk", "yjson", "yjson_support", "axyndra_agent_testkit"]),
    }
    for name, (source_root, dependencies) in frozen.items():
        root = destination / name
        shutil.copytree(source_root / "src", root / "src")
        shutil.copy2(source_root / "README.md", root / "README.md")
        manifest = consumer_manifest(name, versions[name], stage_root, dependencies)
        if name == "agent_sdk":
            manifest = manifest.replace('name = "agent_sdk_consumer"', 'name = "sdk_fixture_extension"')
            (root / "src" / "runner.cj").write_text(
                "package sdk_fixture_extension\n\nmain(): Int64 { runFixtureContract() }\n",
                encoding="utf-8",
            )
        else:
            manifest = manifest.replace('name = "axyndra_agent_testkit_consumer"', 'name = "testkit_consumer"')
            (root / "src" / "runner.cj").write_text(
                '''package testkit_consumer

import agent_sdk.*
import yjson_support.*
import axyndra_agent_testkit.*

main(): Int64 {
    let harness = ExtensionContractHarness(ConsumerExtension())
    let input = jsonObject([JsonObjectEntry("text", jsonString("package"))])
    let prepared = requireSdkOk(harness.prepare("consumer_echo", input, callId: "package-run"))
    assertCapabilityRequested(prepared.definition, "workspace.read")
    println("axyndra_agent_testkit external consumer passed")
    0
}
''', encoding="utf-8")
        (root / "cjpm.toml").write_text(manifest, encoding="utf-8")


def replace_table(stage_root: Path, relative_prefix: Path, exclude: str = "") -> str:
    lines = ["", "[replace]"]
    for package_root in sorted(path for path in stage_root.iterdir() if path.is_dir()):
        package_manifest = load_toml(package_root / "cjpm.toml")
        package = package_manifest["package"]
        assert isinstance(package, dict)
        name = str(package["name"])
        if name == exclude:
            continue
        relative = relative_prefix / package_root.name
        lines.append(f'  "{name}" = {{ path = "{relative.as_posix()}" }}')
    return "\n".join(lines) + "\n"


def materialize_validation(stage_root: Path, destination: Path) -> None:
    if destination.exists():
        raise ValueError(f"validation destination already exists: {destination}")
    destination.mkdir(parents=True)
    for package_root in sorted(path for path in stage_root.iterdir() if path.is_dir()):
        manifest = load_toml(package_root / "cjpm.toml")
        package = manifest["package"]
        assert isinstance(package, dict)
        name = str(package["name"])
        target = destination / name
        shutil.copytree(package_root, target)
        manifest_path = target / "cjpm.toml"
        manifest_path.write_text(
            manifest_path.read_text(encoding="utf-8")
            + replace_table(stage_root, Path("../../packages"), exclude=name),
            encoding="utf-8",
        )


def self_test_legal_metadata() -> None:
    with tempfile.TemporaryDirectory(prefix="axyndra-legal-metadata-") as value:
        root = Path(value)
        licenses, notices, blockers = legal_metadata(root)
        assert not licenses and not notices and len(blockers) == 1

        (root / "NOTICE").write_text("attribution\n", encoding="utf-8")
        licenses, notices, blockers = legal_metadata(root)
        assert not licenses and [path.name for path in notices] == ["NOTICE"]
        assert any("no non-empty LICENSE" in blocker for blocker in blockers)

        (root / "LICENSE").write_text("owner-supplied license text\n", encoding="utf-8")
        licenses, notices, blockers = legal_metadata(root)
        assert [path.name for path in licenses] == ["LICENSE"]
        assert [path.name for path in notices] == ["NOTICE"]
        assert not blockers

        (root / "LICENSE").write_text("", encoding="utf-8")
        _, _, blockers = legal_metadata(root)
        assert any("empty LICENSE metadata" in blocker for blocker in blockers)
        assert any("no non-empty LICENSE" in blocker for blocker in blockers)


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    audit_parser = subparsers.add_parser("audit")
    audit_parser.add_argument("--require-publication-metadata", action="store_true")
    stage_parser = subparsers.add_parser("stage")
    stage_parser.add_argument("destination", type=Path)
    compare_parser = subparsers.add_parser("compare")
    compare_parser.add_argument("first", type=Path)
    compare_parser.add_argument("second", type=Path)
    consumer_parser = subparsers.add_parser("materialize-consumers")
    consumer_parser.add_argument("stage", type=Path)
    consumer_parser.add_argument("destination", type=Path)
    validation_parser = subparsers.add_parser("materialize-validation")
    validation_parser.add_argument("stage", type=Path)
    validation_parser.add_argument("destination", type=Path)
    subparsers.add_parser("self-test")
    args = parser.parse_args()

    if args.command == "audit":
        errors, warnings = audit()
        for warning in warnings:
            print(f"warning: {warning}", file=sys.stderr)
        _, notices, _ = legal_metadata()
        if notices:
            print("NOTICE metadata: included " + ", ".join(path.name for path in notices))
        else:
            print("NOTICE metadata: not required by current publication policy")
        if errors or (warnings and args.require_publication_metadata):
            for error in errors:
                print(f"error: {error}", file=sys.stderr)
            return 1
        publishable, held, private, _ = inventory()
        print(f"package inventory passed ({len(publishable)} public, {len(held)} held, {len(private)} internal)")
        return 0
    if args.command == "self-test":
        self_test_legal_metadata()
        print("package legal metadata policy tests passed")
        return 0
    if args.command == "stage":
        stage(args.destination.resolve())
        print(args.destination.resolve())
        return 0
    if args.command == "compare":
        first = normalized_tree(args.first.resolve())
        second = normalized_tree(args.second.resolve())
        if first != second:
            for path in sorted(set(first) | set(second)):
                if first.get(path) != second.get(path):
                    print(f"different: {path}: {first.get(path)} != {second.get(path)}", file=sys.stderr)
            return 1
        print(f"staging trees match ({len(first)} files)")
        return 0
    if args.command == "materialize-consumers":
        materialize_consumers(args.stage.resolve(), args.destination.resolve())
        print(args.destination.resolve())
        return 0
    if args.command == "materialize-validation":
        materialize_validation(args.stage.resolve(), args.destination.resolve())
        print(args.destination.resolve())
        return 0
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError, tomllib.TOMLDecodeError) as error:
        print(f"package readiness error: {error}", file=sys.stderr)
        raise SystemExit(1)
